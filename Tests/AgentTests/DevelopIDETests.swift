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
