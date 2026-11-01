import Foundation
import Testing
@testable import Kiln

struct ReasoningGatingTests {
    @Test func aModelThatCannotReasonGetsReasoningTurnedOffButKeepsItsSettings() {
        var config = ReasoningConfig.default
        config.temperature = 0.2
        let adjusted = ModelRegistry.reasoning(config, forModelSupporting: false)
        #expect(adjusted?.enabled == false)
        #expect(adjusted?.temperature == 0.2)
    }

    @Test func reasoningStaysOnWhenSupportedOrUnknown() {
        let config = ReasoningConfig.default
        #expect(ModelRegistry.reasoning(config, forModelSupporting: true)?.enabled == true)
        #expect(ModelRegistry.reasoning(config, forModelSupporting: nil)?.enabled == true)
        #expect(ModelRegistry.reasoning(nil, forModelSupporting: false) == nil)
    }
}

struct OllamaToolsPayloadTests {
    @Test func toolsAreEncodedAsFunctionsWithTheirRequiredParameters() throws {
        let tool = ProviderTool(name: "read_file", description: "Read a file",
                                parameters: ["path": ProviderJSON(["type": ProviderJSON("string")])], required: ["path"])
        let data = try JSONEncoder().encode(OpenAICompatibleTransport.toolsJSON([tool]))
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let function = try #require(array.first?["function"] as? [String: Any])
        #expect(array.first?["type"] as? String == "function")
        #expect(function["name"] as? String == "read_file")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["path"])
    }
}

struct BareModelIDTests {
    @Test func theProviderIsHandedItsOwnModelNameNotTheCatalogId() {
        #expect(ModelRegistry.bareModelID("nvidia-nim-z-ai/glm-5.3-flash", providerID: "nvidia-nim") == "z-ai/glm-5.3-flash")
        #expect(ModelRegistry.bareModelID("openrouter-nvidia/nemotron:free", providerID: "openrouter") == "nvidia/nemotron:free")
        #expect(ModelRegistry.bareModelID("ollama-cloud-glm-5.2", providerID: "ollama-cloud") == "glm-5.2")
        #expect(ModelRegistry.bareModelID("already-bare", providerID: "other") == "already-bare")
    }
}

@MainActor
struct RegistryHandsProvidersBareModelNamesTests {
    private final class Seen: @unchecked Sendable { var model: String? }

    private struct Recorder: ModelProvider {
        let id = "hosted"
        let name = "Hosted"
        let providerType: ProviderType = .customEndpoint
        let capabilities: ProviderCapabilities = [.streaming]
        let seen: Seen
        func fetchModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(id: "hosted-vendor/model-1", name: "vendor/model-1", providerID: id, providerType: providerType)]
        }
        func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
            seen.model = request.model
            return AsyncThrowingStream { $0.finish() }
        }
        func checkAvailability() async -> ProviderAvailability { .available() }
    }

    @Test func streamingAndSilentCompletionBothSendTheBareName() async throws {
        let seen = Seen()
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        await registry.register(Recorder(seen: seen))
        _ = await registry.allModels(forceRefresh: true)

        _ = try await registry.streamChat(ChatRequest(messages: [], model: "hosted-vendor/model-1"))
        #expect(seen.model == "vendor/model-1")

        seen.model = nil
        _ = try await registry.completeSilently(ChatRequest(messages: [], model: "hosted-vendor/model-1"))
        #expect(seen.model == "vendor/model-1")
    }
}
