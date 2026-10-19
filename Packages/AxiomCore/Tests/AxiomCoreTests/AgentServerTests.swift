import XCTest
@testable import AxiomCore

/// MCP server, operation lifecycle, audit log and edit proposals, driven in-process through `MCPServer` (no subprocess).
final class AgentServerTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock(); private(set) var messages: [[String: Any]] = []
        func add(_ m: [String: Any]) { lock.lock(); messages.append(m); lock.unlock() }
        func response(id: Int) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return messages.first { ($0["id"] as? Int) == id } }
        func notifications(_ method: String) -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return messages.filter { ($0["method"] as? String) == method } }
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Harness {
        let server: MCPServer; let out: Collector; let audit: AuditLog; let registry: OperationRegistry
        func send(_ object: [String: Any]) { server.handle(line: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
        func call(_ id: Int, _ tool: String, _ args: [String: Any] = [:], progressToken: String? = nil) {
            var params: [String: Any] = ["name": tool, "arguments": args]
            if let progressToken { params["_meta"] = ["progressToken": progressToken] }
            send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params])
        }
        func text(_ id: Int) -> String? { ((out.response(id: id)?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String }
    }

    private func harness(proposeOnly: Bool = false) throws -> Harness {
        let out = Collector(); let audit = AuditLog(directory: try tempDir()); let registry = OperationRegistry()
        let server = MCPServer(options: .init(proposeOnly: proposeOnly, transport: "mcp", audit: audit, registry: registry)) { out.add($0) }
        let h = Harness(server: server, out: out, audit: audit, registry: registry)
        h.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-client", "version": "9"]]])
        h.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return h
    }
    private func eventually(_ timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return condition()
    }
    private func project() throws -> String {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        var a = Analysis(binaryPath: "/tmp/x", sha256: "00", size: 1, format: "test", engine: "test", sections: "", hex: "",
                         functions: [FunctionRecord(address: "00001000", name: "f"), FunctionRecord(address: "00002000", name: "g")], strings: [])
        a.revision = 0
        try ProjectStore.create(a, to: path)
        return path
    }
    override func tearDown() { AgentTools.extra = [:]; super.tearDown() }

    // MARK: Protocol

    func testInitializeNegotiatesVersionAndListsTheNewTools() throws {
        let h = try harness()
        XCTAssertEqual(((h.out.response(id: 1)?["result"] as? [String: Any])?["protocolVersion"]) as? String, "2025-06-18")
        h.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = ((h.out.response(id: 2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        for name in ["list_operations", "cancel_operation", "list_audit", "propose_edit", "list_proposals", "withdraw_proposal", "change_variable", "annotate_address"] { XCTAssertTrue(names.contains(name), name) }
        let readOnly = { (name: String) in ((tools.first { $0["name"] as? String == name }?["annotations"]) as? [String: Any])?["readOnlyHint"] as? Bool }
        XCTAssertEqual(readOnly("list_audit"), true); XCTAssertEqual(readOnly("propose_edit"), false); XCTAssertEqual(readOnly("rename_function"), false); XCTAssertEqual(readOnly("list_proposals"), true)
    }

    func testRequestsBeforeInitializeAreRefusedAndBadInputGetsTypedErrors() {
        let out = Collector(); let server = MCPServer(options: .init(audit: nil, registry: OperationRegistry())) { out.add($0) }
        server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)
        XCTAssertEqual(((out.response(id: 5)?["error"]) as? [String: Any])?["code"] as? Int, -32601)
        server.handle(line: "not json")
        XCTAssertEqual(((out.messages.last?["error"]) as? [String: Any])?["code"] as? Int, -32700)
    }

    // MARK: Operations, audit

    func testEveryCallCarriesAnOperationIdAndIsAudited() throws {
        let h = try harness()
        AgentTools.extra["_echo"] = { _ in #"{"ok":true,"revision":7}"# }
        h.call(10, "_echo", ["project": "/tmp/p", "password": "hunter2", "note": String(repeating: "x", count: 300)])
        h.server.waitUntilIdle()
        let result = h.out.response(id: 10)?["result"] as? [String: Any]
        let opId = (result?["_meta"] as? [String: Any])?["axiom/operationId"] as? String
        XCTAssertNotNil(opId)
        let entry = h.audit.read().items.first
        XCTAssertEqual(entry?.operationId, opId); XCTAssertEqual(entry?.tool, "_echo"); XCTAssertEqual(entry?.outcome, "ok"); XCTAssertEqual(entry?.client, "test-client/9")
        XCTAssertEqual(entry?.arguments["password"], "[redacted]", "secrets never reach the log"); XCTAssertTrue(entry?.arguments["note"]?.hasSuffix("(300 chars)") == true)
        XCTAssertEqual(entry?.resultRevision, 7); XCTAssertEqual(entry?.project, "/tmp/p")
        XCTAssertEqual(h.registry.list().first?.state, .completed)
    }

    func testFailedAndRefusedCallsAreAuditedWithTheirOutcome() throws {
        let h = try harness(proposeOnly: true)
        let path = try project()
        h.call(11, "rename_function", ["project": path, "address": "1000", "name": "x", "expectedRevision": 0])
        h.call(12, "no_such_tool")
        h.server.waitUntilIdle()
        XCTAssertTrue(h.text(11)?.contains("propose-only") == true); XCTAssertEqual((h.out.response(id: 11)?["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(try ProjectStore.load(path).functions[0].name, "f", "a refused edit changes nothing")
        let outcomes = Dictionary(uniqueKeysWithValues: h.audit.read().items.map { ($0.tool, $0.outcome) })
        XCTAssertEqual(outcomes["rename_function"], "refused"); XCTAssertEqual(outcomes["no_such_tool"], "error")
    }

    // MARK: Cancellation

    /// A tool that runs until cancelled (like a long decrypt sweep), checking the operation context.
    private func installWaitTool() {
        AgentTools.extra["_wait"] = { _ in
            let end = Date().addingTimeInterval(20)
            while Date() < end { try OperationContext.check(); OperationContext.progress(0.25, "waiting"); Thread.sleep(forTimeInterval: 0.02) }
            return "{}"
        }
    }

    func testClientCancellationStopsTheOperationSendsNoResponseAndLeavesTheServerResponsive() throws {
        installWaitTool(); let h = try harness()
        h.call(20, "_wait")
        XCTAssertTrue(eventually { h.registry.list().contains { $0.tool == "_wait" && $0.state == .running } })
        h.send(["jsonrpc": "2.0", "id": 21, "method": "ping"])
        XCTAssertNotNil(h.out.response(id: 21), "ping is answered while a long operation is still running")
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 20, "reason": "user stopped it"]])
        XCTAssertTrue(eventually { h.registry.list().first { $0.tool == "_wait" }?.state == .cancelled })
        h.server.waitUntilIdle()
        XCTAssertNil(h.out.response(id: 20), "MCP: a cancelled request gets no response")
        XCTAssertEqual(h.audit.read().items.first { $0.tool == "_wait" }?.outcome, "cancelled")
    }

    func testCancelOperationToolStopsAnotherOperationById() throws {
        installWaitTool(); let h = try harness()
        h.call(30, "_wait")
        XCTAssertTrue(eventually { h.registry.list().contains { $0.state == .running } })
        let opId = h.registry.list().first { $0.tool == "_wait" }!.operationId
        h.call(31, "cancel_operation", ["operationId": opId])
        XCTAssertTrue(eventually { h.registry.list().first { $0.tool == "_wait" }?.state == .cancelled })
        h.server.waitUntilIdle()
        XCTAssertTrue(h.text(31)?.contains("\"cancelled\":true") == true)
        h.call(32, "cancel_operation", ["operationId": "no-such-operation"]); h.server.waitUntilIdle()
        XCTAssertTrue(h.text(32)?.contains("\"cancelled\":false") == true)
    }

    func testCancellingTerminatesTheEngineChildProcess() throws {
        let marker = "29.\(Int.random(in: 100_000...999_999))"   // a unique sleep duration identifies our child in the process table
        AgentTools.extra["_sleep"] = { _ in _ = try ProcessRunner.run("/bin/sleep", [marker], timeout: 60); return "{}" }
        let h = try harness()
        h.call(40, "_sleep")
        func running() -> Bool { ((try? ProcessRunner.run("/bin/ps", ["-axo", "command="], timeout: 5)) ?? "").contains("sleep " + marker) }
        XCTAssertTrue(eventually { running() }, "the child process started")
        let started = Date()
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 40]])
        h.server.waitUntilIdle(timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancellation does not wait for the 29-second child")
        XCTAssertTrue(eventually { !running() }, "the child process is gone")
        XCTAssertNil(h.out.response(id: 40))
    }

    /// Regression: Ghidra's launcher script runs the JVM as a grandchild. If the root dies first the grandchild is re-parented and was
    /// never found; the process tree must be snapshotted before anything is signalled.
    func testCancellationKillsGrandchildrenEvenWhenTheRootIsKilledFirst() throws {
        let marker = "28.\(Int.random(in: 100_000...999_999))"
        AgentTools.extra["_tree"] = { _ in _ = try ProcessRunner.run("/bin/sh", ["-c", "sleep \(marker) & wait"], timeout: 60); return "{}" }
        let h = try harness()
        func alive() -> Bool { ((try? ProcessRunner.run("/bin/ps", ["-axo", "command="], timeout: 5)) ?? "").contains("sleep " + marker) }
        h.call(45, "_tree")
        XCTAssertTrue(eventually { alive() }, "the grandchild started")
        h.server.shutdown()   // what closing stdin does: cancel from the reader thread while the worker thread is also noticing the cancel
        XCTAssertTrue(eventually { !alive() }, "the grandchild must not outlive its parent")
    }

    func testClosingTheSessionCancelsEverythingStillRunning() throws {
        installWaitTool(); let h = try harness()
        h.call(50, "_wait"); h.call(51, "_wait")
        XCTAssertTrue(eventually { h.registry.list().filter { $0.state == .running }.count == 2 })
        let started = Date(); h.server.shutdown(grace: 0.3)   // a short grace first: the sleeping tools do not finish, so they are cancelled
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(h.registry.list().filter { $0.state == .cancelled }.count, 2)
    }

    /// Regression: a batch piped into `axiom mcp` (requests, then EOF) must still get every answer.
    func testShutdownWithGraceLetsFastCallsFinishBeforeCancelling() throws {
        AgentTools.extra["_slowish"] = { _ in Thread.sleep(forTimeInterval: 0.4); return #"{"done":true}"# }
        let h = try harness()
        h.call(90, "_slowish"); h.call(91, "_slowish")
        h.server.shutdown(grace: 5)
        XCTAssertNotNil(h.out.response(id: 90)); XCTAssertNotNil(h.out.response(id: 91))
        XCTAssertTrue(h.registry.list().allSatisfy { $0.state == .completed })
    }

    func testProgressNotificationsCarryTheClientsToken() throws {
        installWaitTool(); let h = try harness()
        h.call(60, "_wait", progressToken: "tok-1")
        XCTAssertTrue(eventually { !h.out.notifications("notifications/progress").isEmpty })
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 60]]); h.server.waitUntilIdle()
        let first = h.out.notifications("notifications/progress").first?["params"] as? [String: Any]
        XCTAssertEqual(first?["progressToken"] as? String, "tok-1"); XCTAssertEqual(first?["progress"] as? Double, 0.25); XCTAssertEqual(first?["message"] as? String, "waiting")
        XCTAssertLessThan(h.out.notifications("notifications/progress").count, 40, "progress is throttled")
    }

    // MARK: Audit tool, redaction

    func testAutoDecryptKeysAreRedactedInTheAuditLog() {
        XCTAssertEqual(AuditLog.summarize(arguments: ["keys": ["a", "b"], "key": "k", "wordlist": "/tmp/w.txt", "maxLines": 5, "saltHex": "00"]),
                       ["keys": "[redacted]", "key": "[redacted]", "wordlist": "/tmp/w.txt", "maxLines": "5", "saltHex": "00"])
    }

    func testAuditLogReadsNewestFirstWithFiltersAndPaging() throws {
        let log = AuditLog(directory: try tempDir())
        for i in 0..<5 { log.record(AuditEntry(operationId: "op\(i)", transport: "mcp", client: nil, tool: i % 2 == 0 ? "a" : "b", readOnly: true, arguments: [:], outcome: i == 4 ? "error" : "ok", durationMs: i)) }
        XCTAssertEqual(log.read().items.map(\.operationId), ["op4", "op3", "op2", "op1", "op0"])
        XCTAssertEqual(log.read(tool: "a").total, 3); XCTAssertEqual(log.read(outcome: "error").items.map(\.operationId), ["op4"])
        XCTAssertEqual(log.read(limit: 2, offset: 1).items.map(\.operationId), ["op3", "op2"])
        let attrs = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600, "the log is owner-only")
    }

    // MARK: Proposals

    func testProposeListAndAcceptApplyTheEditWithTheAgentAsProvenance() throws {
        let h = try harness(); let path = try project()
        h.call(70, "propose_edit", ["project": path, "kind": "rename_function", "address": "00001000", "name": "decode_header", "rationale": "reads 4 magic bytes then a length", "evidence": ["1010", "1024"]])
        h.call(71, "propose_edit", ["project": path, "kind": "annotate_address", "address": "1010", "comment": "magic check", "label": "check_magic", "rationale": "compares with 'AXIM'"])
        h.server.waitUntilIdle()
        let proposals = try ProposalStore.list(project: path, status: .pending)
        XCTAssertEqual(proposals.count, 2); XCTAssertEqual(proposals[0].source, "agent:test-client/9")
        XCTAssertEqual(try ProjectStore.load(path).functions[0].name, "f", "a proposal changes nothing until accepted")
        let result = try ProposalStore.accept(project: path, ids: [proposals[0].id])
        XCTAssertEqual(result.functions[0].name, "decode_header")
        let edit = result.edits?.last
        XCTAssertEqual(edit?.source, "agent:test-client/9"); XCTAssertEqual(edit?.rationale, "reads 4 magic bytes then a length")
        XCTAssertEqual(try ProposalStore.list(project: path).first { $0.id == proposals[0].id }?.status, .accepted)
        XCTAssertEqual(try ProposalStore.list(project: path, status: .pending).count, 1)
        h.call(72, "list_proposals", ["project": path, "status": "pending"]); h.server.waitUntilIdle()
        XCTAssertTrue(h.text(72)?.contains("annotate_address") == true)
    }

    func testProposalsAreValidatedWhenProposedNotJustWhenAccepted() throws {
        let path = try project()
        func propose(_ kind: String, address: String = "1000", name: String? = nil, label: String? = nil, variableId: String? = nil, rationale: String = "because") throws {
            try ProposalStore.propose(project: path, kind: kind, address: address, name: name, label: label, variableId: variableId, rationale: rationale, source: "agent:t")
        }
        XCTAssertThrowsError(try propose("delete_everything"))
        XCTAssertThrowsError(try propose("rename_function", address: "9999", name: "x"), "unknown function")
        XCTAssertThrowsError(try propose("annotate_address", label: "bad label"))
        XCTAssertThrowsError(try propose("change_variable", name: "x"), "variable proposals need variableId")
        XCTAssertThrowsError(try propose("rename_function", name: "x", rationale: "  "), "a rationale is required")
        XCTAssertTrue(try ProposalStore.list(project: path).isEmpty)
    }

    func testAGroupIsAcceptedAtomicallyAndAFailingMemberRollsBackTheWholeGroup() throws {
        let path = try project()
        let a = try ProposalStore.propose(project: path, kind: "rename_function", address: "1000", name: "alpha", rationale: "r", source: "agent:t", groupId: "g1")
        let b = try ProposalStore.propose(project: path, kind: "rename_function", address: "2000", name: "beta", rationale: "r", source: "agent:t", groupId: "g1")
        // Make b stale: an analyst edit removes nothing, but a second proposal group member is invalidated by deleting nothing — simulate by
        // corrupting b's stored address after validation (as if the project changed underneath the proposal).
        var all = try ProposalStore.list(project: path)
        let bIndex = all.firstIndex { $0.id == b.id }!; all[bIndex].address = "9999"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: ProposalStore.file(path), options: .atomic)
        XCTAssertThrowsError(try ProposalStore.accept(project: path, ids: [a.id]), "accepting one member means accepting the group, and the group fails as a whole")
        let after = try ProjectStore.load(path)
        XCTAssertEqual(after.functions[0].name, "f", "the valid member was rolled back too"); XCTAssertEqual(after.revision, 0)
        let statuses = try ProposalStore.list(project: path).map(\.status)
        XCTAssertEqual(statuses, [.failed, .failed])
        XCTAssertNotNil(try ProposalStore.list(project: path).first?.note)
    }

    func testRejectAndWithdraw() throws {
        let path = try project()
        let a = try ProposalStore.propose(project: path, kind: "set_comment", address: "1000", comment: "hello", rationale: "r", source: "agent:t")
        let b = try ProposalStore.propose(project: path, kind: "set_comment", address: "2000", comment: "bye", rationale: "r", source: "agent:t")
        try ProposalStore.reject(project: path, ids: [a.id], reason: "not accurate")
        try ProposalStore.withdraw(project: path, id: b.id)
        let all = try ProposalStore.list(project: path)
        XCTAssertEqual(all.map(\.status), [.rejected, .withdrawn]); XCTAssertEqual(all[0].note, "not accurate")
        XCTAssertThrowsError(try ProposalStore.accept(project: path, ids: [a.id]), "a decided proposal cannot be accepted")
        XCTAssertThrowsError(try ProposalStore.withdraw(project: path, id: a.id))
        XCTAssertEqual(try ProjectStore.load(path).functions[0].comment, "")
    }

    func testDirectEditsByAnAgentAreRecordedWithTheAgentAsSource() throws {
        let h = try harness(); let path = try project()
        h.call(80, "rename_function", ["project": path, "address": "00001000", "name": "renamed", "expectedRevision": 0]); h.server.waitUntilIdle()
        XCTAssertEqual(try ProjectStore.load(path).edits?.last?.source, "agent:test-client/9")
        XCTAssertEqual(h.audit.read().items.first?.resultRevision, 1)
    }
}
