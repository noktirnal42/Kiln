import Foundation
import Testing
@testable import Kiln

struct OpenCodeProviderTests {
    private func stubbedProvider(baseURL: String = "https://stub.test") -> OpenCodeProvider {
        OpenCodeProvider(scope: .local, baseURL: baseURL, session: ProviderSessions.stubbed())
    }

    @Test func fetchModelsPrefersOllamaCatalog() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", json: ProviderTestFixtures.ollamaTags())
        let models = try await stubbedProvider().fetchModels()
        #expect(models.map(\.id) == ["ollama-llama2:7b", "ollama-qwen3:8b"])
        let qwen = try #require(models.first { $0.name == "qwen3:8b" })
        #expect(qwen.supportsTools)
        #expect(qwen.supportsReasoning)
        #expect(qwen.contextWindow == 8192, "a local model's window is what Kiln asks Ollama to run with, not the trained maximum")
        #expect(qwen.isOnDevice)
    }

    @Test func localModelsAreDescribedByWhatOllamaReportsNotByTheirName() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", json: #"{"models":[{"name":"gemma4:e4b"}]}"#)
        // A family the name lists have never heard of; /api/show is the source of truth.
        MockURLProtocol.route("/api/show", json: #"{"capabilities":["completion","vision","tools","thinking"],"model_info":{"gemma4.context_length":131072}}"#)
        let model = try #require(try await stubbedProvider().fetchModels().first)
        #expect(model.supportsTools && model.supportsReasoning && model.supportsVision)
        #expect(model.contextWindow == 8192)
    }

    @Test func aModelOllamaSaysCannotUseToolsIsNotOfferedThemEvenIfTheNameLooksCapable() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", json: #"{"models":[{"name":"qwen3-coder-special:7b"}]}"#)
        MockURLProtocol.route("/api/show", json: #"{"capabilities":["completion"],"model_info":{"qwen3.context_length":4096}}"#)
        let model = try #require(try await stubbedProvider().fetchModels().first)
        #expect(!model.supportsTools)
        #expect(model.contextWindow == 4096, "a model trained for less than Kiln asks for keeps its own limit")
    }

    @Test func showAnswersAreParsedWithoutAssumingTheArchitectureName() {
        let info = OpenCodeProvider.parseShow(Data(#"{"capabilities":["Tools","completion"],"model_info":{"general.parameter_count":1,"llama.context_length":8192}}"#.utf8))
        #expect(info == .init(capabilities: ["tools", "completion"], trainedContext: 8192))
        #expect(OpenCodeProvider.parseShow(Data("{}".utf8)) == nil)
        #expect(OpenCodeProvider.parseShow(Data("not json".utf8)) == nil)
    }

    @Test func theNameListsStillCoverNewerFamiliesWhenShowIsUnavailable() {
        for name in ["gemma4:e4b", "devstral-small-2:24b", "glm-4.7-flash", "qwen3.5:9b", "huihui_ai/qwen3.5-abliterated:9b"] {
            #expect(OpenCodeProvider.supportsTools(modelName: name), "\(name)")
        }
    }

    @Test func fetchModelsFallsBackToOpenAICompatibleCatalog() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", status: 404, json: #"{"error":"not found"}"#)
        MockURLProtocol.route("/v1/models", json: ProviderTestFixtures.compatibleModels())
        let models = try await stubbedProvider().fetchModels()
        #expect(models.map(\.id) == ["ollama-granite-4.0-h-tiny", "ollama-lmstudio-community/qwen3-8b"])
    }

    @Test func streamChatUsesOllamaNativeWhenAvailable() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", json: ProviderTestFixtures.ollamaTags())
        MockURLProtocol.route("/api/chat", sseEvents: ProviderTestFixtures.ollamaSSE(deltas: ["Hel", "lo"]))
        let provider = stubbedProvider()
        let request = ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "ollama-qwen3:8b")
        let stream = try await provider.streamChat(request, reasoning: ReasoningConfig.default)
        let chunks = try await collect(stream)
        let contents = chunks.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
        #expect(contents == ["Hel", "lo"])
        #expect(chunks.last?.finishReason == .stop)

        let bodies = MockURLProtocol.recordedRequests().filter { $0.0.contains("/api/chat") }
        let body = try #require(bodies.first?.1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen3:8b")
        #expect(json["think"] as? Bool == true)
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == 8192)
    }

    @Test func streamChatFallsBackToOpenAICompatibleWhenOllamaAbsent() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", status: 500, json: #"{"error":"down"}"#)
        MockURLProtocol.route("/v1/chat/completions", sseEvents: ProviderTestFixtures.openAISSE(deltas: ["a", "b"]))
        let provider = stubbedProvider()
        let request = ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "ollama-qwen3:8b")
        let stream = try await provider.streamChat(request, reasoning: nil)
        let chunks = try await collect(stream)
        let contents = chunks.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
        #expect(contents == ["a", "b"])
    }

    @Test func availabilityReportsSpecificReasonWhenNothingListening() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", status: 404, json: "{}")
        MockURLProtocol.route("/v1/models", status: 404, json: "{}")
        let availability = await stubbedProvider().checkAvailability()
        #expect(!availability.isAvailable)
        let reason = availability.reason ?? ""
        #expect(reason.contains("model server"))
        #expect(reason.contains("OpenAI-compatible"))
    }

    @Test func ollamaCloudScopePrefixesAndFlags() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/api/tags", json: ProviderTestFixtures.ollamaTags())
        let cloud = OpenCodeProvider(scope: .cloud, baseURL: "https://stub.test", session: ProviderSessions.stubbed())
        let models = try await cloud.fetchModels()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { $0.id.hasPrefix("ollama-cloud-") })
        #expect(models.allSatisfy { !$0.isOnDevice })
    }
}

