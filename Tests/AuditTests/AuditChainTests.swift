import Foundation
import Testing
@testable import Kiln

struct AuditChainTests {
    // MARK: Helpers

    private func makeDirectory(_ label: String = "log") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-audit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func logURL(_ directory: URL) -> URL { directory.appendingPathComponent("audit-events.jsonl") }

    private func logLines(_ directory: URL) throws -> [String] {
        try String(contentsOf: logURL(directory), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func rewrite(_ directory: URL, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: logURL(directory), atomically: true, encoding: .utf8)
    }

    /// A chain with `count` events in separate log and head directories.
    private func filledChain(count: Int, log: URL, head: URL) async throws -> AuditChain {
        let chain = AuditChain(directory: log, headDirectory: head)
        for index in 1...count {
            try await chain.append(type: "tool.call", payload: ["n": .int(index), "name": "read_file"], runID: "run-1")
        }
        return chain
    }

    // MARK: Chain basics

    @Test func eventsLinkFromGenesisAndVerify() async throws {
        let chain = AuditChain(directory: makeDirectory())
        let first = try await chain.append(type: "run.started", payload: ["task": "demo"], runID: "r1")
        let second = try await chain.append(type: "tool.call", payload: ["name": "read_file", "n": 3])

        #expect(first.seq == 1)
        #expect(first.prevHash == AuditChain.genesis)
        #expect(second.seq == 2)
        #expect(second.prevHash == first.hash)

        let verification = try await chain.verify()
        #expect(verification.ok)
        #expect(verification.checked == 2)
        #expect(verification.brokenSeq == nil)
        #expect(!verification.truncated)
        #expect(verification.headHash == second.hash)
    }

    @Test func chainContinuesAcrossReopen() async throws {
        let directory = makeDirectory()
        let first = AuditChain(directory: directory)
        let a = try await first.append(type: "a")
        let b = try await first.append(type: "b")

        let reopened = AuditChain(directory: directory)
        let c = try await reopened.append(type: "c")

        #expect(c.seq == 3)
        #expect(c.prevHash == b.hash)
        #expect(a.seq == 1)
        #expect(try await reopened.verify().ok)
    }

    @Test func concurrentAppendsFormOneLinearChain() async throws {
        let chain = AuditChain(directory: makeDirectory())
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 1...40 {
                group.addTask { try await chain.append(type: "burst", payload: ["i": .int(index)]).seq }
            }
            var seen: Set<Int> = []
            for try await seq in group { seen.insert(seq) }
            #expect(seen == Set(1...40))
        }
        let verification = try await chain.verify()
        #expect(verification.ok)
        #expect(verification.checked == 40)
    }

    // MARK: Tamper detection (System5 test intent)

