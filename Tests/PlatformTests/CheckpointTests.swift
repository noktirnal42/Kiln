import Foundation
import Testing
@testable import Kiln

struct CheckpointStoreTests {
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func rewindRestoresEditedFilesAndRemovesCreatedOnes() throws {
        let root = try PlatformTestSupport.tempDir("ws")
        let store = CheckpointStore(directory: try PlatformTestSupport.tempDir("cp"))
        let existing = root.appendingPathComponent("a.txt"), created = root.appendingPathComponent("sub/new.txt")
        try PlatformTestSupport.write("original", to: existing)
        let conversation = UUID(), message = UUID()
        let recorder = CheckpointRecorder(store: store, conversationID: conversation, messageID: message, workspaceRoot: root)
        recorder.beforeTool(name: "edit_file", argumentsJSON: #"{"path":"a.txt"}"#, callID: "1")
        try PlatformTestSupport.write("changed", to: existing)
        recorder.afterTool(callID: "1")
        recorder.beforeTool(name: "write_file", argumentsJSON: #"{"path":"sub/new.txt"}"#, callID: "2")
        try PlatformTestSupport.write("hi", to: created)
        recorder.afterTool(callID: "2")
        recorder.beforeTool(name: "run_command", argumentsJSON: #"{"command":"make install"}"#, callID: "3")
        #expect(recorder.finish() != nil)

        let report = store.rewind(conversationID: conversation, messages: [message], from: message, workspaceRoot: root)
        #expect(read(existing) == "original")
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(report.restored == ["a.txt"] && report.deleted == ["sub/new.txt"])
        #expect(report.unrestorable == ["run_command make install"] && report.summary.contains("Not undone"))
        // Rewinding twice does nothing more.
        #expect(store.rewind(conversationID: conversation, messages: [message], from: message, workspaceRoot: root).checkpoints == 0)
    }

    @Test func neverTouchesFilesOutsideTheWorkspaceOrChangedSince() throws {
        let root = try PlatformTestSupport.tempDir("ws"), outside = try PlatformTestSupport.tempDir("out")
        let store = CheckpointStore(directory: try PlatformTestSupport.tempDir("cp"))
        let file = root.appendingPathComponent("a.txt"), other = outside.appendingPathComponent("x.txt")
        try PlatformTestSupport.write("one", to: file); try PlatformTestSupport.write("keep", to: other)
        let message = UUID(), conversation = UUID()
        let recorder = CheckpointRecorder(store: store, conversationID: conversation, messageID: message, workspaceRoot: root)
        recorder.beforeTool(name: "write_file", argumentsJSON: "{\"path\":\"\(other.path)\"}", callID: "o")
        recorder.beforeTool(name: "write_file", argumentsJSON: #"{"path":"../x.txt"}"#, callID: "p")
        recorder.beforeTool(name: "write_file", argumentsJSON: #"{"path":"a.txt"}"#, callID: "1")
        try PlatformTestSupport.write("two", to: file)
        recorder.afterTool(callID: "1")
        #expect(recorder.changedFiles == ["a.txt"])
        _ = recorder.finish()
        try PlatformTestSupport.write("someone else edited this", to: file)   // after the agent's run
        let report = store.rewind(conversationID: conversation, messages: [message], from: message, workspaceRoot: root)
        #expect(read(file) == "someone else edited this" && report.skipped.first?.contains("changed since") == true)
        #expect(read(other) == "keep")
    }

    @Test func aRunThatChangedNothingLeavesNoCheckpoint() throws {
        let root = try PlatformTestSupport.tempDir("ws")
        let store = CheckpointStore(directory: try PlatformTestSupport.tempDir("cp"))
        let recorder = CheckpointRecorder(store: store, conversationID: UUID(), messageID: UUID(), workspaceRoot: root)
        recorder.beforeTool(name: "read_file", argumentsJSON: #"{"path":"a"}"#, callID: "1")
        #expect(recorder.finish() == nil && store.all().isEmpty)
    }
}

@MainActor
struct CheckpointSessionTests {
    @Test func rewindToAMessageRestoresFilesAndConversation() async throws {
        let project = try PlatformTestSupport.tempDir("ws")
        let target = project.appendingPathComponent("a.txt")
        try PlatformTestSupport.write("before", to: target)
        var stub = PlatformSessionFactory.Stub()
        stub.reply = { request in
            if request.messages.last?.role == .tool { return ChatMessage(role: .assistant, content: "done") }
            return ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"after"}"#, index: 0)])
        }
        let chain = try PlatformTestSupport.auditChain()
        let session = try await PlatformSessionFactory.make(project: project, chain: chain, stub: stub, toolRegistry: ToolRegistry(tools: [WriteFileTool()]),
                                                            autoResolve: .approveOnce, checkpoints: CheckpointStore(directory: try PlatformTestSupport.tempDir("cp")))
        await session.send("first: edit a.txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "after")
        let user = try #require(session.messages.first { $0.role == .user })
        #expect(session.checkpointedMessageIDs.contains(user.id))
        let report = try #require(await session.rewind(to: user.id))
        #expect(report.restored == ["a.txt"])
        #expect(try String(contentsOf: target, encoding: .utf8) == "before")
        #expect(session.messages.isEmpty && session.draft == "first: edit a.txt")
        let types = try await chain.recent(60).map(\.type)
        #expect(types.contains("checkpoint.created") && types.contains("checkpoint.rewound"))
    }
}
