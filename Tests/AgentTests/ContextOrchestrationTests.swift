import Foundation
import Testing
@testable import Kiln

private final class RoundScript: @unchecked Sendable {
    private let lock = NSLock()
    private var rounds = 0
    private var _summaryRequests = 0
    private var _requestSizes: [Int] = []
    let toolRounds: Int
    let failSummary: Bool
    init(toolRounds: Int, failSummary: Bool = false) { self.toolRounds = toolRounds; self.failSummary = failSummary }
    var summaryRequests: Int { lock.lock(); defer { lock.unlock() }; return _summaryRequests }
    var requestSizes: [Int] { lock.lock(); defer { lock.unlock() }; return _requestSizes }

    var factory: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let me = self
        return { request in
            let chunk = try me.respond(to: request)
            return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
        }
    }

    private func respond(to request: ChatRequest) throws -> ChatChunk {
        lock.lock(); defer { lock.unlock() }
        if request.messages.first?.content == ContextCompactor.summaryInstructions {
            _summaryRequests += 1
            if failSummary { throw ProviderError.authenticationFailed }
            return ChatChunk(delta: ChatMessage(role: .assistant, content: "SUMMARY of the work so far."), finishReason: .stop)
        }
        _requestSizes.append(ContextCompactor.estimateTokens(request.messages))
        rounds += 1
        if rounds <= toolRounds {
            let call = ToolCall(id: "c\(rounds)", name: "read_file", arguments: "{\"path\":\"big.txt\"}")
            return ChatChunk(delta: ChatMessage(role: .assistant, content: ""), finishReason: .toolCalls, toolCalls: [call])
        }
        return ChatChunk(delta: ChatMessage(role: .assistant, content: "All done."), finishReason: .stop)
    }
}

struct ContextOrchestrationTests {
    private func setup() async throws -> (AgentOrchestrator, AgentProfile, URL, Task<Void, Never>) {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try String(repeating: "lorem ipsum ", count: 500).write(to: workspace.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .approveOnce)
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [ReadFileTool()]), approvalCenter: center)
        var profile = AgentProfile(
            name: "reader", mode: .act,
            toolPermissions: ToolPermissionSet(enabledTools: ["read_file"], policyByLevel: [.read: .automatic])
        )
        profile.maxTokens = 400
        return (orchestrator, profile, workspace, watcher)
    }

    private func run(_ o: AgentOrchestrator, _ p: AgentProfile, _ ws: URL, window: Int?, limit: Int = 200, chat: RoundScript) async -> (events: [AgentEvent], error: Error?) {
        var events: [AgentEvent] = []
        var caught: Error?
        do {
            for try await e in o.run(profile: p, prompt: "read it a lot", workspaceRoot: ws, contextWindow: window, roundLimit: limit, chat: chat.factory) {
                events.append(e)
            }
        } catch { caught = error }
        return (events, caught)
    }

    @Test func aSmallWindowTriggersCompactionAndTheRunStillFinishes() async throws {
        let (orchestrator, profile, ws, watcher) = try await setup()
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: ws) }
        let chat = RoundScript(toolRounds: 12)
        let (events, error) = await run(orchestrator, profile, ws, window: 3_500, chat: chat)
        #expect(error == nil)
        let compactions = events.compactMap { e -> ContextCompaction? in if case .contextCompacted(let c) = e { return c }; return nil }
        #expect(!compactions.isEmpty)
        #expect(compactions.allSatisfy { $0.tokensAfter < $0.tokensBefore })
        #expect(compactions.contains { $0.stage == .summarized && $0.summary?.contains("SUMMARY of the work") == true })
        #expect(chat.summaryRequests >= 1)
        let summary = events.compactMap { e -> AgentRunSummary? in if case .finished(let s) = e { return s }; return nil }.first
        #expect(summary?.finalText == "All done.")
        // The window held: no request grew past it.
        #expect((chat.requestSizes.max() ?? 0) <= 3_500)
        // Usage is reported against the window each round.
        #expect(events.contains { if case .contextMeasured(_, let w) = $0 { return w == 3_500 }; return false })
    }

    @Test func withoutAWindowNothingIsCompactedOrMeasured() async throws {
        let (orchestrator, profile, ws, watcher) = try await setup()
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: ws) }
        let chat = RoundScript(toolRounds: 8)
        let (events, error) = await run(orchestrator, profile, ws, window: nil, chat: chat)
        #expect(error == nil)
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; if case .contextMeasured = $0 { return true }; return false })
        #expect(chat.summaryRequests == 0)
    }

    @Test func aFailingSummaryDropsTheOldestPartAndKeepsGoing() async throws {
        let (orchestrator, profile, ws, watcher) = try await setup()
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: ws) }
        let chat = RoundScript(toolRounds: 12, failSummary: true)
        let (events, error) = await run(orchestrator, profile, ws, window: 3_500, chat: chat)
        #expect(error == nil)
        let stages = events.compactMap { e -> CompactionStage? in if case .contextCompacted(let c) = e { return c.stage }; return nil }
        #expect(stages.contains(.dropped))
    }

    @Test func theRoundLimitPausesGracefullyInsteadOfFailing() async throws {
        let (orchestrator, profile, ws, watcher) = try await setup()
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: ws) }
        let chat = RoundScript(toolRounds: 100)
        let (events, error) = await run(orchestrator, profile, ws, window: nil, limit: 3, chat: chat)
        #expect(error == nil)
        let summary = events.compactMap { e -> AgentRunSummary? in if case .finished(let s) = e { return s }; return nil }.first
        #expect(summary?.pausedAfterRounds == 3)
        #expect(summary?.rounds == 3)
        #expect(summary?.finalText == "Paused after 3 steps; say continue to pick up where it left off.")
    }

    @Test func theDefaultLimitIsFarAboveTheOldFortyAndAFinishedRunIsNotPaused() async throws {
        #expect(AgentOrchestrator.defaultRoundLimit == 200)
        let (orchestrator, profile, ws, watcher) = try await setup()
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: ws) }
        let chat = RoundScript(toolRounds: 45)
        let (events, error) = await run(orchestrator, profile, ws, window: nil, chat: chat)
        #expect(error == nil)
        let summary = events.compactMap { e -> AgentRunSummary? in if case .finished(let s) = e { return s }; return nil }.first
        #expect(summary?.pausedAfterRounds == nil)
        #expect(summary?.rounds == 46)
    }

    @Test func manualCompactionSummarisesAndReportsCounts() async throws {
        let (orchestrator, profile, ws, watcher) = try await setup()
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: ws) }
        var history: [ChatMessage] = []
        for i in 0..<8 {
            history.append(ChatMessage(role: .user, content: "q\(i) " + String(repeating: "a", count: 1_500)))
            history.append(ChatMessage(role: .assistant, content: "r\(i) " + String(repeating: "b", count: 1_500)))
        }
        let chat = RoundScript(toolRounds: 0)
        let outcome = await orchestrator.compact(profile: profile, history: history, contextWindow: 20_000, chat: chat.factory)
        #expect(outcome.stage == .summarized)
        #expect(outcome.tokensAfter < outcome.tokensBefore)
        #expect(outcome.messages.last == history.last)
    }
}
