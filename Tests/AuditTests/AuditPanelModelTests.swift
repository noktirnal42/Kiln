import Foundation
import Testing
@testable import Kiln

@MainActor
struct AuditPanelModelTests {
    // MARK: Helpers

    private func makeDirectory(_ label: String = "log") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-panel-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func logURL(_ directory: URL) -> URL { directory.appendingPathComponent("audit-events.jsonl") }

    private func lines(_ directory: URL) throws -> [String] {
        try String(contentsOf: logURL(directory), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func rewrite(_ directory: URL, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: logURL(directory), atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let chain: AuditChain
        let log: URL
        let health: AuditHealth
    }

    private func fixture(events: Int) async throws -> Fixture {
        let log = try makeDirectory("log")
        let head = try makeDirectory("head")
        let chain = AuditChain(directory: log, headDirectory: head)
        if events > 0 {
            for index in 1...events {
                try await chain.append(type: "tool.call", payload: ["n": .int(index)], runID: "run-1")
            }
        }
        return Fixture(chain: chain, log: log, health: AuditHealth())
    }

    private func model(_ f: Fixture, settings: SettingsService? = nil) -> AuditPanelModel {
        AuditPanelModel(chain: f.chain, health: f.health, settings: settings)
    }

    private func event(_ type: String, _ payload: [String: AuditValue] = [:]) -> AuditEvent {
        AuditEvent(seq: 1, runID: "r", ts: "2026-10-30T22:00:00.000Z", type: type, payload: payload,
                   prevHash: AuditChain.genesis, hash: "h")
    }

    // MARK: Status honesty

    @Test func withNoChainThereIsNothingToVerifyAndNoCrash() async {
        let model = AuditPanelModel(chain: nil, health: nil, settings: nil)
        await model.refresh()
        await model.verify()

        #expect(model.chainStatus == .noChain)
        #expect(!model.hasChain)
        #expect(model.recentEvents.isEmpty)
    }

    @Test func aFreshChainIsNotVerifiedUntilSomeoneAsks() async throws {
        let f = try await fixture(events: 3)
        let model = model(f)
        await model.refresh()

        #expect(model.summary?.events == 3)
        #expect(model.chainStatus == .notVerified, "showing OK without verifying would be a fake capability")
        #expect(model.verifiedAt == nil)
    }

    @Test func verifyingAnIntactChainReportsItAsIntact() async throws {
        let f = try await fixture(events: 4)
        let model = model(f)
        await model.verify()

        #expect(model.chainStatus == .intact(checked: 4))
        #expect(model.verifiedAt != nil)
    }

    @Test func verifyingATamperedChainNamesTheBrokenRow() async throws {
        let f = try await fixture(events: 4)
        var rows = try lines(f.log)
        rows[1] = rows[1].replacingOccurrences(of: "\"n\":2", with: "\"n\":99")
        try rewrite(f.log, rows)

        let model = model(f)
        await model.verify()
        #expect(model.chainStatus == .tampered(brokenSeq: 2))
    }

    @Test func removedRowsShowAfterAPlainRefreshWithoutRehashing() async throws {
        let f = try await fixture(events: 5)
        try rewrite(f.log, Array(try lines(f.log).prefix(3)))

        let model = model(f)
        await model.refresh()
        #expect(model.chainStatus == .truncated(expectedEvents: 5), "the cheap summary already catches this")
    }

    @Test func aGarbageLineIsReportedAsUnreadable() async throws {
        let f = try await fixture(events: 2)
        try rewrite(f.log, try lines(f.log) + ["not an event"])

        let model = model(f)
        await model.verify()
        #expect(model.chainStatus == .unreadable(line: 3))
    }

    // MARK: Recent events

    @Test func recentEventsAreNewestFirstAndLimited() async throws {
        let f = try await fixture(events: 55)
        let model = model(f)
        await model.refresh()

        #expect(model.recentEvents.count == AuditPanelModel.recentLimit)
        #expect(model.recentEvents.first?.id == 55)
        #expect(model.recentEvents.last?.id == 55 - AuditPanelModel.recentLimit + 1)
    }

    // MARK: Dropped entries

    @Test func droppedEntriesAreSurfacedWithTheLastFailure() async throws {
        let f = try await fixture(events: 1)
        f.health.note(AuditError.unreadableTail(line: 7))

        let model = model(f)
        await model.refresh()
        #expect(model.droppedEntries == 1)
        #expect(model.lastFailure?.contains("line 7") == true)
    }

    @Test func aRecorderReportsRefusedAppendsToTheSharedHealth() async throws {
        let log = try makeDirectory("log")
        try "not an event\n".write(to: logURL(log), atomically: true, encoding: .utf8)
        let health = AuditHealth()
        let recorder = AgentAuditRecorder(chain: AuditChain(directory: log), health: health)
        recorder.record("a")
        recorder.record("b")
        await recorder.finish()

        #expect(health.snapshot.dropped == 2)
        #expect(health.snapshot.lastFailure != nil)
    }

    // MARK: Export

    @Test func anExportedBundleVerifiesFromItsOwnContents() async throws {
        let f = try await fixture(events: 3)
        let url = try makeDirectory("out").appendingPathComponent("bundle.json")
        let model = model(f)
        await model.export(to: url)

        let bundle = try JSONDecoder().decode(AuditBundle.self, from: Data(contentsOf: url))
        #expect(bundle.count == 3)
        #expect(bundle.isSelfConsistent())
        #expect(model.exportStatus?.contains("intact") == true)
        #expect(model.errorMessage == nil)
    }

    @Test func aSignedExportCarriesAVerifiableSignature() async throws {
        let f = try await fixture(events: 2)
        let url = try makeDirectory("out").appendingPathComponent("signed.json")
        let key = Data("panel-signing-key".utf8)
        let model = model(f)
        await model.export(to: url, signKey: key)

        let bundle = try JSONDecoder().decode(AuditBundle.self, from: Data(contentsOf: url))
        #expect(bundle.isSelfConsistent(signKey: key))
        #expect(!bundle.isSelfConsistent(signKey: Data("other".utf8)))
    }

    @Test func aBrokenChainIsStillExportedAndTheStatusSaysSo() async throws {
        let f = try await fixture(events: 3)
        var rows = try lines(f.log)
        rows[1] = rows[1].replacingOccurrences(of: "\"n\":2", with: "\"n\":99")
        try rewrite(f.log, rows)
        let url = try makeDirectory("out").appendingPathComponent("broken.json")

        let model = model(f)
        await model.export(to: url)

        let bundle = try JSONDecoder().decode(AuditBundle.self, from: Data(contentsOf: url))
        #expect(!bundle.chainOK)
        #expect(!bundle.isSelfConsistent())
        #expect(model.exportStatus?.contains("NOT intact") == true)
    }

    @Test func anExportThatCannotBeWrittenSurfacesTheError() async throws {
        let f = try await fixture(events: 1)
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/bundle.json")
        let model = model(f)
        await model.export(to: url)

        #expect(model.errorMessage != nil)
        #expect(model.exportStatus == nil)
    }

    // MARK: Rubric settings

    @Test func rubricSettingsAreTrimmedPersistedAndReadBack() async throws {
        let f = try await fixture(events: 0)
        let configURL = try makeDirectory("config").appendingPathComponent("settings.json")
        let settings = SettingsService(userConfigURL: configURL)

        let writer = model(f, settings: settings)
        writer.rubricModel = "  claude-haiku-5-5  "
        writer.rubricFallbackModel = " claude-sonnet-5-5 "
        await writer.saveRubricSettings()
        #expect(writer.rubricModel == "claude-haiku-5-5")
        #expect(writer.settingsStatus?.contains("next agent run") == true)

        let reader = model(f, settings: SettingsService(userConfigURL: configURL))
        await reader.refresh()
        #expect(reader.rubricModel == "claude-haiku-5-5")
        #expect(reader.rubricFallbackModel == "claude-sonnet-5-5")
    }

    @Test func clearingTheRubricModelTurnsTheModelPassOff() async throws {
        let f = try await fixture(events: 0)
        let settings = SettingsService(userConfigURL: try makeDirectory("config").appendingPathComponent("s.json"))
        let model = model(f, settings: settings)
        model.rubricModel = "some-model"
        await model.saveRubricSettings()

        model.rubricModel = "   "
        await model.saveRubricSettings()
        #expect(model.rubricModel.isEmpty)
        #expect(model.settingsStatus?.contains("off") == true)
        #expect(await settings.get(AuditPanelModel.rubricModelKey, as: String.self, fallback: "x") == "")
    }

    // MARK: Row text (pure)

    @Test func eventDetailsReadAsOneLinePerType() {
        let call = event("tool.call", [
            "tool": "write_file",
            "arguments": ["values": ["path": "notes.txt"], "other_keys": ["content"]],
        ])
        #expect(AuditPanelModel.detail(for: call) == "write_file path=notes.txt")
        #expect(AuditPanelModel.detail(for: event("tool.result", ["tool": "write_file", "status": "succeeded"])) == "write_file → succeeded")
        #expect(AuditPanelModel.detail(for: event("policy.denied", ["tool": "write_file", "rule": "write_scope"])) == "write_file · rule write_scope")
        #expect(AuditPanelModel.detail(for: event("approval.resolved", ["approved": false])) == "declined")
        #expect(AuditPanelModel.detail(for: event("monitor.paused", ["tool": "read_file", "severity": 7])) == "read_file held · severity 7")
        #expect(AuditPanelModel.detail(for: event("monitor.flag", ["category": "credential_access", "severity": 7, "rationale": "outside"]))
                == "[credential_access 7] outside")
        #expect(AuditPanelModel.detail(for: event("agent.run.finished", ["rounds": 2, "tool_calls_executed": 1, "tool_calls_denied": 0]))
                == "2 rounds · 1 tool calls · 0 denied")
    }

    @Test func unknownEventTypesListTheirPayloadKeys() {
        #expect(AuditPanelModel.detail(for: event("future.thing", ["b": 1, "a": 2])) == "a, b")
    }

    @Test func attentionMarksDenialsHoldsAndSevereFlagsOnly() {
        #expect(AuditPanelModel.needsAttention(event("policy.denied")))
        #expect(AuditPanelModel.needsAttention(event("monitor.paused")))
        #expect(AuditPanelModel.needsAttention(event("agent.run.failed")))
        #expect(AuditPanelModel.needsAttention(event("monitor.flag", ["severity": 6])))
        #expect(!AuditPanelModel.needsAttention(event("monitor.flag", ["severity": 2])))
        #expect(!AuditPanelModel.needsAttention(event("tool.call")))
    }

    @Test func rowsParseTheirTimestamp() {
        let row = AuditPanelModel.row(event("agent.round", ["round": 1]))
        #expect(row.timestamp != nil)
        #expect(row.detail == "round 1")
    }
}
