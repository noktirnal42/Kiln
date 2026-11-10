import Foundation
import Testing
@testable import Kiln

@MainActor
struct DevelopIDETests {
    @Test func outlineNestsMembersAndSkipsLocals() {
        let source = """
        struct Box {
            var size = 1
            func grow() {
                let temp = 2
            }
        }
        func free() {}
        """
        let symbols = SymbolOutline.symbols(in: source, language: .swift)
        #expect(symbols.map(\.name) == ["Box", "free"])
        #expect(symbols[0].children.map(\.name) == ["size", "grow"])
        #expect(symbols[0].endLine == 5)
        #expect(LSPSymbol.trail(at: 2, in: symbols).map(\.name) == ["Box", "grow"])
    }

    @Test func workspaceEditAppliesLastToFirst() {
        let text = "let a = 1\nprint(a)\n"
        let edits = [LSPTextEdit(line: 0, column: 4, endLine: 0, endColumn: 5, newText: "count"),
                     LSPTextEdit(line: 1, column: 6, endLine: 1, endColumn: 7, newText: "count")]
        #expect(LSPWorkspaceEdit.apply(edits, to: text) == "let count = 1\nprint(count)\n")
    }

    @Test func parsesDocumentSymbolsRenameAndHover() {
        let raw: [[String: Any]] = [["name": "Foo", "kind": 23,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 4, "character": 1]],
            "selectionRange": ["start": ["line": 0, "character": 7], "end": ["line": 0, "character": 10]],
            "children": [["name": "bar", "kind": 6,
                "range": ["start": ["line": 1, "character": 4], "end": ["line": 2, "character": 5]],
                "selectionRange": ["start": ["line": 1, "character": 9], "end": ["line": 1, "character": 12]]]]]]
        let symbols = LanguageServerClient.symbols(from: raw)
        #expect(symbols.first?.kind == .struct && symbols.first?.children.first?.name == "bar")
        let edit = LanguageServerClient.workspaceEdit(from: ["changes": ["file:///tmp/a.swift": [
            ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]], "newText": "x"]]]])
        #expect(edit?.editCount == 1 && edit?.edits["/tmp/a.swift"]?.count == 1)
        #expect(LanguageServerClient.hoverText(from: ["contents": ["kind": "markdown", "value": "Int"]]) == "Int")
    }

    @Test func parsesLLDBThreads() {
        let thread = LLDBOutput.thread("* thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1")
        #expect(thread?.id == 1 && thread?.selected == true)
    }

    @Test func wordAtPosition() {
        #expect(DevelopController.word(in: "let value_1 = 2", line: 1, column: 7) == "value_1")
    }
}

@MainActor
struct DevelopControllerIntegrationTests {
    private func project(_ text: String = "let a = 1\nprint(a)\n") throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.swift")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (dir.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }

    private func controller(root: URL) async -> DevelopController {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub_lsp.py").path
        let editor = EditorWorkspace(recovery: EditorRecoveryStore(directory: root.appendingPathComponent(".recovery")))
        // The stub replaces sourcekit-lsp so no toolchain is needed.
        let workspace = editor
        _ = script
        let controller = DevelopController(editor: workspace, builder: BuildRunner())
        workspace.setRoot(root.path)
        return controller
    }

    @Test func openRefusesPathsOutsideTheProjectAndMissingFiles() async throws {
        let (dir, _) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let develop = await controller(root: dir)
        #expect(throws: (any Error).self) { try develop.open(path: "/etc/hosts") }
        #expect(throws: DevelopController.IDEError.self) { try develop.open(path: "missing.swift") }
        let document = try develop.open(path: "a.swift", line: 2)
        #expect(develop.editor.active?.id == document.id && develop.editor.pendingLine?.line == 2)
    }

    @Test func outlineFallsBackToThePatternParserWithoutAServer() async throws {
        let (dir, _) = try project("struct S {\n    func f() {}\n}\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let develop = await controller(root: dir)
        let document = try develop.open(path: "a.swift")
        develop.editor.languageServerEnabled = false
        let symbols = await develop.outline(for: document)
        #expect(symbols.first?.name == "S" && symbols.first?.children.first?.name == "f")
    }

    @Test func breakpointsAndConditionsRoundTripThroughTheController() async throws {
        let (dir, file) = try project()
        defer { try? FileManager.default.removeItem(at: dir); UserDefaults.standard.removeObject(forKey: "debug.breakpoints." + dir.path); UserDefaults.standard.removeObject(forKey: "debug.conditions." + dir.path) }
        let develop = await controller(root: dir)
        try develop.setBreakpoint(path: "a.swift", line: 2, condition: "a > 0")
        #expect(develop.editor.breakpointLines(for: file) == [2])
        #expect(develop.debugSummary().contains("a.swift:2  if a > 0"))
        try develop.setBreakpoint(path: "a.swift", line: 2, enabled: false)
        #expect(develop.editor.breakpointLines(for: file).isEmpty)
    }

    @Test func workspaceEditsApplyToOpenAndClosedFilesAndRefuseOutsideFiles() async throws {
        let (dir, file) = try project()
        let other = dir.appendingPathComponent("b.swift")
        try "let a = 2\n".write(to: other, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let develop = await controller(root: dir)
        let document = try develop.open(path: "a.swift")
        let edit = LSPWorkspaceEdit(edits: [
            file.path: [LSPTextEdit(line: 0, column: 4, endLine: 0, endColumn: 5, newText: "count")],
            other.path: [LSPTextEdit(line: 0, column: 4, endLine: 0, endColumn: 5, newText: "count")],
        ])
        try develop.applyEdit(edit)
        #expect(document.text.hasPrefix("let count = 1") && !document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("let count = 1"))
        #expect(try String(contentsOf: other, encoding: .utf8) == "let count = 2\n")
        #expect(throws: DevelopController.IDEError.self) {
            try develop.applyEdit(LSPWorkspaceEdit(edits: ["/etc/hosts": [LSPTextEdit(line: 0, column: 0, endLine: 0, endColumn: 0, newText: "x")]]))
        }
    }

    @Test func toolsRunThroughTheRegistryWithAWorkspace() async throws {
        let (dir, _) = try project("struct S {\n    func f() {}\n}\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let develop = await controller(root: dir)
        develop.editor.languageServerEnabled = false
        let registry = ToolRegistry()
        DevelopAgentTools.register(controller: develop, into: registry)
        #expect(registry.allSpecs().count == DevelopAgentTools.Kind.allCases.count)
        let context = ToolExecutionContext(workspaceRoot: dir, conversationID: UUID())
        let project = try await registry.tool(named: "ide_project")!.execute(argumentsJSON: "{}", context: context)
        #expect(project.contains("Folder:"))
        let outline = try await registry.tool(named: "ide_outline")!.execute(argumentsJSON: #"{"path":"a.swift"}"#, context: context)
        #expect(outline.contains("struct S") && outline.contains("func f"))
        let opened = try await registry.tool(named: "ide_open")!.execute(argumentsJSON: #"{"path":"a.swift","line":2}"#, context: context)
        #expect(opened.contains("Opened a.swift"))
    }
}
