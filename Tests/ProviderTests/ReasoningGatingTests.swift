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