    @Test func alteringAHistoricalRowIsDetected() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 4, log: log, head: head)

        var lines = try logLines(log)
        lines[1] = lines[1].replacingOccurrences(of: "\"n\":2", with: "\"n\":99")
        try rewrite(log, lines)

        let verification = try await chain.verify()
        #expect(!verification.ok)
        #expect(verification.brokenSeq == 2)
        #expect(!verification.truncated)
    }

    @Test func removingTheNewestRowsIsDetectedThroughTheRecordedHead() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 5, log: log, head: head)

        // What remains is a perfectly valid shorter chain; only the head can show it shrank.
        try rewrite(log, Array(try logLines(log).prefix(3)))

        let verification = try await chain.verify()
        #expect(!verification.ok)
        #expect(verification.truncated)
        #expect(verification.expectedEvents == 5)
        #expect(verification.brokenSeq == nil)
        #expect(verification.checked == 3)
    }

    @Test func rewritingTheNewestRowWithAValidChainIsStillDetected() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 5, log: log, head: head)

        // Forge a last row whose hash is correct for its predecessor: same length, valid links,
        // different head.
        let decoder = JSONDecoder()
        var lines = try logLines(log)
        let fourth = try decoder.decode(AuditEvent.self, from: Data(lines[3].utf8))
        let fifth = try decoder.decode(AuditEvent.self, from: Data(lines[4].utf8))
        let forgedPayload: [String: AuditValue] = ["forged": true]
        let body = AuditChain.body(seq: 5, runID: fifth.runID, ts: fifth.ts, type: fifth.type, payload: forgedPayload)
        let forged = AuditEvent(seq: 5, runID: fifth.runID, ts: fifth.ts, type: fifth.type,
                                payload: forgedPayload, prevHash: fourth.hash,
                                hash: AuditChain.hash(previous: fourth.hash, body: body))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        lines[4] = String(decoding: try encoder.encode(forged), as: UTF8.self)
        try rewrite(log, lines)

        let verification = try await chain.verify()
        #expect(!verification.ok)
        #expect(verification.truncated)
        #expect(verification.brokenSeq == nil)
    }

    @Test func removingARowFromTheMiddleIsDetected() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 5, log: log, head: head)

        var lines = try logLines(log)
        lines.remove(at: 2)
        try rewrite(log, lines)

        let verification = try await chain.verify()
        #expect(!verification.ok)
        #expect(verification.brokenSeq == 4)
    }

    @Test func missingHeadStillVerifiesTheChainButReportsNoExpectation() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 3, log: log, head: head)
        try FileManager.default.removeItem(at: head.appendingPathComponent("audit-head.json"))

        let verification = try await chain.verify()
        #expect(verification.ok)
        #expect(verification.expectedEvents == nil)
    }

    @Test func untouchedChainVerifiesWithHeadRecorded() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 6, log: log, head: head)

        let verification = try await chain.verify()
        #expect(verification.ok)
        #expect(verification.expectedEvents == 6)
    }

    @Test func unreadableLineStopsAppendsAndFailsVerification() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        _ = try await filledChain(count: 2, log: log, head: head)
        var lines = try logLines(log)
        lines.append("this is not an event")
        try rewrite(log, lines)

        let fresh = AuditChain(directory: log, headDirectory: head)
        await #expect(throws: AuditError.unreadableTail(line: 3)) {
            try await fresh.append(type: "after-corruption")
        }
        let verification = try await fresh.verify()
        #expect(!verification.ok)
        #expect(verification.unreadableLine == 3)
    }

    // MARK: Summary

    @Test func summaryDoesNotRehashButStillCatchesTruncation() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        let chain = try await filledChain(count: 4, log: log, head: head)

        // An altered middle row is invisible to the cheap summary (no hashing)...
        var lines = try logLines(log)
        lines[1] = lines[1].replacingOccurrences(of: "\"n\":2", with: "\"n\":99")
        try rewrite(log, lines)
        let summary = try await chain.summary()
        #expect(summary.events == 4)
        #expect(!summary.truncated)
        // ...and caught by full verification.
        #expect(try await chain.verify().ok == false)

        // Removed rows are caught by the summary through the head comparison.
        try rewrite(log, Array(lines.prefix(2)))
        let shrunk = try await chain.summary()
        #expect(shrunk.truncated)
        #expect(shrunk.expectedEvents == 4)
    }

    // MARK: Export

    @Test func exportedBundleIsSelfConsistentAndSignable() async throws {
        let chain = AuditChain(directory: makeDirectory())
        for index in 1...3 { try await chain.append(type: "step", payload: ["i": .int(index)]) }
        let key = Data("swarm-signing-key".utf8)

        let bundle = try await chain.export(signKey: key)
        #expect(bundle.chainOK)
        #expect(bundle.count == 3)
        #expect(bundle.seqFrom == 1 && bundle.seqTo == 3)
        #expect(bundle.isSelfConsistent(signKey: key))
        #expect(!bundle.isSelfConsistent(signKey: Data("wrong-key".utf8)))
        #expect(bundle.isSelfConsistent(signKey: nil))
    }

    @Test func unsignedBundleDoesNotPassSignatureCheck() async throws {
        let chain = AuditChain(directory: makeDirectory())
        try await chain.append(type: "only")
        let bundle = try await chain.export()

        #expect(bundle.signature.isEmpty)
        #expect(bundle.isSelfConsistent())
        #expect(!bundle.isSelfConsistent(signKey: Data("key".utf8)))
    }

    @Test func tamperedBundleFailsSelfVerification() async throws {
        let chain = AuditChain(directory: makeDirectory())
        for index in 1...3 { try await chain.append(type: "step", payload: ["i": .int(index)]) }
        let bundle = try await chain.export()

        var events = bundle.events
        let original = events[1]
        events[1] = AuditEvent(seq: original.seq, runID: original.runID, ts: original.ts, type: original.type,
                               payload: ["i": 999], prevHash: original.prevHash, hash: original.hash)
        let tampered = AuditBundle(generatedAt: bundle.generatedAt, seqFrom: bundle.seqFrom, seqTo: bundle.seqTo,
                                   count: bundle.count, chainOK: true, headHash: bundle.headHash,
                                   sha256: bundle.sha256, signature: bundle.signature, events: events)

        #expect(!tampered.isSelfConsistent())
    }

    // MARK: Files

    @Test func logAndHeadFilesAreOwnerOnly() async throws {
        let log = makeDirectory("log"), head = makeDirectory("head")
        _ = try await filledChain(count: 2, log: log, head: head)

        let logMode = try FileManager.default.attributesOfItem(atPath: logURL(log).path)[.posixPermissions] as? Int
        let headMode = try FileManager.default
            .attributesOfItem(atPath: head.appendingPathComponent("audit-head.json").path)[.posixPermissions] as? Int
        #expect(logMode == 0o600)
        #expect(headMode == 0o600)
    }

    @Test func timestampsComeFromTheInjectedClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let chain = AuditChain(directory: makeDirectory(), clock: { fixed })
        let event = try await chain.append(type: "tick")
        #expect(event.ts == "2023-11-14T22:13:20.000Z")
    }

    // MARK: Canonical form

    @Test func canonicalFormSortsKeysAndEscapes() {
        let value: AuditValue = ["b": 1, "a": ["x": true, "y": nil], "s": "line\n\"quote\"\\ \u{01}"]
        #expect(value.canonical == #"{"a":{"x":true,"y":null},"b":1,"s":"line\n\"quote\"\\ \u0001"}"#)
    }

    @Test func integralDoublesAndIntegersHashAlike() {
        #expect(AuditValue.double(1.0).canonical == AuditValue.int(1).canonical)
        #expect(AuditValue.double(1.5).canonical == "1.5")
        #expect(AuditValue.double(.nan).canonical == "null")
        #expect(AuditValue.double(.infinity).canonical == "null")
    }

    @Test func payloadSurvivesJSONRoundTripWithSameCanonicalForm() throws {
        let payload: AuditValue = ["count": 3, "ratio": 0.25, "ok": true, "list": [1, "two", nil], "name": "a/b"]
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AuditValue.self, from: data)
        #expect(decoded.canonical == payload.canonical)
    }
}
