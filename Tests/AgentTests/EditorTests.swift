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

    @Test func recoverableFilesAreListedUntilOpenedOrDiscarded() throws {
        let (dir, file) = try temp()
        let recoveryDir = dir.appendingPathComponent("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir))
        first.setRoot(dir.path)
        first.open(file).text = "work in progress\n"
        first.writeRecovery()

        let next = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir))
        next.refreshRecoverable()
        #expect(next.recoverable.map(\.lastPathComponent) == ["a.swift"])
        next.restoreRecoverable()
        #expect(next.active?.text == "work in progress\n" && next.recoverable.isEmpty)

        let again = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir))
        again.refreshRecoverable()
        again.discardRecoverable()
        let last = EditorWorkspace(recovery: EditorRecoveryStore(directory: recoveryDir))
        last.refreshRecoverable()
        #expect(last.recoverable.isEmpty)
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

@MainActor
struct EditorSettingsAndSplitTests {
    @Test func settingsPersistAndAreClamped() {
        let suiteName = "kiln-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let a = EditorSettings(defaults: defaults)
        #expect(a.fontSize == 13 && a.tabWidth == 4 && a.insertSpaces && !a.softWrap && a.showLineNumbers)
        a.fontSize = 18; a.tabWidth = 2; a.softWrap = true; a.insertSpaces = false
        let b = EditorSettings(defaults: defaults)
        #expect(b.fontSize == 18 && b.tabWidth == 2 && b.softWrap && b.indentUnit == "\t")
        defaults.set(500.0, forKey: "editor.fontSize"); defaults.set(7, forKey: "editor.tabWidth")
        let c = EditorSettings(defaults: defaults)
        #expect(c.fontSize == 32 && c.tabWidth == 4)
    }

    @Test func fontFamilyAndThemePersistAndFallBack() {
        let suiteName = "kiln-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let a = EditorSettings(defaults: defaults)
        #expect(a.fontFamily == .system && a.theme == .system)
        a.fontFamily = .menlo; a.theme = .dark
        let b = EditorSettings(defaults: defaults)
        #expect(b.fontFamily == .menlo && b.theme == .dark)
        #expect(b.theme.appearance?.name == .darkAqua && EditorTheme.system.appearance == nil)
        defaults.set("Nonexistent", forKey: "editor.fontFamily"); defaults.set("x", forKey: "editor.theme")
        let c = EditorSettings(defaults: defaults)
        #expect(c.fontFamily == .system && c.theme == .system)
        for family in EditorFontFamily.allCases { #expect(family.font(size: 14).pointSize == 14) }
        #expect(EditorFontFamily.system.isAvailable)
    }

    @Test func bracketMatcherPairsNestedBracketsBothWays() {
        let text = "f(a[1], {b: (c)})"
        let open = (text as NSString).range(of: "(").location
        let match = BracketMatcher.match(in: text, caret: open + 1)
        #expect(match?.1.location == (text as NSString).length - 1)
        let close = BracketMatcher.match(in: text, caret: (text as NSString).length)
        #expect(close?.1.location == open)
        #expect(BracketMatcher.match(in: "plain text", caret: 3) == nil)
    }

    @Test func aDroppedTabTakesTheSecondPaneButNotTheActiveOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = EditorWorkspace(recovery: EditorRecoveryStore(directory: dir.appendingPathComponent(".r")))
        let a = try workspace.createFile(named: "a.txt", in: dir)
        let b = try workspace.createFile(named: "b.txt", in: dir)
        let docA = try #require(workspace.documents.first { $0.url == a.standardizedFileURL })
        let docB = try #require(workspace.documents.first { $0.url == b.standardizedFileURL })
        workspace.activeID = docA.id
        #expect(!workspace.openInSplit(id: docA.id))
        #expect(!workspace.openInSplit(id: UUID()))
        #expect(workspace.openInSplit(id: docB.id))
        #expect(workspace.secondary?.id == docB.id)
    }

