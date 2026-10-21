import Foundation
import Testing
import AxiomCore
@testable import Kiln

@MainActor
struct REForensicsAndScriptTests {
    private func importSystemBinary(into module: REModule) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-forensics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        _ = try await module.importBinary(at: copy)
        return try #require(module.selected?.id)
    }

    @Test func ordinaryBinaryHasNoCoreDumpStructure() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        let report = try await module.dumpForensics(projectID: id)
        #expect(report.core == nil)
    }

    @Test func scriptReturnsItsFinalExpression() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        let result = try await module.runScript(projectID: id, source: "1 + 2")
        #expect(result.value == "3")
        #expect(result.output.isEmpty)
    }

    @Test func scriptSeesTheProjectBinaryPath() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        let result = try await module.runScript(projectID: id, source: "binary.endsWith('/true')")
        #expect(result.value == "true")
    }

    @Test func scriptLogLinesAreReturned() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        let result = try await module.runScript(projectID: id, source: "axiom.log('hello from script'); 7")
        #expect(result.value == "7")
        #expect(result.output.contains { $0.contains("hello from script") })
    }

    @Test func slowScriptIsAbandonedAfterItsTimeout() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)
        let started = ContinuousClock.now
        // The loop is bounded, so its worker thread finishes on its own; the caller must not wait for it.
        await #expect(throws: REError.self) {
            _ = try await module.runScript(projectID: id,
                                           source: "var i = 0; while (i < 300000000) { i++; } i",
                                           timeout: .milliseconds(100))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func thrownScriptErrorFailsInsteadOfCrashing() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        await #expect(throws: (any Error).self) {
            _ = try await module.runScript(projectID: id, source: "throw new Error('boom')")
        }
    }
}
