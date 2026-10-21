import Foundation
import Testing
import AxiomCore
@testable import Kiln

@MainActor
struct REGadgetTests {
    private func importSystemBinary(into module: REModule) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-gadget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        _ = try await module.importBinary(at: copy)
        return try #require(module.selected?.id)
    }

    /// The otool file header must not become a function named after the path (regression).
    @Test func fileHeaderIsNotRecordedAsAFunction() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)
        let analysis = try await module.analysis(projectID: id)
        #expect(analysis.functions.allSatisfy { !$0.name.hasPrefix("/") })
    }

    /// Gadgets come out whether or not functions were recovered, and each chain ends in a return.
    @Test func gadgetsAreFoundAndEndInReturns() async throws {
        let module = REModule()
        let id = try await importSystemBinary(into: module)

        let gadgets = try await module.findGadgets(projectID: id)
        #expect(!gadgets.isEmpty)
        #expect(gadgets.allSatisfy { $0.instructions.last?.lowercased().hasPrefix("ret") == true })
    }
}
