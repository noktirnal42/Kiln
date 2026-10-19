import Foundation
import Testing
@testable import Kiln

// MARK: - Test helpers

/// Thread-safe single-slot capture for prompts observed by a mock chat.
final class PromptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String?
    var text: String? {
        get { lock.lock(); defer { lock.unlock() }; return _text }
        set { lock.lock(); _text = newValue; lock.unlock() }
    }
}

struct ScriptedTurn: Sendable {
    var text: String = ""
    var toolCalls: [ToolCall] = []
    var usage: ChatChunk.Usage?
}

/// A chat factory that plays back scripted turns and can fail with
/// retryable errors a set number of times first — the shape the retry
/// tests need.
final class ScriptedChat: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ScriptedTurn]
    private var failuresBeforeSuccess: Int
    private var failureFactory: () -> Error
    private var calls = 0

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    init(
        turns: [ScriptedTurn],
        failuresBeforeSuccess: Int = 0,
        failureFactory: @escaping () -> Error = { ProviderError.rateLimited }
    ) {
        self.turns = turns
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failureFactory = failureFactory
    }

    var factory: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let self_ = self
        return { request in
            let chunk = try self_.next(request: request)
            return AsyncThrowingStream { continuation in
                continuation.yield(chunk)
                continuation.finish()
            }
        }
    }

    private func next(request: ChatRequest) throws -> ChatChunk {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw failureFactory()
        }
        guard !turns.isEmpty else {
            return ChatChunk(delta: ChatMessage(role: .assistant, content: ""), finishReason: .stop)
        }
        let index = min(calls - 1, turns.count - 1)
        let turn = turns[index]
        return ChatChunk(
            delta: ChatMessage(role: .assistant, content: turn.text),
            finishReason: turn.toolCalls.isEmpty ? .stop : .toolCalls,
            usage: turn.usage,
            toolCalls: turn.toolCalls
        )
    }
}

/// Collects an agent event stream to its end, returning (events, error).
func collectRun(
    _ orchestrator: AgentOrchestrator,
    profile: AgentProfile,
    prompt: String,
    workspaceRoot: URL? = nil,
    policy: ExecutionPolicy? = nil,
    stop: AgentStopFlag = AgentStopFlag(),
    backoffUnitSeconds: Double = 1.0,
    chat: @escaping @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error>
) async -> (events: [AgentEvent], error: Error?) {
    var events: [AgentEvent] = []
    var caught: Error?
    let stream = orchestrator.run(
        profile: profile,
        prompt: prompt,
        workspaceRoot: workspaceRoot,
        policy: policy,
        stop: stop,
        backoffUnitSeconds: backoffUnitSeconds,
        chat: chat
    )
    do {
        for try await event in stream { events.append(event) }
    } catch {
        caught = error
    }
    return (events, caught)
}

