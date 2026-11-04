import Foundation
import Testing
@testable import Kiln

@Suite("Offering an outside folder as a project")
struct OutsideFolderTests {
    private func makeDirs() throws -> (workspace: URL, other: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-offer-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("work"), other = base.appendingPathComponent("other/project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        return (workspace, other)
    }
    private func offer(_ tool: String, _ path: String, _ root: URL) -> URL? {
        Tripwires.folderToOffer(tool: tool, argumentsJSON: #"{"path":"\#(path)"}"#, workspaceRoot: root)
    }

    @Test("a read of an outside directory offers that directory") func directory() throws {
        let d = try makeDirs()
        #expect(offer("list_directory", d.other.path, d.workspace)?.standardizedFileURL.path == d.other.resolvingSymlinksInPath().path)
    }
    @Test("a read of an outside file offers its folder") func file() throws {
        let d = try makeDirs()
        let file = d.other.appendingPathComponent("a.swift"); try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(offer("read_file", file.path, d.workspace)?.lastPathComponent == "project")
    }
    @Test("paths inside the workspace offer nothing") func inside() throws {
        let d = try makeDirs()
        #expect(offer("read_file", d.workspace.appendingPathComponent("a.txt").path, d.workspace) == nil)
    }
    @Test("credential folders, the disk root and the home folder are never offered") func neverOffered() throws {
        let d = try makeDirs()
        #expect(offer("list_directory", NSHomeDirectory() + "/.ssh", d.workspace) == nil)
        #expect(offer("list_directory", "/", d.workspace) == nil)
        #expect(offer("list_directory", NSHomeDirectory(), d.workspace) == nil)
    }
    @Test("tools that are not path tools offer nothing") func notPathTool() throws {
        let d = try makeDirs()
        #expect(offer("run_shell", d.other.path, d.workspace) == nil)
    }
}
