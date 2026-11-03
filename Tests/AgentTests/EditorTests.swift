import Foundation
import Testing
@testable import Kiln

@MainActor
struct EditorDocumentTests {
    private func temp(_ name: String = "a.swift", text: String = "let x = 1\n") throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (dir, file)
    }

    @Test func opensEditsAndSaves() throws {
        let (dir, file) = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = EditorDocument(url: file)
        #expect(doc.isEditable && !doc.isDirty)
        doc.text += "let y = 2\n"
        #expect(doc.isDirty)
        try doc.save()
        #expect(!doc.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let x = 1\nlet y = 2\n")
    }

    @Test func refusesToOverwriteANewerFileUnlessAsked() throws {
        let (dir, file) = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = EditorDocument(url: file)
        doc.text = "mine\n"
        try "theirs, longer\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: EditorError.changedOnDisk) { try doc.save() }
        #expect(doc.conflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs, longer\n")
        try doc.save(overwrite: true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine\n")
        #expect(!doc.conflict)
    }

    @Test func cleanDocumentsReloadAndEditedOnesConflict() throws {
        let (dir, file) = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clean = EditorDocument(url: file)
        try "changed by an agent\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(clean.checkForExternalChange() == .reloaded)
        #expect(clean.text == "changed by an agent\n")

        let edited = EditorDocument(url: file)
        edited.text = "my edit\n"
        try "another outside change, longer\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(edited.checkForExternalChange() == .conflict)
        #expect(edited.text == "my edit\n")

        try FileManager.default.removeItem(at: file)
        #expect(edited.checkForExternalChange() == .deleted)
        #expect(edited.deletedOnDisk)
    }

    @Test func binaryOversizedAndMissingFilesAreNotEditable() throws {
        let (dir, _) = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("b.bin")
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: binary)
        #expect(EditorDocument(url: binary).status == .binary)

        let big = dir.appendingPathComponent("big.txt")
        try Data(repeating: 65, count: Int(EditorDocument.maxBytes) + 1).write(to: big)
        if case .tooLarge = EditorDocument(url: big).status {} else { Issue.record("expected tooLarge") }

        let missing = EditorDocument(url: dir.appendingPathComponent("nope.txt"))
        if case .unreadable = missing.status {} else { Issue.record("expected unreadable") }
        #expect(throws: EditorError.notEditable) { try missing.save() }
    }

    @Test func savePreservesTheExecutableBit() throws {
        let (dir, file) = try temp("run.sh", text: "#!/bin/sh\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let doc = EditorDocument(url: file)
        doc.text += "echo hi\n"
        try doc.save()
        #expect((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int == 0o755)
    }

    @Test func workspaceKeepsOneDocumentPerFileAndRecoversUnsavedWork() throws {
        let (dir, file) = try temp()
        let recoveryDir = dir.appendingPathComponent("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir))
        workspace.setRoot(dir.path)
        let first = workspace.open(file)
        #expect(workspace.open(file).id == first.id)
        #expect(workspace.documents.count == 1)
        first.text = "unsaved work\n"
        workspace.writeRecovery()

        let reopened = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir))
        let restored = reopened.open(file)
        #expect(restored.text == "unsaved work\n")
        #expect(restored.isDirty && restored.restoredFromRecovery)

        // A file changed on disk since the recovery copy was written must not be clobbered by it.
        try "changed elsewhere\n".write(to: file, atomically: true, encoding: .utf8)
        let third = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir)).open(file)
        #expect(third.text == "changed elsewhere\n")
        workspace.close(first)
        #expect(workspace.documents.isEmpty)
    }

    @Test func navigatorHidesBuildOutputAndSortsFoldersFirst() throws {
        let (dir, _) = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: false)
        let workspace = EditorWorkspace(recovery: EditorRecoveryStore(directory: dir.appendingPathComponent("r")))
        workspace.setRoot(dir.path)
        let names = workspace.children(of: dir).map(\.name)
        #expect(names == ["Sources", "a.swift"])
    }
}

struct SyntaxAndBuildTests {
    @Test func highlighterClaimsCommentsAndStringsBeforeKeywords() {
        let source = "let s = \"if x\" // return\nreturn 42\n"
        let spans = SyntaxHighlighter.spans(in: source, language: .swift)
        func text(_ span: HighlightSpan) -> String { (source as NSString).substring(with: span.range) }
        #expect(spans.contains { $0.kind == .string && text($0) == "\"if x\"" })
        #expect(spans.contains { $0.kind == .comment && text($0) == "// return" })
        #expect(spans.contains { $0.kind == .number && text($0) == "42" })
        #expect(spans.filter { $0.kind == .keyword }.map(text) == ["let", "return"])
    }

    @Test func languageDetectionAndPlainText() {
        #expect(SyntaxHighlighter.language(for: URL(fileURLWithPath: "/x/Foo.swift")) == .swift)
        #expect(SyntaxHighlighter.language(for: URL(fileURLWithPath: "/x/README")) == .plain)
        #expect(SyntaxHighlighter.spans(in: "anything", language: .plain).isEmpty)
    }