    @Test func splitShowsASecondDocumentAndClosesWithIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = EditorWorkspace(recovery: EditorRecoveryStore(directory: dir.appendingPathComponent(".r")))
        let a = try workspace.createFile(named: "a.txt", in: dir)
        let b = try workspace.createFile(named: "b.txt", in: dir)
        let docA = try #require(workspace.documents.first { $0.url == a.standardizedFileURL })
        workspace.activeID = workspace.documents.first { $0.url == b.standardizedFileURL }?.id
        workspace.openInSplit(docA)
        #expect(workspace.secondary?.id == docA.id)
        workspace.close(docA)
        #expect(workspace.secondary == nil)
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
        let issue = try #require(DiagnosticParser.parse("✘ Test failsOnPurpose() recorded an issue at helloTests.swift:3:31: Expectation failed: 1 + 1 == 3"))
        #expect(issue.path == "helloTests.swift" && issue.line == 3 && issue.column == 31 && issue.message.hasPrefix("Expectation failed"))
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

struct LineDiffTests {
    @Test func classifiesAddedModifiedAndRemovedLines() {
        let base = ["a", "b", "c", "d", "e"]
        let current = ["a", "B", "c", "new", "d"]      // b→B modified, "new" added, e removed
        let hunks = LineDiff.hunks(base: base, current: current)
        #expect(hunks.map(\.kind) == [.modified, .added, .removed])
        #expect(hunks[0].current == 1..<2 && hunks[0].base == ["b"])
        #expect(hunks[1].current == 3..<4)
        #expect(hunks[2].base == ["e"] && hunks[2].current == 5..<5)
        #expect(LineDiff.hunks(base: base, current: base).isEmpty)
    }

    @Test func revertsAHunkBackToTheCommittedLines() {
        let base = ["a", "b", "c"]
        let text = "a\nB\nB2\nc"
        let hunks = LineDiff.hunks(base: base, current: text.components(separatedBy: "\n"))
        #expect(hunks.count == 1)
        #expect(LineDiff.revert(hunks[0], in: text) == "a\nb\nc")
        #expect(LineDiff.hunk(at: 2, in: hunks) == hunks[0] && LineDiff.hunk(at: 0, in: hunks) == nil)
    }

    @Test func removalsAreRestoredAtTheirPosition() {
        let base = ["a", "b", "c"]
        let text = "a\nc"
        let hunk = LineDiff.hunks(base: base, current: text.components(separatedBy: "\n"))[0]
        #expect(hunk.kind == .removed)
        #expect(LineDiff.revert(hunk, in: text) == "a\nb\nc")
    }
}

struct ProjectCommandTests {
    @Test func parsesXcodebuildListAndPackageDescription() {
        let list = #"{"project":{"configurations":["Debug","Release"],"name":"App","schemes":["App","AppTests"],"targets":["App"]}}"#
        let parsed = ProjectInfo.parseXcodebuildList(Data(list.utf8))
        #expect(parsed.schemes == ["App", "AppTests"] && parsed.configurations == ["Debug", "Release"])
        let description = #"{"products":[{"name":"tool","type":{"executable":null}},{"name":"Lib","type":{"library":["automatic"]}}]}"#
        #expect(ProjectInfo.parsePackageDescription(Data(description.utf8)) == ["tool"])
        #expect(ProjectInfo.parseXcodebuildList(Data("garbage".utf8)).schemes.isEmpty)
    }

    @Test func buildTestAndRunCommandsFollowTheSelection() throws {
        let xcode = ProjectInfo(kind: .xcodeProject, container: "My App.xcodeproj", schemes: ["Mac", "Mac Tests"], configurations: ["Debug", "Release"], executables: [])
        let selection = BuildSelection(scheme: "Mac Tests", configuration: "Release")
        let build = try #require(ProjectCommands.build(info: xcode, selection: selection))
        #expect(build.command == "xcodebuild build -project 'My App.xcodeproj' -scheme 'Mac Tests' -destination 'platform=macOS' -configuration 'Release'")
        let test = try #require(ProjectCommands.test(info: xcode, selection: selection, filter: "Mac Tests/Foo/testBar"))
        #expect(test.command.hasSuffix("-only-testing:'Mac Tests/Foo/testBar'"))
        let run = try #require(ProjectCommands.run(info: xcode, selection: selection))
        #expect(run.command.contains("-showBuildSettings") && run.command.contains("exec \"$D/$X\""))

        let package = ProjectInfo(kind: .swiftPackage, container: "Package.swift", schemes: [], configurations: ["debug", "release"], executables: ["tool"])
        #expect(ProjectCommands.build(info: package, selection: BuildSelection(scheme: nil, configuration: "release"))?.command == "swift build -c release")
        #expect(ProjectCommands.test(info: package, selection: BuildSelection(), filter: "Suite/test")?.command == "swift test --filter 'Suite/test'")
        #expect(ProjectCommands.run(info: package, selection: BuildSelection())?.command == "swift run 'tool'")
        #expect(ProjectCommands.build(info: .empty, selection: BuildSelection()) == nil)
    }

