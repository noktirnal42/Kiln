import Foundation
import Testing
@testable import Kiln

/// Chats with a model that already sits in the user's shared model store, through the registry exactly as the
/// app does. Opt-in (`TEST_RUNNER_KILN_LIVE=1`) AND it must run unsandboxed (the sandboxed test host cannot read
/// an external drive until a folder is chosen in Settings): pass `CODE_SIGN_ENTITLEMENTS=` to xcodebuild.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"))
struct LiveMLXStoreTests {
    private let hub = URL(fileURLWithPath: "/Volumes/Artificial_Intelligence_Machine_Learning/huggingface-cache/hub")
    private let repo = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    @Test func aModelFromTheDriveStoreAnswersAChat() async throws {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        print("MLX sandboxed=\(sandboxed)")
        guard FileManager.default.fileExists(atPath: hub.path), !sandboxed else {
            print("MLX skipped: drive store not readable here (sandboxed=\(sandboxed))"); return
        }
        let store = UniversalModelStore(root: hub)
        let installed = store.installed().filter(\.isLanguageModel)
        print("MLX store: \(installed.count) language models: \(installed.map(\.repoID))")
        #expect(installed.contains { $0.repoID == repo })

        let registry = ModelRegistry(eventBus: ModuleEventBus())
        await registry.register(MLXProvider(store: store))
        let catalog = await registry.allModels(forceRefresh: true)
        #expect(catalog.contains { $0.id == "mlx-\(repo)" }, "model missing from the picker catalog")

        let started = ContinuousClock.now
        let stream = try await registry.streamChat(ChatRequest(
            messages: [ChatMessage(role: .user, content: "Reply with exactly one word: pong")], model: "mlx-\(repo)"))
        var text = ""
        for try await chunk in stream { text += chunk.delta?.content ?? "" }
        print("MLX reply=\(text.debugDescription) in \(ContinuousClock.now - started)")
        // A 1.5B model does not reliably follow "one word"; what matters is that the model loaded and answered.
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no reply")

        // History is honoured: the second turn can refer to the first.
        let second = try await registry.streamChat(ChatRequest(messages: [
            ChatMessage(role: .user, content: "My favourite fruit is marmalade-flavoured kiwi. Remember it."),
            ChatMessage(role: .assistant, content: "Noted: marmalade-flavoured kiwi."),
            ChatMessage(role: .user, content: "What is my favourite fruit? Answer in a few words."),
        ], model: "mlx-\(repo)"))
        var answer = ""
        for try await chunk in second { answer += chunk.delta?.content ?? "" }
        print("MLX history reply=\(answer.debugDescription)")
        #expect(answer.lowercased().contains("kiwi"), "history was not used: \(answer)")
    }
}