@MainActor
func makeTestApprovalCenter(
    autoResolve: ApprovalDecision?
) throws -> (ApprovalCenter, Task<Void, Never>) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kiln-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let center = ApprovalCenter(
        grants: GrantStore(fileURL: dir.appendingPathComponent("grants.json")),
        log: ApprovalLogStore(fileURL: dir.appendingPathComponent("approvals.jsonl"))
    )
    let watcher = Task { @MainActor in
        // Only auto-resolves when a decision was supplied; a nil decision
        // means the test wants to drive the approval itself.
        guard let autoResolve else { return }
        while !Task.isCancelled {
            if let request = center.pending.last {
                center.resolve(request.id, decision: autoResolve)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    return (center, watcher)
}

// MARK: - Orchestrator: the loop and both gates

struct OrchestratorLoopTests {
    @Test func toolCallLoopFeedsResultsBackAndFinishes() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = ToolRegistry(tools: [ReadFileTool(), WriteFileTool()])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)

        let profile = AgentProfile(
            name: "coder",
            mode: .act,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["read_file", "write_file"],
                policyByLevel: [.read: .automatic, .write: .automatic]
            )
        )

        let writeJSON = """
        {"path": "hello.txt", "content": "hi there"}
        """
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "writing", toolCalls: [ToolCall(id: "c1", name: "write_file", arguments: writeJSON)]),
            ScriptedTurn(text: "done writing"),
        ])

        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "write hello.txt",
            workspaceRoot: workspace, chat: chat.factory
        )
        #expect(error == nil)
        let finished = events.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }
        #expect(finished.count == 1)
        guard finished.count == 1 else { return }
        #expect(finished[0].toolCallsExecuted == 1)
        #expect(finished[0].finalText == "done writing")
        #expect(finished[0].rounds == 2)

        // The model saw the tool result in the next request's history.
        let written = try String(contentsOf: workspace.appendingPathComponent("hello.txt"), encoding: .utf8)
        #expect(written == "hi there")
    }

    @Test func gateBDeniesAToolTheModelWasNeverOffered() async throws {
        // Read-only agent: Gate A strips write_file from the offered list.
        // The model calls it anyway — Gate B must stop it, feed a denial
        // back, and the run must survive.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = ToolRegistry(tools: [ReadFileTool(), WriteFileTool()])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)

        let profile = AgentProfile(
            name: "reader",
            mode: .review,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["read_file", "write_file"],
                policyByLevel: ToolPermissionSet.readOnlyDefaults
            )
        )
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "sneaking", toolCalls: [
                ToolCall(id: "c1", name: "write_file", arguments: #"{"path": "x.txt", "content": "no"}"#)
            ]),
            ScriptedTurn(text: "I could not write."),
        ])
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "write x.txt",
            workspaceRoot: workspace, chat: chat.factory
        )
        #expect(error == nil)
        let denials = events.compactMap { ev -> (String, String)? in
            if case .policyDenied(let tool, let rule, _) = ev { return (tool, rule) }
            return nil
        }
        #expect(denials.contains(where: { $0.0 == "write_file" }))
        let finished = events.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }
        #expect(finished[0].toolCallsDenied == 1)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("x.txt").path))
    }

    @Test func outOfScopeWriteIsDeniedEvenWhenToolIsEnabled() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = ToolRegistry(tools: [WriteFileTool()])
        var noApprovalPolicy = ExecutionPolicy(mode: .act)
        noApprovalPolicy.requiredApprovals = [] // no approvals configured: out-of-scope is denied outright
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)

        let profile = AgentProfile(
            name: "coder",
            mode: .act,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["write_file"],
                policyByLevel: [.write: .automatic]
            )
        )
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "escaping", toolCalls: [
                ToolCall(id: "c1", name: "write_file", arguments: #"{"path": "../../outside-\#(UUID().uuidString).txt", "content": "x"}"#)
            ]),
            ScriptedTurn(text: "stopped"),
        ])
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "escape",
            workspaceRoot: workspace, policy: noApprovalPolicy, chat: chat.factory
        )
        #expect(error == nil)
        let denials = events.filter { if case .policyDenied = $0 { return true }; return false }
        #expect(!denials.isEmpty)
        let finished = events.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }
        #expect(finished.count == 1)
        #expect(finished[0].toolCallsDenied == 1)
    }

    @Test func blockedShellPatternIsDeniedBeforeAnyApproval() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = ToolRegistry(tools: [RunCommandTool()])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)

        let profile = AgentProfile(
            name: "coder",
            mode: .act,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["run_command"],
                policyByLevel: [.execute: .automatic]
            )
        )
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "nuking", toolCalls: [
                ToolCall(id: "c1", name: "run_command", arguments: #"{"command": "mkfs /dev/disk9"}"#)
            ]),
            ScriptedTurn(text: "refused"),
        ])
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "format disk",
            workspaceRoot: workspace, chat: chat.factory
        )
        #expect(error == nil)
        let denials = events.compactMap { ev -> String? in
            if case .policyDenied(_, let rule, _) = ev { return rule }
            return nil
        }
        #expect(denials.contains { $0.hasPrefix("shell.block_patterns") })
        // A blocked command must never reach the approval sheet.
        let approvals = events.filter { if case .awaitingApproval = $0 { return true }; return false }
        #expect(approvals.isEmpty)
    }

    @Test func deniedApprovalStopsExecutionButNotTheRun() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = ToolRegistry(tools: [WriteFileTool()])
        // Auto-deny everything the human is asked.
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)

        let profile = AgentProfile(
            name: "coder",
            mode: .act,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["write_file"],
                policyByLevel: [.write: .always]
            )
        )
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "writing", toolCalls: [
                ToolCall(id: "c1", name: "write_file", arguments: #"{"path": "a.txt", "content": "x"}"#)
            ]),
            ScriptedTurn(text: "user said no"),
        ])
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "write",
            workspaceRoot: workspace, chat: chat.factory
        )
        #expect(error == nil)
        let finished = events.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }
        #expect(finished[0].toolCallsDenied == 1)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
    }

    @Test func secretsAreRedactedBeforeTheProviderSeesThem() async throws {
        let registry = ToolRegistry(tools: [])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)
        let profile = AgentProfile(name: "chat", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []))

        let seenPrompt = PromptCapture()
        let chatFactory: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error> = { request in
            if seenPrompt.text == nil { seenPrompt.text = request.messages.first { $0.role == .user }?.content }
            return AsyncThrowingStream { $0.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: "ok"), finishReason: .stop)); $0.finish() }
        }
        let (events, error) = await collectRun(
            orchestrator, profile: profile,
            prompt: "my key is sk-abc123def456ghi789jkl012 please help",
            chat: chatFactory
        )
        #expect(error == nil)
        #expect(seenPrompt.text?.contains("[REDACTED:OpenAI-style Key]") == true)
        #expect(seenPrompt.text?.contains("sk-abc123") == false)
        let finished = events.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }
        #expect(finished[0].redactionCount == 1)
    }
}

