import Foundation
import Testing
@testable import Kiln

struct RunEvidenceCollectorTests {
    private func record(_ tool: String, _ args: String, _ status: ToolCallStatus, error: String? = nil) -> ToolCallRecord {
        ToolCallRecord(toolName: tool, argumentsJSON: args, errorText: error, status: status)
    }

    @Test func buildsEvidenceFromToolEvents() {
        var collector = RunEvidenceCollector(toolsOffered: ["write_file", "read_file", "run_command"])
        collector.record(.roundStarted(1))
        collector.record(.toolCallStarted(record("read_file", #"{"path":"a.py"}"#, .running)))
        collector.record(.toolCallFinished(record("read_file", #"{"path":"a.py"}"#, .succeeded)))
        collector.record(.toolCallFinished(record("write_file", #"{"path":"b.py","content":"x"}"#, .succeeded)))
        collector.record(.toolCallFinished(record("run_command", #"{"command":"python3 b.py"}"#, .succeeded)))
        collector.record(.toolCallFinished(record("write_file", #"{"path":"c.py","content":"x"}"#, .failed, error: "denied")))
        collector.record(.finished(AgentRunSummary(finalText: "done")))
        let evidence = collector.evidence
        #expect(evidence.succeeded.count == 3 && evidence.failed.count == 1)
        #expect(evidence.filesWritten == ["b.py"])
        #expect(evidence.commandsRun.first?.target == "python3 b.py")
        #expect(evidence.didWrite && evidence.didRead)
        #expect(evidence.summaryLine.contains("files written: b.py") && evidence.summaryLine.contains("1 failed/denied"))
        #expect(evidence.finalText == "done")
    }

    @Test func countsTurnsThatWereProseOnly() {
        var collector = RunEvidenceCollector(toolsOffered: ["read_file"])
        collector.record(.roundStarted(1)); collector.record(.textDelta("I looked at it and it is fine."))
        collector.record(.roundStarted(2)); collector.record(.textDelta("Done."))
        collector.record(.finished(AgentRunSummary(finalText: "Done.")))
        #expect(collector.evidence.proseOnlyTurns == 2)
        #expect(collector.evidence.summaryLine == "evidence: no tools were executed")
    }
}

struct RunVerifierTests {
    private func evidence(offered: [String] = ["write_file", "read_file"], calls: [RunEvidence.Call] = []) -> RunEvidence {
        var e = RunEvidence(); e.toolsOffered = offered; e.calls = calls; return e
    }
    private func ok(_ tool: String, _ target: String? = nil) -> RunEvidence.Call { .init(tool: tool, status: .succeeded, target: target, error: nil) }
    private func bad(_ tool: String, _ message: String) -> RunEvidence.Call { .init(tool: tool, status: .failed, target: nil, error: message) }

    @Test func classifiesProviderModelAndToolFailuresSeparately() {
        let empty = RunVerifier.verdict(evidence: evidence(), summary: "  ", role: .implementer, workspace: nil, simulatedToolCall: false)
        #expect(empty == .providerReturnedNothing)
        #expect(empty?.description.hasPrefix("Provider/transport") == true)

        let prose = RunVerifier.verdict(evidence: evidence(), summary: "All good, the code looks right.", role: .reviewer, workspace: nil, simulatedToolCall: false)
        #expect(prose == .modelUsedNoTools && prose?.description.hasPrefix("Model limitation") == true)

        let simulated = RunVerifier.verdict(evidence: evidence(), summary: #"{"name":"write_file","arguments":{}}"#, role: .implementer, workspace: nil, simulatedToolCall: true)
        #expect(simulated == .modelSimulatedToolCall)

        let toolFailure = RunVerifier.verdict(evidence: evidence(calls: [bad("write_file", "permission denied")]), summary: "I tried.", role: .implementer, workspace: nil, simulatedToolCall: false)
        #expect(toolFailure == .toolFailed(tool: "write_file", message: "permission denied"))
        #expect(toolFailure?.description.hasPrefix("Tool failure") == true)
    }

    @Test func anImplementerClaimingFileChangesNeedsAWriteOrCommand() {
        let readsOnly = evidence(calls: [ok("read_file", "a.py")])
        #expect(RunVerifier.verdict(evidence: readsOnly, summary: "I created calc.py with the add function.", role: .implementer, workspace: nil, simulatedToolCall: false) == .claimedWorkWithoutEvidence)
        let wrote = evidence(calls: [ok("read_file", "a.py"), ok("write_file", "calc.py")])
        #expect(RunVerifier.verdict(evidence: wrote, summary: "I created calc.py with the add function.", role: .implementer, workspace: nil, simulatedToolCall: false) == nil)
        // A researcher describing what it read is not claiming changes.
        #expect(RunVerifier.verdict(evidence: readsOnly, summary: "The file a.py was written in Python.", role: .researcher, workspace: nil, simulatedToolCall: false) == nil)
    }

    @Test func expectedArtifactsAreCheckedOnDiskInsideTheWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-expect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("full.txt"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
        #expect(TaskExpectation.fileExists("full.txt").unmet(in: root) == nil)
        #expect(TaskExpectation.fileExists("nope.txt").unmet(in: root) == "file nope.txt")
        #expect(TaskExpectation.fileNonEmpty("empty.txt").unmet(in: root) == "non-empty file empty.txt")
        #expect(TaskExpectation.fileExists("../outside.txt").unmet(in: root)?.contains("outside the workspace") == true)
        #expect(TaskExpectation("file:a/b.txt") == .fileExists("a/b.txt") && TaskExpectation("nonempty:x") == .fileNonEmpty("x") && TaskExpectation("bogus") == nil)

        let withWrite = evidence(calls: [ok("write_file", "missing.txt")])
        let verdict = RunVerifier.verdict(evidence: withWrite, summary: "Wrote missing.txt", role: .implementer,
                                          expectations: [.fileExists("missing.txt")], workspace: root, simulatedToolCall: false)
        #expect(verdict == .expectationNotMet("file missing.txt"))
    }

    @Test func plansMayDeclareExpectedFilesAndInvalidOnesAreDropped() throws {
        let reply = #"{"tasks":[{"id":"a","title":"A","role":"implementer","expects":["file:out.txt","nonempty:data.json","garbage"]}]}"#
        let graph = try #require(SwarmPlanner.parse(reply))
        #expect(graph.task("a")?.expects == ["file:out.txt", "nonempty:data.json"])
    }
}

@MainActor
struct SwarmWorkerEvidenceTests {
    private func runOne(role: SwarmRole, turns: [ScriptedTurn], expects: [String] = [], workspace: URL) async throws -> SwarmGraph {
        let registry = ToolRegistry(tools: [ReadFileTool(), WriteFileTool(), EditFileTool()])
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let base = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)
        let chat = ScriptedChat(turns: turns)
        let swarm = SwarmOrchestrator(bus: CoordinationBus(), attemptsPerTask: 1,
                                      worker: SwarmWorkers.agent(base: base, modelID: "stub", workspaceRoot: workspace, chat: chat.factory))
        let graph = try SwarmGraph(tasks: [SwarmTask(id: "t", title: "Task", details: "do it", role: role, expects: expects)])
        var final: SwarmGraph?
        for await event in swarm.run(goal: "g", graph: graph) { if case .finished(let g) = event { final = g } }
        return try #require(final)
    }

    private func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-swarm-ev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aWorkerThatWritesAFileIsDoneWithEvidenceAttached() async throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let write = ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"hello.txt","content":"hi"}"#)
        let final = try await runOne(role: .implementer, turns: [ScriptedTurn(text: "writing", toolCalls: [write]), ScriptedTurn(text: "I created hello.txt.")],
                                     expects: ["nonempty:hello.txt"], workspace: dir)
        let task = try #require(final.task("t"))
        #expect(task.status == .done)
        #expect(task.result?.contains("[evidence: tools: write_file") == true && task.result?.contains("files written: hello.txt") == true)
    }

    @Test func aWorkerThatOnlyTalksIsBlockedAsAModelLimitation() async throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let final = try await runOne(role: .implementer, turns: [ScriptedTurn(text: "I created hello.py and it works.")], workspace: dir)
        let task = try #require(final.task("t"))
        #expect(task.status == .blocked)
        #expect(task.result?.contains("Model limitation") == true && task.result?.contains("no tools were executed") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("hello.py").path))
    }

    @Test func aMissingExpectedFileBlocksEvenWhenToolsRan() async throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let write = ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"other.txt","content":"hi"}"#)
        let final = try await runOne(role: .implementer, turns: [ScriptedTurn(text: "writing", toolCalls: [write]), ScriptedTurn(text: "Wrote other.txt.")],
                                     expects: ["file:report.md"], workspace: dir)
        let task = try #require(final.task("t"))
        #expect(task.status == .blocked && task.result?.contains("expected file report.md") == true)
    }
}

@Suite("RunFailure error classification")
struct RunFailureClassifyTests {
    @Test func classifiesProviderRejections() {
        #expect(RunFailure.classify(errorMessage: "x does not support tools").hasPrefix("Model limitation"))
        #expect(RunFailure.classify(errorMessage: "The run exceeded its wall-clock timeout.").hasPrefix("Provider/transport"))
        #expect(RunFailure.classify(errorMessage: "weird").hasPrefix("Unverified"))
    }
}