struct CloudProviderCatalogTests {
    @Test func openRouterCatalogParsing() throws {
        let models = try OpenRouterProvider.catalog(from: Data(ProviderTestFixtures.openRouterModels().utf8))
        #expect(models.count == 2)
        let flash = try #require(models.first { $0.id == "openrouter-z-ai/glm-5.3-flash:free" })
        #expect(flash.contextWindow == 1_048_576)
        #expect(flash.supportsReasoning)
        #expect(flash.supportsTools)
        #expect(!flash.supportsVision)
        let claude = try #require(models.first { $0.id == "openrouter-anthropic/claude" })
        #expect(claude.supportsVision)
    }

    @Test func nimCatalogFiltersNonChatEndpoints() throws {
        let models = try NVIDIANIMProvider.catalog(from: Data(ProviderTestFixtures.nimModels().utf8))
        #expect(models.count == 2)
        #expect(models.contains { $0.id == "nvidia-nim-z-ai/glm-5.3-flash" })
        #expect(models.contains { $0.id == "nvidia-nim-meta/llama-3.1-8b-instruct" })
    }

    @Test func hostedModelsWithoutAPublishedWindowAreNotAssumedToBeTiny() throws {
        // A 4096 placeholder pins the context meter at 100% and triggers compaction on every run.
        let models = try NVIDIANIMProvider.catalog(from: Data(ProviderTestFixtures.nimModels().utf8))
        let llama = try #require(models.first { $0.id == "nvidia-nim-meta/llama-3.1-8b-instruct" })
        #expect(llama.contextWindow == ModelDescriptor.unknownHostedWindow)
        #expect(ModelDescriptor.unknownHostedWindow >= 32_768)
    }

    @Test func nimGLMRequestOptions() {
        let deep = NVIDIANIMProvider.requestOptions(model: "z-ai/glm-5.3-flash", reasoning: ReasoningConfig(depth: .deep))
        #expect(deep["reasoning_effort"] == ProviderJSON("max"))
        let balanced = NVIDIANIMProvider.requestOptions(model: "z-ai/glm-5.3-flash", reasoning: ReasoningConfig(depth: .balanced))
        #expect(balanced["reasoning_effort"] == ProviderJSON("high"))
        let minimal = NVIDIANIMProvider.requestOptions(model: "z-ai/glm-5.3-flash", reasoning: ReasoningConfig(depth: .minimal))
        #expect(minimal["reasoning_effort"] == ProviderJSON("low"))
        let other = NVIDIANIMProvider.requestOptions(model: "meta/llama-3.1", reasoning: nil)
        #expect(other.isEmpty)
    }

    @Test func customEndpointCatalogParsing() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/models", json: ProviderTestFixtures.customModels())
        let provider = CustomEndpointProvider(baseURL: "https://stub.test/v1", session: ProviderSessions.stubbed())
        let models = try await provider.fetchModels()
        #expect(models.map(\.id) == ["custom-my-model"])
        #expect(models.first?.name == "My Model")
        #expect(models.first?.contextWindow == 8192)
    }

    @Test func missingKeyReportsSpecificAvailabilityReason() async {
        let keychain = KeychainService()
        let secretKey = "openrouter-availability-\(UUID().uuidString)"
        defer { try? keychain.delete(module: providersKeychainModule, key: secretKey) }
        let provider = OpenRouterProvider(secretProvider: keychain.secretProvider(module: providersKeychainModule, key: secretKey))
        let availability = await provider.checkAvailability()
        #expect(!availability.isAvailable)
        let reason = availability.reason ?? ""
        #expect(reason.contains("API key"))
        #expect(reason.contains("Keychain"))
    }
}
