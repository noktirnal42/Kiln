import Foundation
import Testing
@testable import SuperMetaApp

struct AppleAndMLXProviderTests {
    @Test func appleAvailabilityReasonsAreSpecific() {
        if #available(macOS 26.0, *) {
            let notEnabled = AppleFoundationProvider.availability(from: .unavailable(.appleIntelligenceNotEnabled))
            #expect(!notEnabled.isAvailable)
            #expect(notEnabled.reason?.contains("System Settings") == true)

            let notEligible = AppleFoundationProvider.availability(from: .unavailable(.deviceNotEligible))
            #expect(notEligible.reason?.contains("not support Apple Intelligence") == true)

            let notReady = AppleFoundationProvider.availability(from: .unavailable(.modelNotReady))
            #expect(notReady.reason?.contains("downloading") == true)

            let available = AppleFoundationProvider.availability(from: .available)
            #expect(available.isAvailable)
            #expect(available.reason == nil)
        }
    }

    @Test func mlxProviderReportsSpecificEngineReason() async {
        let provider = MLXProvider()
        let availability = await provider.checkAvailability()
        #expect(!availability.isAvailable)
        let reason = availability.reason ?? ""
        #expect(reason.contains("MLX runtime"))
        #expect(reason.contains("Phase 2"))

        do {
            _ = try await provider.streamChat(
                ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "mlx-x"),
                reasoning: nil
            )
            Issue.record("streamChat must fail honestly")
        } catch let error as ProviderError {
            guard case .engineUnavailable(let detail) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(detail.contains("MLX runtime"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func mlxProviderListsModelsFromSharedCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermeta-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("models--mlx-community--Qwen3-0.6B-4bit")
        let snapshot = repo.appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weights"
        )
        try Data("weights".utf8).write(to: repo.appendingPathComponent("blobs/weights"))

        let provider = MLXProvider(store: UniversalModelStore(root: root))
        let models = try await provider.fetchModels()
        #expect(models.map(\.id) == ["mlx-mlx-community/Qwen3-0.6B-4bit"])
        #expect(models.first?.isOnDevice == true)
        #expect(models.first?.tags.contains("mlx") == true)
    }
}

struct ModelRegistryTests {
    struct StubStreamProvider: ModelProvider {
        let id: String
        let name: String
        let providerType: ProviderType
        let capabilities: ProviderCapabilities
        let available: Bool
        let chunks: [ChatChunk]

