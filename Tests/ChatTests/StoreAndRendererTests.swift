import Foundation
import SwiftData
import Testing
@testable import SuperMetaApp

@MainActor
struct ConversationStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Workspace.self, Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    @Test func createAppendFetchRoundTrip() async throws {
        let store = ConversationStore(container: try makeContainer())
        let summary = try await store.createConversation(title: "Test", modelID: "ollama-qwen3:8b")
        #expect(summary.messageCount == 0)

        _ = try await store.appendMessage(conversationID: summary.id, role: .user, content: "hello")
        _ = try await store.appendMessage(
            conversationID: summary.id, role: .assistant, content: "hi there",
            tokenCount: 12, toolCalls: [ToolCall(id: "call_1", name: "read_file", arguments: "{}")],
            modelID: "ollama-qwen3:8b"
        )

        let page = try await store.messages(conversationID: summary.id)
        #expect(page.messages.count == 2)
        #expect(page.messages[0].role == .user)
        #expect(page.messages[1].content == "hi there")
        #expect(page.messages[1].tokenCount == 12)
        #expect(page.messages[1].toolCalls.first?.name == "read_file")
        #expect(page.messages[1].order == 1)

        let conversations = try await store.conversations()
        #expect(conversations.first?.messageCount == 2)
    }

    @Test func updateAndDeleteMessage() async throws {
        let store = ConversationStore(container: try makeContainer())
        let summary = try await store.createConversation(title: "T")
        let user = try #require(await store.appendMessage(conversationID: summary.id, role: .user, content: "before"))
        let assistant = try #require(await store.appendMessage(conversationID: summary.id, role: .assistant, content: "answer"))

        try await store.updateMessage(assistant.id, content: "updated", tokenCount: 5)
        let page = try await store.messages(conversationID: summary.id)
        #expect(page.messages[1].content == "updated")
        #expect(page.messages[1].tokenCount == 5)

        try await store.deleteMessage(user.id)
        let afterDelete = try await store.messages(conversationID: summary.id)
        #expect(afterDelete.messages.count == 1)
    }

    @Test func forkCopiesPrefixUpToMessage() async throws {
        let store = ConversationStore(container: try makeContainer())
        let summary = try await store.createConversation(title: "Original")
        _ = try await store.appendMessage(conversationID: summary.id, role: .user, content: "q1")
        let a1 = try #require(await store.appendMessage(conversationID: summary.id, role: .assistant, content: "a1"))
        _ = try await store.appendMessage(conversationID: summary.id, role: .user, content: "q2")
        let a2 = try #require(await store.appendMessage(conversationID: summary.id, role: .assistant, content: "a2"))

        let fork = try #require(await store.fork(conversationID: summary.id, atMessageID: a1.id, newTitle: "Fork"))
        #expect(fork.title == "Fork")
        let forkPage = try await store.messages(conversationID: fork.id)
        #expect(forkPage.messages.map(\.content) == ["q1", "a1"])
        #expect(forkPage.messages.map(\.order) == [0, 1])

        let original = try await store.messages(conversationID: summary.id)
        #expect(original.messages.count == 4)
        #expect(original.messages.last?.id == a2.id)
    }

    @Test func forkAtUnknownMessageReturnsNil() async throws {
        let store = ConversationStore(container: try makeContainer())
        let summary = try await store.createConversation(title: "T")
        _ = try await store.appendMessage(conversationID: summary.id, role: .user, content: "q")
        let fork = try await store.fork(conversationID: summary.id, atMessageID: UUID(), newTitle: "F")
        #expect(fork == nil)
    }

    @Test func deleteConversationCascades() async throws {
        let store = ConversationStore(container: try makeContainer())
        let summary = try await store.createConversation(title: "Doomed")
        _ = try await store.appendMessage(conversationID: summary.id, role: .user, content: "q")
        try await store.deleteConversation(summary.id)
        let page = try await store.messages(conversationID: summary.id)
        #expect(page.messages.isEmpty)
        #expect(try await store.conversations().isEmpty)
    }

    @Test func largePageIsTruncatedWithCount() async throws {
        let store = ConversationStore(container: try makeContainer())
        let summary = try await store.createConversation(title: "Big")
        for index in 0..<25 {
            _ = try await store.appendMessage(conversationID: summary.id, role: .user, content: "m\(index)")
        }
        let page = try await store.messages(conversationID: summary.id, limit: 10)
        #expect(page.truncated)
        #expect(page.total == 25)
        #expect(page.messages.count == 10)
        #expect(page.messages.last?.content == "m24")
    }
}

@MainActor
struct ArtifactStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Artifact.self, ArtifactVersion.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    @Test func createUpdateVersionHistory() async throws {
        let store = ArtifactStore(container: try makeContainer())
        let artifact = try await store.create(title: "demo.py", kind: .code, content: Data("print(1)".utf8), language: "python")
        #expect(artifact.version == 1)