// MARK: - ApprovalCenter

@MainActor
struct ApprovalCenterTests {
    @Test func approvalBlocksUntilResolved() async throws {
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: nil)
        defer { watcher.cancel() }
        let request = ApprovalRequest(
            toolName: "run_command",
            toolSummary: "run",
            argumentsJSON: #"{"command": "ls"}"#,
            permission: .execute
        )
        let answer = Task { await center.requestApproval(request, conversationID: UUID()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(center.pending.count == 1)
        guard center.pending.count == 1 else { answer.cancel(); return }
        #expect(center.pending[0].toolName == "run_command")
        center.resolve(request.id, decision: .approveOnce)
        let decision = await answer.value
        #expect(decision == .approveOnce)
        #expect(center.pending.isEmpty)
    }

    @Test func sessionApprovalIsRememberedPerConversation() async throws {
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: nil)
        defer { watcher.cancel() }
        let conv = UUID()
        let first = ApprovalRequest(toolName: "write_file", toolSummary: "w", argumentsJSON: "{}", permission: .write)
        let second = ApprovalRequest(toolName: "write_file", toolSummary: "w", argumentsJSON: "{}", permission: .write)

        let t1 = Task { await center.requestApproval(first, conversationID: conv) }
        try await Task.sleep(nanoseconds: 50_000_000)
        center.resolve(first.id, decision: .approveForSession)
        #expect(await t1.value == .approveForSession)

        // Second ask for the same tool in the same conversation: no human.
        let decision = await center.requestApproval(second, conversationID: conv)
        #expect(decision == .approveForSession)
        #expect(center.pending.isEmpty)

        // A different conversation asks again.
        let otherConv = UUID()
        let otherTask = Task { await center.requestApproval(second, conversationID: otherConv) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(center.pending.count == 1) // it surfaced for a human
        center.resolve(second.id, decision: .deny)
        #expect(await otherTask.value == .deny)
    }

    @Test func alwaysAllowPersistsARevocableHostGrant() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let grantFile = dir.appendingPathComponent("grants.json")

        let center = ApprovalCenter(
            grants: GrantStore(fileURL: grantFile),
            log: ApprovalLogStore(fileURL: dir.appendingPathComponent("approvals.jsonl"))
        )
        let request = ApprovalRequest(
            toolName: "web_fetch",
            toolSummary: "fetch",
            argumentsJSON: "{}",
            permission: .execute,
            grantValue: "api.example.com",
            grantKind: .egressHost
        )
        let t = Task { await center.requestApproval(request, conversationID: UUID()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        center.resolve(request.id, decision: .alwaysAllow)
        _ = await t.value
        #expect(center.grants.has(kind: .egressHost, value: "api.example.com"))

        // Persisted: a fresh store over the same file sees it.
        let reloaded = GrantStore(fileURL: grantFile)
        #expect(reloaded.has(kind: .egressHost, value: "api.example.com"))

        // The standing grant short-circuits the next ask.
        let again = await center.requestApproval(
            ApprovalRequest(toolName: "web_fetch", toolSummary: "fetch", argumentsJSON: "{}", permission: .execute,
                            grantValue: "api.example.com", grantKind: .egressHost),
            conversationID: UUID()
        )
        #expect(again == .alwaysAllow)

        // Revocation works and is immediate.
        center.grants.revoke(kind: .egressHost, value: "api.example.com")
        #expect(!center.grants.has(kind: .egressHost, value: "api.example.com"))
    }

    @Test func approvalLogRecordsEveryDecision() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = ApprovalCenter(
            grants: GrantStore(fileURL: dir.appendingPathComponent("grants.json")),
            log: ApprovalLogStore(fileURL: dir.appendingPathComponent("approvals.jsonl"))
        )
        let request = ApprovalRequest(toolName: "run_command", toolSummary: "r", argumentsJSON: "{}", permission: .execute)
        let t = Task { await center.requestApproval(request, conversationID: UUID()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        center.resolve(request.id, decision: .deny)
        _ = await t.value
        let entries = center.log.readAll()
        #expect(entries.count == 1)
        #expect(entries[0].decision == "deny")
        #expect(entries[0].toolName == "run_command")
    }
}
