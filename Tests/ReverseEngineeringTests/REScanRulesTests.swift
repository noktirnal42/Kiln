import Foundation
import Testing
import AxiomCore
@testable import Kiln

@MainActor
struct REScanRulesTests {
    private func importSystemBinary(into module: REModule) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-rules-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        _ = try await module.importBinary(at: copy)
        return try #require(module.selected?.id)
    }

    private let referenceRule = """
    rule libsystem_reference {
        strings:
            $a = "libSystem"
        condition:
            $a
    }
    """

    @Test func ruleMatchingAStringPresentInTheBinaryIsReported() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        let matches = try await module.scanRules(projectID: id, source: referenceRule)
        let match = try #require(matches.first { $0.rule == "libsystem_reference" })
        #expect(match.strings.contains { !$0.offsets.isEmpty })
    }

    @Test func ruleWithAbsentStringIsNotReported() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)
        let source = """
        rule absent {
            strings:
                $a = "zzz-not-in-any-binary-\(UUID().uuidString)"
            condition:
                $a
        }
        """

        let matches = try await module.scanRules(projectID: id, source: source)
        #expect(matches.isEmpty)
    }

    @Test func malformedRuleFailsWithSyntaxError() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        await #expect(throws: RuleSyntaxError.self) {
            _ = try await module.scanRules(projectID: id, source: "rule broken { strings: $a = ")
        }
    }
}
