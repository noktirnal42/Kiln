import Foundation
import Testing
import AxiomCore
@testable import Kiln

@MainActor
struct REAnnotationTests {
    private func importSystemBinary(into module: REModule) async throws -> (id: String, analysis: Analysis) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-annotation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        let analysis = try await module.importBinary(at: copy)
        return (try #require(module.selected?.id), analysis)
    }

    @Test func addressNoteEditCanBeUndoneAndRedone() async throws {
        let module = REModule()
        let (id, initial) = try await importSystemBinary(into: module)
        let address = "0x100000368"

        let edited = try await module.editProject(
            projectID: id, expectedRevision: initial.revision,
            operations: [.addressNote(address: address, comment: "entry", label: nil)]
        )
        #expect(edited.revision > initial.revision)
        #expect(edited.addressComments?.values.contains("entry") == true)

        let undone = try await module.undo(projectID: id, expectedRevision: edited.revision)
        #expect(undone.addressComments?.values.contains("entry") != true)
        #expect(!(undone.undone ?? []).isEmpty)

        let redone = try await module.redo(projectID: id, expectedRevision: undone.revision)
        #expect(redone.addressComments?.values.contains("entry") == true)
    }

    @Test func staleRevisionIsRefusedInsteadOfOverwriting() async throws {
        let module = REModule()
        let (id, initial) = try await importSystemBinary(into: module)

        _ = try await module.editProject(
            projectID: id, expectedRevision: initial.revision,
            operations: [.addressNote(address: "0x100000368", comment: "first", label: nil)]
        )
        // The first edit moved the revision on; a second edit still holding the old revision must fail.
        await #expect(throws: (any Error).self) {
            _ = try await module.editProject(
                projectID: id, expectedRevision: initial.revision,
                operations: [.addressNote(address: "0x100000368", comment: "second", label: nil)]
            )
        }
    }

    /// Bookmarks belong to functions. A stripped binary has none, so a bookmark there must be refused, not recorded.
    @Test func bookmarkNeedsARecoveredFunction() async throws {
        let module = REModule()
        let (id, initial) = try await importSystemBinary(into: module)

        await #expect(throws: (any Error).self) {
            _ = try await module.toggleBookmark(projectID: id, expectedRevision: initial.revision, address: "0x100000368")
        }
    }
}