    @Test func parsesCompilerDiagnostics() throws {
        let error = try #require(DiagnosticParser.parse("/p/A.swift:12:5: error: cannot find 'x' in scope"))
        #expect(error.path == "/p/A.swift" && error.line == 12 && error.column == 5 && error.severity == .error)
        let warning = try #require(DiagnosticParser.parse("main.c:3: warning: unused variable"))
        #expect(warning.line == 3 && warning.column == 1 && warning.severity == .warning)
        let spm = try #require(DiagnosticParser.parse("error: /p/Sources/F.swift:81:13 expected ':' after '? ...' in ternary expression"))
        #expect(spm.path == "/p/Sources/F.swift" && spm.line == 81 && spm.column == 13 && spm.message.hasPrefix("expected ':'"))
        #expect(DiagnosticParser.parse("error: Build failed") == nil)
        #expect(DiagnosticParser.parse("Compiling Foo.swift") == nil)
    }

    @Test func detectsBuildCommandsByProjectKind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BuildRunner.detectPlan(in: dir) == nil)
        try "".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        #expect(BuildRunner.detectPlan(in: dir)?.command == "swift build")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        #expect(BuildRunner.detectPlan(in: dir)?.command.hasPrefix("xcodebuild build -project 'App.xcodeproj'") == true)
    }

    @MainActor
    @Test func buildRunnerCapturesOutputDiagnosticsAndStatus() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = BuildRunner()
        runner.run(command: "echo 'f.py:7:2: error: boom'; echo done; exit 3", in: dir)
        for _ in 0..<100 where runner.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(!runner.isRunning && runner.lastExitStatus == 3)
        #expect(runner.output.contains("done"))
        #expect(runner.diagnostics.first?.line == 7 && runner.diagnostics.first?.path == dir.appendingPathComponent("f.py").path)
    }

    @Test func quickOpenRanksExactThenPrefixThenSubstring() {
        let files = ["/p/Sources/Editor.swift", "/p/Tests/EditorTests.swift", "/p/README.md", "/p/Sources/Render.swift"].map { URL(fileURLWithPath: $0) }
        let ranked = QuickOpenMatcher.rank(files, query: "editor", root: nil).map(\.lastPathComponent)
        #expect(ranked.first == "Editor.swift" && ranked.contains("EditorTests.swift"))
        #expect(!ranked.contains("README.md"))
        #expect(QuickOpenMatcher.rank(files, query: "rdm", root: nil).map(\.lastPathComponent) == ["README.md"])
    }
}

@MainActor
struct EditorFileOperationTests {
    private func project() throws -> (URL, EditorWorkspace) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let workspace = EditorWorkspace(recovery: EditorRecoveryStore(directory: dir.appendingPathComponent(".r")))
        workspace.setRoot(dir.path)
        return (dir, workspace)
    }

    @Test func createsRenamesAndTrashesFilesKeepingTabsInStep() throws {
        let (dir, workspace) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try workspace.createFile(named: "a.txt", in: dir)
        #expect(workspace.active?.url == file.standardizedFileURL)
        #expect(throws: EditorWorkspace.FileOperationError.self) { try workspace.createFile(named: "a.txt", in: dir) }
        #expect(throws: EditorWorkspace.FileOperationError.self) { try workspace.createFile(named: "x/y", in: dir) }

        let renamed = try workspace.rename(file, to: "b.txt")
        #expect(FileManager.default.fileExists(atPath: renamed.path) && !FileManager.default.fileExists(atPath: file.path))
        #expect(workspace.documents.map(\.name) == ["b.txt"])

        let folder = try workspace.createFolder(named: "sub", in: dir)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try workspace.trash(renamed)
        #expect(workspace.documents.isEmpty && !FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func renameRefusesWhileAnOpenFileHasUnsavedEdits() throws {
        let (dir, workspace) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try workspace.createFile(named: "c.txt", in: dir)
        workspace.active?.text = "unsaved"
        #expect(throws: EditorWorkspace.FileOperationError.self) { try workspace.rename(file, to: "d.txt") }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func projectSearchFindsLinesAndSkipsBuildOutputAndBinaries() throws {
        let (dir, _) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\nNeedle here\nthree\n".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "needle in deps".write(to: dir.appendingPathComponent("node_modules/x.js"), atomically: true, encoding: .utf8)
        try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00]).write(to: dir.appendingPathComponent("bin.dat"))

        let hits = ProjectSearch.search(root: dir, query: "needle")
        #expect(hits.count == 1)
        #expect(hits.first?.line == 2 && hits.first?.column == 1 && hits.first?.path.hasSuffix("a.swift") == true)
        #expect(ProjectSearch.search(root: dir, query: "needle", caseSensitive: true).isEmpty)
        #expect(ProjectSearch.search(root: dir, query: "").isEmpty)
    }
}
