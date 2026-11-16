import Foundation
import SwiftData
import Testing
@testable import Kiln

struct ReplySegmenterTests {
    @Test func eachToolRoundBecomesASegmentAndTheFinalRoundDoesNot() {
        var s = ReplySegmenter()
        s.callStarted("a"); s.callStarted("b"); s.callStarted("a")
        s.roundEnded(text: "  Now the tests.  ")
        s.callStarted("c")
        s.roundEnded(text: "")
        s.roundEnded(text: "All done.") // the final reply: no calls, so no segment
        #expect(s.segments == [ReplySegment(text: "Now the tests.", callIDs: ["a", "b"]), ReplySegment(text: "", callIDs: ["c"])])
        #expect(!s.hasOpenRound)
    }
}

@MainActor
struct ReplySegmentStoreTests {
    @Test func segmentsSurviveSavingAndReloading() async throws {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let store = ConversationStore(container: container)
        let conversation = try await store.createConversation(title: "t", modelID: nil)
        let segments = [ReplySegment(text: "First I read it.", callIDs: ["c1"])]
        let saved = try #require(try await store.appendMessage(conversationID: conversation.id, role: .assistant, content: "Done", segments: segments))
        #expect(saved.segments == segments)
        let page = try await store.messages(conversationID: conversation.id, limit: 50)
        #expect(page.messages.first?.segments == segments)
        let plain = try #require(try await store.appendMessage(conversationID: conversation.id, role: .assistant, content: "old style"))
        #expect(plain.segments.isEmpty)
    }

    @Test func aRunKeepsWhatTheModelSaidBeforeEachBurst() async throws {
        let project = try PlatformTestSupport.tempDir("ws")
        try PlatformTestSupport.write("hello", to: project.appendingPathComponent("a.txt"))
        var stub = PlatformSessionFactory.Stub()
        stub.reply = { request in
            if request.messages.last?.role == .tool { return ChatMessage(role: .assistant, content: "It says hello.") }
            return ChatMessage(role: .assistant, content: "Let me read the file.", toolCalls: [ToolCall(id: "call-1", name: "read_file", arguments: #"{"path":"a.txt"}"#, index: 0)])
        }
        let session = try await PlatformSessionFactory.make(project: project, stub: stub, toolRegistry: ToolRegistry(tools: [ReadFileTool()]), autoResolve: .approveOnce)
        await session.send("what is in a.txt")
        let reply = try #require(session.messages.last)
        #expect(reply.content == "It says hello.")
        #expect(reply.segments == [ReplySegment(text: "Let me read the file.", callIDs: ["call-1"])])
        #expect(reply.toolCalls.map(\.id) == ["call-1"])
        #expect(session.liveSegments.isEmpty)
    }
}
