import Foundation
import Testing
@testable import Kiln

@MainActor
final class FakeAttention: AttentionSink {
    var asked: [String] = []
    var clearedCounts: [Int] = []
    func needsApproval(tool: String, conversation: String, pending: Int) { asked.append("\(tool):\(pending)") }
    func cleared(pending: Int) { clearedCounts.append(pending) }
}

@MainActor
struct SessionsTests {
    @Test func rowsPutBusySessionsFirst() {
        let now = Date()
        let a = ConversationSummary(id: UUID(), title: "old idle", modelID: nil, createdAt: now, updatedAt: now.addingTimeInterval(-100), messageCount: 2)
        let b = ConversationSummary(id: UUID(), title: "new idle", modelID: nil, createdAt: now, updatedAt: now, messageCount: 2)
        let c = ConversationSummary(id: UUID(), title: "waiting", modelID: nil, createdAt: now, updatedAt: now.addingTimeInterval(-500), messageCount: 2)
        let rows = SessionList.rows([a, b, c], states: [c.id: .waitingForApproval], open: b.id)
        #expect(rows.map(\.title) == ["waiting", "new idle", "old idle"])
        #expect(rows[1].isOpen && rows[0].state == .waitingForApproval)
    }

    @Test func approvalWaitRaisesAttentionAndClears() async throws {
        let project = try PlatformTestSupport.tempDir()
        var stub = PlatformSessionFactory.Stub()
        stub.reply = { request in
            if request.messages.last?.role == .tool { return ChatMessage(role: .assistant, content: "done") }
            return ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#, index: 0)])
        }
        let session = try await PlatformSessionFactory.make(project: project, stub: stub, toolRegistry: ToolRegistry(tools: [WriteFileTool()]), autoResolve: .approveOnce)
        let sink = FakeAttention()
        session.attention = sink
        let id = try #require(session.conversationID)
        await session.send("write it")
        #expect(sink.asked == ["write_file:1"])
        #expect(sink.clearedCounts.first == 0)
        #expect(session.sessionStates[id] == nil)
        #expect(await session.sessionRows().first?.state == .idle)
    }

    @Test func forkLatestOpensABranch() async throws {
        let session = try await PlatformSessionFactory.make(project: nil)
        session.agentEnabled = false
        await session.send("hello")
        let original = try #require(session.conversationID)
        await session.newConversation()
        await session.forkLatest(of: original)
        #expect(session.conversationID != original && session.conversationTitle.hasPrefix("Fork of"))
        #expect(session.messages.count == 2)
    }
}