    @Test func parsesXCTestAndSwiftTestingOutput() {
        let output = """
        Test Case '-[AppTests.FooTests testA]' passed (0.012 seconds).
        Test Case '-[AppTests.FooTests testB]' failed (0.500 seconds).
        ✔ Test mergesByLaunchIdentity() passed after 0.001 seconds.
        ✘ Test brokenThing() recorded an issue at T.swift:3:31: Expectation failed: 1 + 1 == 3
        ✘ Test brokenThing() failed after 0.200 seconds with 1 issue.
        ✘ Test run with 2 tests in 0 suites failed after 0.201 seconds with 1 issue.
        random noise
        """
        let results = TestOutputParser.parse(output)
        #expect(results.map(\.name) == ["AppTests.FooTests testA", "AppTests.FooTests testB", "mergesByLaunchIdentity()", "brokenThing()"])
        #expect(results.filter { $0.status == .failed }.count == 2)
        #expect(results.first?.seconds == 0.012)
    }

    @Test func selectionIsRememberedPerProject() {
        let suite = "kiln-sel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }   // every run used to leave a plist in ~/Library/Preferences
        let root = URL(fileURLWithPath: "/tmp/proj-a")
        BuildSelection(scheme: "S", configuration: "Release").save(for: root, defaults: defaults)
        #expect(BuildSelection.load(for: root, defaults: defaults) == BuildSelection(scheme: "S", configuration: "Release"))
        #expect(BuildSelection.load(for: URL(fileURLWithPath: "/tmp/proj-b"), defaults: defaults) == BuildSelection())
    }
}

@MainActor
struct LanguageServerTests {
    @Test func framerSplitsMessagesAcrossArbitraryChunks() {
        var framer = LSPFramer()
        let a = LSPFramer.encode(["jsonrpc": "2.0", "id": 1, "result": "x"])
        let b = LSPFramer.encode(["jsonrpc": "2.0", "method": "m"])
        let all = a + b
        var out: [[String: Any]] = []
        for start in stride(from: 0, to: all.count, by: 7) { out += framer.feed(all[start..<min(start + 7, all.count)]) }
        #expect(out.count == 2 && out[0]["id"] as? Int == 1 && out[1]["method"] as? String == "m")
    }

    @Test func talksToAStubServerForDiagnosticsDefinitionAndCompletion() async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub_lsp.py").path
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-lsp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.swift")
        let client = LanguageServerClient(command: "python3 '\(script)'")
        await client.start(root: dir)
        #expect(client.state == .running)
        client.didOpen(url: file, text: "let a = 1\n")
        for _ in 0..<100 where client.diagnostics[file.path] == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let diagnostic = try #require(client.diagnostics[file.path]?.first)
        #expect(diagnostic.line == 2 && diagnostic.column == 4 && diagnostic.severity == .error && diagnostic.message == "stub error")
        let definition = try #require(await client.definition(url: file, line: 0, column: 4))
        #expect(definition == LSPLocation(path: file.path, line: 7, column: 1))
        let items = await client.completions(url: file, line: 0, column: 1)
        #expect(items.map(\.label) == ["alpha", "beta"] && items[1].insertText == "beta()")
        client.stop()
        #expect(client.state == .stopped)
    }

    @Test func aMissingServerFailsCleanlyInsteadOfHanging() async {
        let client = LanguageServerClient(command: "definitely-not-a-real-server-binary")
        await client.start(root: FileManager.default.temporaryDirectory)
        if case .failed = client.state {} else { Issue.record("expected failed, got \(client.state)") }
        #expect(await client.definition(url: URL(fileURLWithPath: "/x.swift"), line: 0, column: 0) == nil)
    }

    @Test func mapsDiagnosticSeverityAndLocations() {
        let raw: [[String: Any]] = [["range": ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]], "severity": 2, "message": "w"]]
        #expect(LanguageServerClient.diagnostics(from: raw).first?.severity == .warning)
        let link: [[String: Any]] = [["targetUri": "file:///tmp/x.swift", "targetSelectionRange": ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 6]]]]
        #expect(LanguageServerClient.location(from: link) == LSPLocation(path: "/tmp/x.swift", line: 3, column: 4))
    }
}

