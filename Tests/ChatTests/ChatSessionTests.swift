import Foundation
import SwiftData
import Testing
@testable import Kiln

@MainActor
struct ChatSessionTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeSession(bus: ModuleEventBus = ModuleEventBus()) throws -> (ChatSession, ConversationStore, ArtifactStore) {
        let container = try makeContainer()
        let conversations = ConversationStore(container: container)
        let artifacts = ArtifactStore(container: container)
        let registry = ModelRegistry(eventBus: bus)
        let session = ChatSession(registry: registry, conversations: conversations, artifacts: artifacts)
        return (session, conversations, artifacts)
    }

    private func registerStreamingProvider(
        _ registry: ModelRegistry,
        chunks: [ChatChunk],
        delay: Duration? = nil,
        chunkDelays: [Duration?]? = nil
    ) async {
        struct StreamStub: ModelProvider {
            let id = "stub"
            let name = "Stub"
            let providerType: ProviderType = .customEndpoint
            let capabilities: ProviderCapabilities = [.streaming]
            let chunks: [ChatChunk]
            let chunkDelays: [Duration?]

            func fetchModels() async throws -> [ModelDescriptor] {
                [ModelDescriptor(id: "stub-m1", name: "m1", providerID: id, providerType: providerType)]
            }

            func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        for (index, chunk) in chunks.enumerated() {
                            if let sleepFor = index < chunkDelays.count ? chunkDelays[index] : nil {
                                try? await Task.sleep(for: sleepFor)
                            }
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }

            func checkAvailability() async -> ProviderAvailability { .available() }
        }
        await registry.register(StreamStub(chunks: chunks, chunkDelays: chunkDelays ?? chunks.map { _ in delay }))
    }

    @Test func sendPersistsUserAndAssistantFromDeltas() async throws {
        let (session, conversations, _) = try makeSession()
        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(delta: ChatMessage(role: .assistant, content: "Hel")),
            ChatChunk(delta: ChatMessage(role: .assistant, content: "lo")),
            ChatChunk(finishReason: .stop, usage: ChatChunk.Usage(promptTokens: 3, completionTokens: 2, totalTokens: 5)),
        ])
        await session.newConversation()
        session.selectedModelID = "stub-m1"

        await session.send("hello world")
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].content == "hello world")
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].content == "Hello")

        let stored = try await conversations.messages(conversationID: session.conversationID!)
        #expect(stored.messages.count == 2)
        #expect(stored.messages[1].content == "Hello")
        #expect(stored.messages[1].tokenCount == 5)
    }

    @Test func sendAccumulatesToolCallsFromFragments() async throws {
        let (session, conversations, _) = try makeSession()
        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(toolCalls: [ToolCall(id: "call_1", name: "read_file", arguments: "{\"pat", index: 0)]),
            ChatChunk(toolCalls: [ToolCall(id: "", name: "", arguments: "h\": \"/tmp\"}", index: 0)]),
            ChatChunk(finishReason: .toolCalls),
        ])
        await session.newConversation()
        session.selectedModelID = "stub-m1"

        await session.send("read it")
        #expect(session.messages.count == 2)
        let toolCalls = session.messages[1].toolCalls
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.name == "read_file")
        #expect(toolCalls.first?.arguments == "{\"path\": \"/tmp\"}")

        let stored = try await conversations.messages(conversationID: session.conversationID!)
        #expect(stored.messages[1].toolCalls.first?.arguments == "{\"path\": \"/tmp\"}")
    }

    @Test func midStreamStopKeepsPartialAndStops() async throws {
        let (session, conversations, _) = try makeSession()
        await registerStreamingProvider(
            session.registry,
            chunks: [
                ChatChunk(delta: ChatMessage(role: .assistant, content: "part")),
                ChatChunk(delta: ChatMessage(role: .assistant, content: "ial")),
            ],
            chunkDelays: [nil, .seconds(30)]
        )
        await session.newConversation()
        session.selectedModelID = "stub-m1"

        let sendTask = Task { await session.send("go") }
        for _ in 0..<50 where session.streamingText.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.streamingText == "part")
        #expect(session.isStreaming)
        session.stopStreaming()
        await sendTask.value
        #expect(!session.isStreaming)

        let stored = try await conversations.messages(conversationID: session.conversationID!)
        #expect(stored.messages.count == 2)
        #expect(stored.messages[1].content == "part")
    }

    @Test func forkViaSessionProducesBranchedConversation() async throws {
        let (session, conversations, _) = try makeSession()
        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(delta: ChatMessage(role: .assistant, content: "answer one")),
            ChatChunk(finishReason: .stop),
        ])
        await session.newConversation()
        session.selectedModelID = "stub-m1"
        await session.send("q1")
        let firstAssistant = session.messages[1]

        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(delta: ChatMessage(role: .assistant, content: "answer two")),
            ChatChunk(finishReason: .stop),
        ])
        await session.send("q2")
        #expect(session.messages.count == 4)

        await session.fork(at: firstAssistant.id)
        #expect(session.messages.count == 2)
        #expect(session.messages[1].content == "answer one")
        #expect(session.conversationTitle.hasPrefix("Fork of"))

        let all = try await conversations.conversations()
        #expect(all.count == 2)
    }

    @Test func emptyModelSelectionReportsSpecificError() async throws {
        let (session, _, _) = try makeSession()
        await session.newConversation()
        session.selectedModelID = ""
        await session.send("hi")
        #expect(session.errorText?.contains("No model selected") == true)
        #expect(session.messages.count == 0)
    }

    @Test func regenerateRemovesLastAssistantAndReplies() async throws {
        let (session, _, _) = try makeSession()
        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(delta: ChatMessage(role: .assistant, content: "first")),
            ChatChunk(finishReason: .stop),
        ])
        await session.newConversation()
        session.selectedModelID = "stub-m1"
        await session.send("q")

        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(delta: ChatMessage(role: .assistant, content: "second")),
            ChatChunk(finishReason: .stop),
        ])
        await session.regenerate()
        #expect(session.messages.count == 2)
        #expect(session.messages[1].content == "second")
    }

    @Test func tenThousandMessageConversationLoads() async throws {
        let (session, conversations, _) = try makeSession()
        let summary = try await conversations.createConversation(title: "synthetic")
        let start = Date()
        let items = (0..<10_000).map { index -> (role: ChatMessage.Role, content: String, reasoning: String?, tokenCount: Int, toolCalls: [ToolCall], modelID: String?) in
            (index % 2 == 0 ? ChatMessage.Role.user : .assistant, "message \(index)", nil, 0, [], nil)
        }
        _ = try await conversations.appendMessages(conversationID: summary.id, items: items)
        let appendElapsed = Date().timeIntervalSince(start)

        let loadStart = Date()
        await session.loadConversation(summary.id)
        let loadElapsed = Date().timeIntervalSince(loadStart)

        #expect(session.messages.count == 10_000)
        #expect(session.messages.first?.content == "message 0")
        #expect(session.messages.last?.content == "message 9999")
        #expect(loadElapsed < 5.0, "10k-message load took \(loadElapsed)s (append took \(appendElapsed)s)")
    }

    @Test func sendWithoutConversationCreatesOne() async throws {
        let (session, conversations, _) = try makeSession()
        await registerStreamingProvider(session.registry, chunks: [
            ChatChunk(delta: ChatMessage(role: .assistant, content: "ok")),
            ChatChunk(finishReason: .stop),
        ])
        session.selectedModelID = "stub-m1"
        #expect(session.conversationID == nil)
        await session.send("hi")
        #expect(session.conversationID != nil)
        let summaries = try await conversations.conversations()
        #expect(summaries.count == 1)
    }
}
