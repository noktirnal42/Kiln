import Foundation
import Testing
import AxiomCore
@testable import Kiln

@MainActor
struct REModuleTests {
    /// Copies a system binary into a private temp dir so the test never
    /// depends on the analyzed file staying put.
    private func copySystemBinary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-re-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: dest)
        return dest
    }

    @Test func importBinaryCreatesSelectableProjectWithAnalysis() async throws {
        let module = REModule()
        let analysis = try await module.importBinary(at: try copySystemBinary())

        #expect(!analysis.sha256.isEmpty)
        #expect(analysis.size > 0)
        #expect(module.projects.count == 1)
        #expect(module.selected?.analysis?.sha256 == analysis.sha256)
    }

    @Test func importedProjectListsFunctionsAndSurvivesReload() async throws {
        let module = REModule()
        let analysis = try await module.importBinary(at: try copySystemBinary())
        let projectID = try #require(module.selected?.id)

        let reloaded = try await module.analysis(projectID: projectID)
        #expect(reloaded.sha256 == analysis.sha256)
        #expect(reloaded.functions.count == analysis.functions.count)
    }

    @Test func selectByProjectIDChangesSelection() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: try copySystemBinary())
        let id = try #require(module.projects.first?.id)

        module.select(projectID: id)
        #expect(module.selected?.id == id)
    }

    @Test func ghidraWithoutConfigurationFailsWithSpecificReason() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: try copySystemBinary())
        let id = try #require(module.projects.first?.id)

        await #expect(throws: REError.self) {
            _ = try await module.analyzeWithGhidra(projectID: id)
        }
    }

    @Test func findingsAnalysesRunOnImportedProject() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: try copySystemBinary())
        let id = try #require(module.selected?.id)

        _ = try await module.scanCrypto(projectID: id)
        _ = try await module.carveFormats(projectID: id)
        let gadgets = try await module.findGadgets(projectID: id)
        #expect(gadgets.allSatisfy { !$0.instructions.isEmpty })
        let matches = try await module.searchStrings(projectID: id, pattern: "zzz-no-such-string-\(UUID().uuidString)")
        #expect(matches.isEmpty)
    }

    @Test func strippedSystemBinaryHasLinearDisassembly() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: try copySystemBinary())
        let id = try #require(module.selected?.id)
        let listing = try await module.linearDisassembly(projectID: id)
        #expect(listing.contains("__text"))
        #expect(listing.contains("ret"))
    }

    @Test func mcpToolDefinitionsHaveUniqueNames() {
        let names = REMCPTools.definitions.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(!names.isEmpty)
    }
}