        func fetchModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(id: "\(id)-m1", name: "m1", providerID: id, providerType: providerType)]
        }

        func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
            AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        func checkAvailability() async -> ProviderAvailability {
            available ? .available() : .unavailable("stub unavailable for \(id)")
        }
    }

    private func makeRequest(model: String) -> ChatRequest {
        ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: model)
    }

    @Test func registryResolvesByModelPrefix() async throws {
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        let provider = StubStreamProvider(
            id: "ollama", name: "Ollama", providerType: .ollama,
            capabilities: [.streaming, .tools], available: true,
            chunks: [ChatChunk(delta: ChatMessage(role: .assistant, content: "x"))]
        )
        await registry.register(provider)
        let models = await registry.allModels()
        #expect(models.map(\.id) == ["ollama-m1"])

        let stream = try await registry.streamChat(makeRequest(model: "ollama-m1"), reasoning: nil)
        let chunks = try await collect(stream)
        #expect(chunks.first?.delta?.content == "x")
    }

    @Test func registryEmitsModelSwitchedEventOnModelChange() async throws {
        let bus = ModuleEventBus()
        let registry = ModelRegistry(eventBus: bus)
        let provider = StubStreamProvider(
            id: "openrouter", name: "OpenRouter", providerType: .openRouter,
            capabilities: [.streaming], available: true, chunks: []
        )
        await registry.register(provider)

        let received = Counter()
        _ = await bus.subscribe(ModelSwitchedEvent.self) { event in
            await received.add("\(event.fromModel ?? "nil")→\(event.toModel)")
        }

        _ = try await registry.streamChat(makeRequest(model: "openrouter-a"), reasoning: nil)
        _ = try await registry.streamChat(makeRequest(model: "openrouter-b"), reasoning: nil)
        _ = try await registry.streamChat(makeRequest(model: "openrouter-b"), reasoning: nil)
        let events = await received.snapshot()
        #expect(events == ["nil→openrouter-a", "openrouter-a→openrouter-b"])
        #expect(await registry.currentModel() == "openrouter-b")
    }

    @Test func capabilityBasedSelectionSkipsUnavailableAndWeakerProviders() async throws {
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        await registry.register(StubStreamProvider(
            id: "aaa-basic", name: "Basic", providerType: .customEndpoint,
            capabilities: [.streaming], available: true, chunks: []
        ))
        await registry.register(StubStreamProvider(
            id: "zzz-tools", name: "Tools", providerType: .customEndpoint,
            capabilities: [.streaming, .tools], available: true, chunks: []
        ))
        await registry.register(StubStreamProvider(
            id: "bbb-tools-offline", name: "ToolsOffline", providerType: .customEndpoint,
            capabilities: [.streaming, .tools], available: false, chunks: []
        ))

        let withTools = await registry.resolveProvider(requiring: .tools)
        #expect(withTools?.id == "zzz-tools")

        let streaming = await registry.resolveProvider(requiring: .streaming)
        #expect(streaming?.id == "aaa-basic")

        let vision = await registry.resolveProvider(requiring: .vision)
        #expect(vision == nil)
    }

    @Test func unknownModelThrowsNotFoundWithReason() async throws {
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        do {
            _ = try await registry.streamChat(makeRequest(model: "nobody/unknown"), reasoning: nil)
            Issue.record("expected failure")
        } catch let error as ProviderError {
            guard case .notFound(let detail) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(detail.contains("nobody/unknown"))
        }
    }

    @Test func modelCacheRespectsTTL() async throws {
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        let provider = StubStreamProvider(
            id: "ollama", name: "Ollama", providerType: .ollama,
            capabilities: [.streaming], available: true, chunks: []
        )
        await registry.register(provider)
        let first = await registry.allModels()
        let second = await registry.allModels()
        #expect(first.map(\.id) == second.map(\.id))

        await registry.unregister(providerID: "ollama")
        let afterUnregister = await registry.allModels()
        #expect(afterUnregister.isEmpty)
    }

    @Test func contractAllCloudProvidersStreamDeltasThroughRegistry() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let session = ProviderSessions.stubbed()
        MockURLProtocol.route("openrouter.ai", sseEvents: ProviderTestFixtures.openAISSE(deltas: ["o1", "o2"]))
        MockURLProtocol.route("integrate.api.nvidia.com", sseEvents: ProviderTestFixtures.openAISSE(deltas: ["n1", "n2"]))
        MockURLProtocol.route("stub-custom.test", sseEvents: ProviderTestFixtures.openAISSE(deltas: ["c1", "c2"]))
        MockURLProtocol.route("/api/tags", json: ProviderTestFixtures.ollamaTags())
        MockURLProtocol.route("ollama-cloud.test/api/chat", sseEvents: ProviderTestFixtures.ollamaSSE(deltas: ["cl1"]))

        let bus = ModuleEventBus()
        let registry = ModelRegistry(eventBus: bus)
        await registry.register(OpenRouterProvider(session: session))
        await registry.register(NVIDIANIMProvider(session: session))
        await registry.register(CustomEndpointProvider(baseURL: "https://stub-custom.test/v1", session: session))
        await registry.register(OpenCodeProvider(scope: .cloud, baseURL: "https://ollama-cloud.test", session: session))

        let cases: [(String, [String])] = [
            ("openrouter-x", ["o1", "o2"]),
            ("nvidia-nim-z-ai/glm-5.3-flash", ["n1", "n2"]),
            ("custom-x", ["c1", "c2"]),
            ("ollama-cloud-qwen3:8b", ["cl1"]),
        ]
        for (model, expected) in cases {
            let stream = try await registry.streamChat(makeRequest(model: model), reasoning: nil)
            let chunks = try await collect(stream)
            let contents = chunks.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
            #expect(contents == expected, "model \(model) delivered \(contents)")
        }
    }
}
