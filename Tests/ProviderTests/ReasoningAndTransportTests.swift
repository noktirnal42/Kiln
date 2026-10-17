import Foundation
import Testing
@testable import SuperMetaApp

struct ReasoningConfigTests {
    @Test func ollamaOptionsMapping() {
        var config = ReasoningConfig.default
        config.temperature = 0.4
        config.topP = 0.8
        config.stopSequences = ["END"]
        let options = config.toOllamaOptions()
        #expect(options.num_predict == 2048)
        #expect(options.temperature == 0.4)
        #expect(options.top_p == 0.8)
        #expect(options.stop == ["END"])
    }

    @Test func ollamaUnlimitedBudgetUsesNegativeOne() {
        var config = ReasoningConfig.default
        config.budget = .unlimited
        #expect(config.toOllamaOptions().num_predict == -1)
    }

    @Test func nimEffortMappingFollowsDepth() {
        #expect(ReasoningConfig(depth: .minimal).toNIMEffort() == .low)
        #expect(ReasoningConfig(depth: .balanced).toNIMEffort() == .medium)
        #expect(ReasoningConfig(depth: .deep).toNIMEffort() == .high)
        #expect(ReasoningConfig(depth: .exhaustive).toNIMEffort() == .high)
    }

    @Test func appleEffortMappingFollowsDepth() {
        #expect(ReasoningConfig(depth: .minimal).toAppleEffort() == .low)
        #expect(ReasoningConfig(depth: .balanced).toAppleEffort() == .medium)
        #expect(ReasoningConfig(depth: .exhaustive).toAppleEffort() == .high)
    }

    @Test func openAIRReasoningFieldsPreferBudgetTokens() {
        var config = ReasoningConfig.default
        config.budget = .high
        let fields = config.openAIRReasoningFields
        #expect(fields["max_tokens"] == ProviderJSON(8192))
        config.budget = .unlimited
        let unlimited = config.openAIRReasoningFields
        #expect(unlimited["effort"] == ProviderJSON("medium"))
        #expect(unlimited["max_tokens"] == nil)
    }

    @Test func budgetTokenLimits() {
        #expect(ReasoningBudget.low.tokenLimit == 512)
        #expect(ReasoningBudget.medium.tokenLimit == 2048)
        #expect(ReasoningBudget.high.tokenLimit == 8192)
        #expect(ReasoningBudget.unlimited.tokenLimit == nil)
    }
}

struct OpenAICompatibleTransportTests {
    @Test func requestEncodesMessagesToolsAndReasoning() throws {
        let request = ChatRequest(
            messages: [ChatMessage(role: .user, content: "hi")],
            model: "test-model",
            temperature: 0.1,
            maxTokens: 128,
            topP: 0.5,
            tools: [ProviderTool(name: "list_files", description: "lists files", required: ["path"])]
        )
        let config = ReasoningConfig.default
        let data = try OpenAICompatibleTransport.body(for: request, reasoning: config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "test-model")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 128)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["max_tokens"] as? Int == 2048)
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
    }

    @Test func decodeEventEmitsDeltasAndFinishReasons() throws {
        let deltaData = Data(#"{"choices":[{"delta":{"content":"Hel"}}]}"#.utf8)
        let chunk = try #require(try OpenAICompatibleTransport.decodeEvent(deltaData))
        #expect(chunk.delta?.content == "Hel")
        #expect(chunk.finishReason == nil)

        let toolData = Data(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"p\""}}]}}]}"#.utf8)
        let toolChunk = try #require(try OpenAICompatibleTransport.decodeEvent(toolData))
        #expect(toolChunk.toolCalls.first?.name == "read_file")
        #expect(toolChunk.toolCalls.first?.arguments == "{\"p\"")

        let finishData = Data(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#.utf8)
        let finishChunk = try #require(try OpenAICompatibleTransport.decodeEvent(finishData))
        #expect(finishChunk.finishReason == .length)

        let usageOnlyData = Data(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#.utf8)
        #expect(try OpenAICompatibleTransport.decodeEvent(usageOnlyData) == nil)
    }

    @Test func errorMappingByStatus() {
        #expect(OpenAICompatibleTransport.providerError(status: 401, body: Data()) == .authenticationFailed)
        #expect(OpenAICompatibleTransport.providerError(status: 429, body: Data()) == .rateLimited)
        #expect(OpenAICompatibleTransport.providerError(status: 503, body: Data()) == .serviceUnavailable(""))
        let withMessage = OpenAICompatibleTransport.providerError(status: 400, body: Data(#"{"error":{"message":"bad model"}}"#.utf8))
        #expect(withMessage == .invalidResponse("bad model"))
    }

    @Test func retryPolicy() {
        #expect(ProviderRetry.shouldRetry(status: 429, attempt: 0))
        #expect(ProviderRetry.shouldRetry(status: 503, attempt: 1))
        #expect(!ProviderRetry.shouldRetry(status: 429, attempt: 2))
        #expect(!ProviderRetry.shouldRetry(status: 401, attempt: 0))
        #expect(ProviderRetry.delaySeconds(retryAfter: "2", attempt: 0) == 2)
        #expect(ProviderRetry.delaySeconds(retryAfter: nil, attempt: 0) == 2)
    }

    @Test func streamEmitsDeltasNotCumulativeSnapshots() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/chat/completions", sseEvents: ProviderTestFixtures.openAISSE(deltas: ["Hel", "lo", " world"], finishReason: "stop"))
        let session = ProviderSessions.stubbed()
        let provider = CustomEndpointProvider(baseURL: "https://stub.test/v1", session: session)
        let request = ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "m")
        let stream = try await provider.streamChat(request, reasoning: nil)
        let chunks = try await collect(stream)

        let contents = chunks.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
        #expect(contents == ["Hel", "lo", " world"])
        #expect(chunks.last?.finishReason == .stop)
    }

    @Test func streamMapsAuthenticationFailure() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.route("/chat/completions", status: 401, json: #"{"error":{"message":"bad key"}}"#)
        let session = ProviderSessions.stubbed()
        let provider = OpenRouterProvider(session: session)
        let request = ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "m")
        do {
            let stream = try await provider.streamChat(request, reasoning: nil)
            _ = try await collect(stream)
            Issue.record("expected failure")
        } catch let error as ProviderError {
            #expect(error == .authenticationFailed)
        }
    }
}
