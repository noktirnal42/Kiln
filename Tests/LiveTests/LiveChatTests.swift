import Foundation
import SwiftData
import Testing
@testable import Kiln

/// Plain chat (agent mode off) through the same `ChatSession` and `ModelRegistry` the app uses, against the
/// real providers. Opt-in with `TEST_RUNNER_KILN_LIVE=1`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"), .serialized)
struct LiveChatTests {
    private func session() async throws -> (ChatSession, ModelRegistry) {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        let keychain = KeychainService()
        await registry.register(OpenCodeProvider(scope: .local))
        await registry.register(NVIDIANIMProvider(secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "nvidia-nim")))
        await registry.register(OpenRouterProvider(secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "openrouter")))
        let session = ChatSession(registry: registry, conversations: ConversationStore(container: container),
                                  artifacts: ArtifactStore(container: container))
        return (session, registry)
    }

    private func ask(_ label: String, modelSuffix: String) async throws {
        let (session, registry) = try await session()
        let models = await registry.allModels(forceRefresh: true)
        guard let model = models.first(where: { $0.id.hasSuffix(modelSuffix) }) else {
            print("CHAT \(label): model not listed (\(models.count) models total)")
            Issue.record("\(label): \(modelSuffix) not in the catalog")
            return
        }
        session.selectedModelID = model.id
        await session.send("Reply with exactly one word: pong")
        let reply = session.messages.last(where: { $0.role == .assistant })?.content ?? ""
        print("CHAT \(label) [\(model.id)] reply=\(reply.prefix(120).debugDescription) error=\(session.errorText ?? "none") streaming=\(session.isStreaming)")
        #expect(session.errorText == nil, "\(label) error: \(session.errorText ?? "")")
        #expect(!reply.isEmpty, "\(label) gave no response")
        #expect(!session.isStreaming, "\(label) is stuck streaming")
    }

    @Test func localOllamaAnswersAPlainChat() async throws { try await ask("ollama", modelSuffix: "qwen2.5-coder:3b") }
    @Test func nvidiaNimAnswersAPlainChat() async throws { try await ask("nim", modelSuffix: "z-ai/glm-5.3-flash") }
}
