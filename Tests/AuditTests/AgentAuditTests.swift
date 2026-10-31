import Foundation
import Testing
@testable import Kiln

struct AgentAuditTests {
    // MARK: Helpers

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-agent-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-audit-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writerProfile(level: ApprovalPolicy = .automatic) -> AgentProfile {
        AgentProfile(
            name: "coder",
            mode: .act,
            toolPermissions: ToolPermissionSet(enabledTools: ["write_file"], policyByLevel: [.write: level])
        )
    }

    private func writeCall(path: String = "hello.txt", content: String = "hi there") -> ToolCall {
        let arguments = #"{"path": "\#(path)", "content": "\#(content)"}"#
        return ToolCall(id: "c1", name: "write_file", arguments: arguments)
    }

    private func types(_ chain: AuditChain) async throws -> [String] {
        try await chain.export().events.map(\.type)
    }

    // MARK: Ordering and content

    @Test func aSuccessfulRunIsRecordedInEmissionOrder() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chain = AuditChain(directory: try makeDirectory("log"))
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), auditChain: chain)
        let script = ScriptedChat(turns: [
            ScriptedTurn(text: "writing", toolCalls: [writeCall()]),
            ScriptedTurn(text: "done"),
        ])

        let (_, error) = await collectRun(orchestrator, profile: writerProfile(), prompt: "write it",
                                          workspaceRoot: workspace, chat: script.factory)
        #expect(error == nil)

        #expect(try await types(chain) == [
            "agent.run.started", "agent.round", "tool.call", "tool.result", "agent.round", "agent.run.finished",
        ])
        let verification = try await chain.verify()
        #expect(verification.ok)
        #expect(verification.checked == 6)
    }

    @Test func everyEntryOfARunSharesItsRunID() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chain = AuditChain(directory: try makeDirectory("log"))
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), auditChain: chain)
        let script = ScriptedChat(turns: [ScriptedTurn(text: "writing", toolCalls: [writeCall()]), ScriptedTurn(text: "done")])
        _ = await collectRun(orchestrator, profile: writerProfile(), prompt: "go", workspaceRoot: workspace, chat: script.factory)

        let ids = Set(try await chain.export().events.map(\.runID))
        #expect(ids.count == 1)
        #expect(ids.first! != nil)
    }

    @Test func toolCallRecordsWhatWasTouchedButNotWhatWasWritten() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = try makeDirectory("log")
        let chain = AuditChain(directory: directory)
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), auditChain: chain)
        let script = ScriptedChat(turns: [
            ScriptedTurn(text: "writing", toolCalls: [writeCall(path: "notes.txt", content: "TOP-SECRET-CONTENT-8731")]),
            ScriptedTurn(text: "done"),
        ])
        _ = await collectRun(orchestrator, profile: writerProfile(), prompt: "go", workspaceRoot: workspace, chat: script.factory)

        let log = try String(contentsOf: directory.appendingPathComponent("audit-events.jsonl"), encoding: .utf8)
        #expect(log.contains("write_file"))
        #expect(log.contains("notes.txt"))
        #expect(log.contains("\"other_keys\":[\"content\"]"))
        #expect(!log.contains("TOP-SECRET-CONTENT-8731"))
    }

    @Test func promptAndSecretsNeverReachTheLog() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = try makeDirectory("log")
        let chain = AuditChain(directory: directory)
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), auditChain: chain)
        let script = ScriptedChat(turns: [
            // A secret-shaped value inside an identifying argument must be redacted before it is logged.
            ScriptedTurn(text: "writing", toolCalls: [writeCall(path: "notes-AKIAIOSFODNN7EXAMPLE.txt")]),
            ScriptedTurn(text: "done"),
        ])
        _ = await collectRun(orchestrator, profile: writerProfile(),
                             prompt: "private plan: the launch code is ORCHID-77-PAPAYA",
                             workspaceRoot: workspace, chat: script.factory)

        let log = try String(contentsOf: directory.appendingPathComponent("audit-events.jsonl"), encoding: .utf8)
        #expect(!log.contains("ORCHID-77-PAPAYA"))
        #expect(!log.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(log.contains("\"prompt_characters\":"))
    }

    // MARK: Policy and approvals

    @Test func policyDenialsAreRecorded() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chain = AuditChain(directory: try makeDirectory("log"))
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [ReadFileTool(), WriteFileTool()]),
                                             auditChain: chain)
        let reader = AgentProfile(
            name: "reader", mode: .review,
            toolPermissions: ToolPermissionSet(enabledTools: ["read_file", "write_file"],
                                               policyByLevel: ToolPermissionSet.readOnlyDefaults)
        )
        let script = ScriptedChat(turns: [
            ScriptedTurn(text: "sneaking", toolCalls: [writeCall(path: "x.txt")]),
            ScriptedTurn(text: "could not write"),
        ])
        _ = await collectRun(orchestrator, profile: reader, prompt: "write", workspaceRoot: workspace, chat: script.factory)

        let events = try await chain.export().events
        let denial = try #require(events.first { $0.type == "policy.denied" })
        #expect(denial.payload["tool"] == "write_file")
        #expect(events.contains { $0.type == "tool.result" && $0.payload["status"] == "denied" })
    }

    @MainActor
    @Test func approvalDecisionKindIsRecordedNotJustYesOrNo() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chain = AuditChain(directory: try makeDirectory("log"))
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: .approveForSession)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]),
                                             approvalCenter: center, auditChain: chain)
        let script = ScriptedChat(turns: [ScriptedTurn(text: "writing", toolCalls: [writeCall()]), ScriptedTurn(text: "done")])

        _ = await collectRun(orchestrator, profile: writerProfile(level: .once), prompt: "go",
                             workspaceRoot: workspace, chat: script.factory)

        let events = try await chain.export().events
        let order = events.map(\.type).filter { $0.hasPrefix("approval.") }
        #expect(order == ["approval.requested", "approval.decision", "approval.resolved"])
        let decision = try #require(events.first { $0.type == "approval.decision" })
        #expect(decision.payload["decision"] == "approveForSession")
        let resolved = try #require(events.first { $0.type == "approval.resolved" })
        #expect(resolved.payload["approved"] == true)
    }

    // MARK: Failure handling

    @Test func aStoppedRunIsRecordedAsFailedAndFlushed() async throws {
        let chain = AuditChain(directory: try makeDirectory("log"))
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: []), auditChain: chain)
        let stop = AgentStopFlag()
        stop.stop()
        let script = ScriptedChat(turns: [ScriptedTurn(text: "never")])

        let (_, error) = await collectRun(orchestrator, profile: writerProfile(), prompt: "go",
                                          stop: stop, chat: script.factory)
        #expect(error != nil)

        // The run has ended, so everything queued must already be in the chain.
        #expect(try await types(chain) == ["agent.run.started", "agent.run.failed"])
        #expect(try await chain.verify().ok)
    }

    @Test func runsWithoutAChainRecordNothingAndStillWork() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]))
        let script = ScriptedChat(turns: [ScriptedTurn(text: "writing", toolCalls: [writeCall()]), ScriptedTurn(text: "done")])

        let (events, error) = await collectRun(orchestrator, profile: writerProfile(), prompt: "go",
                                               workspaceRoot: workspace, chat: script.factory)
        #expect(error == nil)
        #expect(events.contains { if case .finished = $0 { return true }; return false })
    }

    @Test func aRefusingChainIsCountedAndTheRunContinues() async throws {
        let directory = try makeDirectory("log")
        try "not an event\n".write(to: directory.appendingPathComponent("audit-events.jsonl"),
                                  atomically: true, encoding: .utf8)
        let recorder = AgentAuditRecorder(chain: AuditChain(directory: directory))
        recorder.record("first")
        recorder.record("second")
        await recorder.finish()

        #expect(recorder.droppedEntries == 2)
        #expect(recorder.lastFailureDescription != nil)
    }

    @Test func concurrentRunsEachKeepTheirOwnOrderInOneValidChain() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chain = AuditChain(directory: try makeDirectory("log"))
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), auditChain: chain)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    let script = ScriptedChat(turns: [
                        ScriptedTurn(text: "writing", toolCalls: [self.writeCall(path: "f\(index).txt")]),
                        ScriptedTurn(text: "done"),
                    ])
                    // Distinct profiles so the per-profile concurrency limiter does not serialize them.
                    var profile = self.writerProfile()
                    profile.name = "coder-\(index)"
                    _ = await collectRun(orchestrator, profile: profile, prompt: "go",
                                         workspaceRoot: workspace, chat: script.factory)
                }
            }
        }

        let events = try await chain.export().events
        #expect(try await chain.verify().ok)
        for runID in Set(events.compactMap(\.runID)) {
            let own = events.filter { $0.runID == runID }.map(\.type)
            #expect(own == ["agent.run.started", "agent.round", "tool.call", "tool.result", "agent.round", "agent.run.finished"])
        }
    }

    // MARK: Pure mapping

    @Test func textDeltasAreNotRecorded() {
        #expect(AgentAuditRecorder.entry(for: .textDelta("anything the model said")) == nil)
    }

    @Test func argumentSummaryKeepsIdentifyingValuesAndOnlyNamesTheRest() {
        let summary = AgentAuditRecorder.summarizeArguments(#"{"path":"a.txt","content":"secret body","mode":"w"}"#)
        #expect(summary == ["values": ["path": "a.txt"], "other_keys": ["content", "mode"]])
    }

    @Test func longIdentifyingValuesAreClipped() {
        let long = String(repeating: "x", count: 1000)
        let summary = AgentAuditRecorder.summarizeArguments(#"{"command":"\#(long)"}"#)
        guard case .object(let top) = summary, case .object(let values)? = top["values"],
              case .string(let command)? = values["command"] else {
            Issue.record("unexpected summary shape")
            return
        }
        #expect(command.count == 301)
        #expect(command.hasSuffix("…"))
    }

    @Test func unparseableArgumentsAreMarkedNotDropped() {
        #expect(AgentAuditRecorder.summarizeArguments("not json") == ["unparseable": true])
    }
}