@MainActor
struct TabOrderAndMultiCursorTests {
    @Test func tabsReorderBeforeATargetOrToTheEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = EditorWorkspace(recovery: EditorRecoveryStore(directory: dir.appendingPathComponent("r")))
        let docs = try ["a", "b", "c"].map { name -> EditorDocument in
            let url = dir.appendingPathComponent("\(name).txt")
            try name.write(to: url, atomically: true, encoding: .utf8)
            return workspace.open(url)
        }
        workspace.moveDocument(docs[2].id, before: docs[0].id)
        #expect(workspace.documents.map(\.name) == ["c.txt", "a.txt", "b.txt"])
        workspace.moveDocument(docs[2].id, before: nil)
        #expect(workspace.documents.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        workspace.moveDocument(docs[1].id, before: docs[1].id)
        workspace.moveDocument(UUID(), before: docs[0].id)
        #expect(workspace.documents.count == 3)
    }

    @Test func commandDSelectsTheWordThenEachNextOccurrenceWithWrap() {
        let text = "foo bar foo baz foo" as NSString
        let word = MultiCursor.nextSelection(in: text, selected: [NSRange(location: 1, length: 0)])
        #expect(word == NSRange(location: 0, length: 3))
        let second = MultiCursor.nextSelection(in: text, selected: [word!])
        #expect(second == NSRange(location: 8, length: 3))
        let third = MultiCursor.nextSelection(in: text, selected: [word!, second!])
        #expect(third == NSRange(location: 16, length: 3))
        // Everything already selected: nothing more to add.
        #expect(MultiCursor.nextSelection(in: "foo foo" as NSString, selected: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)]) == nil)
        #expect(MultiCursor.nextSelection(in: " " as NSString, selected: [NSRange(location: 0, length: 0)]) == nil)
    }
}

struct CodeFoldingTests {
    @Test func bracesFoldBodiesAndKeepTheClosingLine() {
        let code = "func a() {\n  let x = 1\n  if x {\n    print(x)\n  }\n}\nlet y = 2\n"
        let regions = CodeFolding.regions(in: code, indentationBased: false)
        #expect(regions == [FoldRegion(startLine: 0, lastHiddenLine: 4), FoldRegion(startLine: 2, lastHiddenLine: 3)])
        #expect(CodeFolding.innermost(containing: 3, in: regions)?.startLine == 2)
    }

    @Test func bracesInStringsAndCommentsAreIgnored() {
        let code = "let s = \"{\"\n// {\n/* { */\nfunc f() {\n  1\n}\n"
        #expect(CodeFolding.regions(in: code, indentationBased: false) == [FoldRegion(startLine: 3, lastHiddenLine: 4)])
    }

    @Test func oneLineBlocksAreNotFoldable() {
        #expect(CodeFolding.regions(in: "a {\n}\nb { c }\n", indentationBased: false).isEmpty)
    }

    @Test func indentationBlocksFoldPythonStyle() {
        let code = "def f():\n    x = 1\n\n    return x\n\nprint(f())\n"
        #expect(CodeFolding.regions(in: code, indentationBased: true) == [FoldRegion(startLine: 0, lastHiddenLine: 3)])
    }

    @Test func hiddenRangesKeepTheStartLineAndTheLineAfter() {
        let text = "a {\nb\nc\n}\nd" as NSString
        let regions = CodeFolding.regions(in: text as String, indentationBased: false)
        let hidden = CodeFolding.hiddenRanges(in: text, folded: regions)
        #expect(hidden == [NSRange(location: 4, length: 4)])   // "b\nc\n"
        let visible = text.replacingCharacters(in: hidden[0], with: "")
        #expect(visible == "a {\n}\nd")
    }

    @Test func nestedFoldsMerge() {
        let text = "a {\n b {\n c\n }\n}\n" as NSString
        let regions = CodeFolding.regions(in: text as String, indentationBased: false)
        #expect(CodeFolding.hiddenRanges(in: text, folded: regions).count == 1)
    }
}

@Suite("Gutter accessibility")
struct GutterAccessibilityTests {
    @Test("unmarked lines have no element") func unmarked() {
        #expect(GutterAccessibility.label(line: 3, foldable: false, folded: false, breakpoint: false, executing: false, change: nil) == nil)
    }

    @Test("markers are spoken together") func markers() {
        let label = GutterAccessibility.label(line: 7, foldable: true, folded: true, breakpoint: true, executing: false, change: "modified since commit")
        #expect(label == "Line 7, breakpoint, modified since commit, folded block, press to expand")
        #expect(GutterAccessibility.label(line: 1, foldable: true, folded: false, breakpoint: false, executing: false, change: nil)
                == "Line 1, foldable block, press to fold")
    }
}