        let updated = try await store.update(artifact.id, content: Data("print(2)".utf8))
        #expect(updated.version == 2)

        let versions = try await store.versions(of: artifact.id)
        #expect(versions.map(\.version) == [2, 1])

        let latest = try await store.content(of: artifact.id)
        #expect(String(decoding: latest, as: UTF8.self) == "print(2)")
        let v1 = try await store.content(of: artifact.id, version: 1)
        #expect(String(decoding: v1, as: UTF8.self) == "print(1)")
    }

    @Test func oversizeContentIsRefused() async throws {
        let store = ArtifactStore(container: try makeContainer())
        await #expect(throws: ArtifactError.tooLarge(limit: ArtifactStore.maxContentBytes)) {
            try await store.create(title: "big", kind: .code, content: Data(count: ArtifactStore.maxContentBytes + 1))
        }
    }

    @Test func missingArtifactThrowsNotFound() async throws {
        let store = ArtifactStore(container: try makeContainer())
        do {
            _ = try await store.content(of: UUID())
            Issue.record("expected notFound")
        } catch let error as ArtifactError {
            guard case .notFound = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test func deleteRemovesArtifact() async throws {
        let store = ArtifactStore(container: try makeContainer())
        let artifact = try await store.create(title: "x", kind: .markdown, content: Data("# hi".utf8))
        try await store.delete(artifact.id)
        #expect(try await store.artifacts().isEmpty)
    }
}

@MainActor
struct RendererTests {
    @Test func highlighterEmitsExpectedKinds() {
        let code = """
        // comment
        import Foundation
        func greet(name: String) -> String {
            let count = 42
            return "hello \\(name)"
        }
        """
        let spans = CodeHighlighter.highlight(code, language: "swift")
        let kinds = spans.map(\.kind)
        #expect(kinds.contains(.comment))
        #expect(kinds.contains(.keyword))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.number))
        #expect(kinds.contains(.type))

        let keywords = spans.filter { $0.kind == .keyword }.flatMap { $0.text.split(separator: " ") }
        #expect(keywords.contains("func"))
        #expect(keywords.contains("return"))
        let strings = spans.filter { $0.kind == .string }.map(\.text).joined()
        #expect(strings.contains("hello"))
    }

    @Test func markdownParsesBlocks() {
        let markdown = """
        # Title
        Some *inline* text with `code`.

        ```swift
        let x = 1
        ```

        - item one
        - item two

        | a | b |
        |---|---|
        | 1 | 2 |

        > quoted text

        ---
        """
        let blocks = MarkdownRenderer.parse(markdown)
        #expect(blocks.contains { if case .heading(let level, let text) = $0 { level == 1 && text == "Title" } else { false } })
        #expect(blocks.contains { if case .codeFence(let language, let code) = $0 { language == "swift" && code == "let x = 1" } else { false } })
        #expect(blocks.contains { if case .listItem(let ordered, let text, _) = $0 { !ordered && text == "item one" } else { false } })
        #expect(blocks.contains { if case .table(let header, let rows) = $0 { header == ["a", "b"] && rows == [["1", "2"]] } else { false } })
        #expect(blocks.contains { if case .blockquote(let text) = $0 { text == "quoted text" } else { false } })
        #expect(blocks.contains { if case .divider = $0 { true } else { false } })
        #expect(blocks.contains { if case .paragraph(let text) = $0 { text.contains("inline") } else { false } })
    }

    @Test func orderedListParsing() {
        let blocks = MarkdownRenderer.parse("3. third item")
        guard case .listItem(let ordered, let text, _)? = blocks.first else {
            Issue.record("expected list item")
            return
        }
        #expect(ordered)
        #expect(text == "third item")
    }

    @Test func dataTableParsesJSONAndCSV() throws {
        let json = try DataTableParser.parse(Data(#"[{"name":"a","value":1},{"name":"b","value":2}]"#.utf8))
        #expect(json.columns == ["name", "value"])
        #expect(json.rows.count == 2)
        #expect(json.rows[0] == ["a", "1"])

        let csv = try DataTableParser.parse(Data("name,value\n\"x,1\",2\n".utf8))
        #expect(csv.columns == ["name", "value"])
        #expect(csv.rows.first == ["x,1", "2"])
    }

    @Test func dataTableRefusesExcessRows() {
        let huge = Array(repeating: "{\"v\":1}", count: DataTableParser.maxRows + 1).joined(separator: ",")
        let payload = "[" + huge + "]"
        #expect(throws: DataTableParser.ParseError.tooManyRows(limit: DataTableParser.maxRows)) {
            _ = try DataTableParser.parse(Data(payload.utf8))
        }
    }
}
