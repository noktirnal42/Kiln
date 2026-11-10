import Foundation
import SwiftData
import Testing
@testable import Kiln

/// A ChatSession wired to a stub model, an in-memory store and (optionally) an audit chain.
@MainActor
enum PlatformSessionFactory {
    struct Stub: ModelProvider {
        let id = "stub"
        let name = "Stub"
        let providerType: ProviderType = .customEndpoint
        let capabilities: ProviderCapabilities = [.streaming]
        var reply: @Sendable (ChatRequest) -> ChatMessage = { _ in ChatMessage(role: .assistant, content: "Reply.") }
        func fetchModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(id: "stub-m1", name: "m1", providerID: id, providerType: providerType, contextWindow: 14_000)]
        }
        func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
            let message = reply(request)
            return AsyncThrowingStream { c in
                c.yield(ChatChunk(delta: message, finishReason: message.toolCalls.isEmpty ? .stop : .toolCalls, usage: ChatChunk.Usage(promptTokens: 10, completionTokens: 5, totalTokens: 15), toolCalls: message.toolCalls))
                c.finish()
            }
        }
        func checkAvailability() async -> ProviderAvailability { .available() }
    }

    static func make(project: URL?, home: URL? = nil, chain: AuditChain? = nil, stub: Stub = Stub(),
                     toolRegistry: ToolRegistry = ToolRegistry(tools: []), autoResolve: ApprovalDecision? = nil, checkpoints: CheckpointStore? = nil, usage: UsageLedger? = nil) async throws -> ChatSession {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let session = ChatSession(
            registry: ModelRegistry(eventBus: ModuleEventBus()),
            conversations: ConversationStore(container: container),
            artifacts: ArtifactStore(container: container),
            workspaceRoot: project?.path,
            compactionDefaults: nil,
            memoryHome: home,
            checkpointStore: checkpoints,
            usageLedger: usage
        )
        await session.registry.register(stub)
        let (center, _) = try makeTestApprovalCenter(autoResolve: autoResolve)
        session.attachOrchestrator(AgentOrchestrator(toolRegistry: toolRegistry, approvalCenter: center, auditChain: chain))
        await session.newConversation()
        session.selectedModelID = "stub-m1"
        return session
    }
}
