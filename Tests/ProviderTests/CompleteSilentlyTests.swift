import Foundation
import Testing
@testable import Kiln

actor SwitchLog {
    private var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
    var snapshot: [String] { entries }
}

struct CompleteSilentlyTests {
    private typealias Stub = ModelRegistryTests.StubStreamProvider

    private func request(_ model: String) -> ChatRequest {
        ChatRequest(messages: [ChatMessage(role: .user, content: "score this")], model: model)
    }

    private func chunk(_ text: String) -> ChatChunk {
        ChatChunk(delta: ChatMessage(role: .assistant, content: text))
    }

    @Test func returnsTheTextWithoutChangingTheActiveModelOrPublishingASwitch() async throws {
        let bus = ModuleEventBus()
        let registry = ModelRegistry(eventBus: bus)
        await registry.register(Stub(id: "openrouter", name: "OpenRouter", providerType: .openRouter,
                                     capabilities: [.streaming], available: true,
                                     chunks: [chunk("he"), chunk("llo")]))
        let log = SwitchLog()
        _ = await bus.subscribe(ModelSwitchedEvent.self) { event in await log.add(event.toModel) }

        // The user's chat is on model "a".
        _ = try await registry.streamChat(request("openrouter-a"), reasoning: nil)
        #expect(await registry.currentModel() == "openrouter-a")

        // A background monitor call to a different model must be invisible to the chat.
        let text = try await registry.completeSilently(request("openrouter-monitor"))

        #expect(text == "hello")
        #expect(await registry.currentModel() == "openrouter-a", "the active model is untouched")
        #expect(await log.snapshot == ["openrouter-a"], "no ModelSwitchedEvent for the monitor call")
    }

    @Test func anUnservedModelThrowsInsteadOfGuessing() async {
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        await #expect(throws: (any Error).self) {
            _ = try await registry.completeSilently(request("nobody-serves-this"))
        }
    }

    @Test func outputIsCapped() async throws {
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        let big = chunk(String(repeating: "x", count: 5_000))
        await registry.register(Stub(id: "openrouter", name: "OpenRouter", providerType: .openRouter,
                                     capabilities: [.streaming], available: true,
                                     chunks: Array(repeating: big, count: 10)))

        let text = try await registry.completeSilently(request("openrouter-a"), maxCharacters: 8_000)
        #expect(text.count == 8_000)
    }
}
