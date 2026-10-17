import Foundation
import Testing
@testable import SuperMetaApp

struct ProviderTestFixtures {
    static func ollamaTags() -> String {
        """
        {"models": [
            {"name": "qwen3:8b", "size": 1, "digest": "abc", "remoteHost": null, "capabilities": ["tools", "thinking"], "details": {"context_length": 32768}},
            {"name": "llama2:7b", "size": 1, "digest": "def", "remoteHost": null, "capabilities": null, "details": null}
        ]}
        """
    }

    static func compatibleModels() -> String {
        """
        {"data": [
            {"id": "lmstudio-community/qwen3-8b", "context_window": 40960},
            {"id": "granite-4.0-h-tiny", "context_window": null}
        ]}
        """
    }

    static func openRouterModels() -> String {
        """
        {"data": [
            {"id": "z-ai/glm-5.3-flash:free", "name": "GLM 5.3 Flash", "context_length": 1048576,
             "supported_parameters": ["tools", "reasoning"], "architecture": {"input_modalities": ["text"]}},
            {"id": "anthropic/claude", "name": "Claude", "context_length": 200000,
             "supported_parameters": ["tools"], "architecture": {"input_modalities": ["text", "image"]}}
        ]}
        """
    }

    static func nimModels() -> String {
        """
        {"data": [
            {"id": "z-ai/glm-5.3-flash"},
            {"id": "meta/llama-3.1-8b-instruct"},
            {"id": "nvidia/nv-embed-qa"},
            {"id": "nvidia/rerank-doc"}
        ]}
        """
    }

    static func customModels() -> String {
        """
        {"data": [
            {"id": "my-model", "name": "My Model", "context_length": 8192}
        ]}
        """
    }

    static func openAISSE(deltas: [String], finishReason: String? = nil) -> [String] {
        var events = deltas.map { delta in
            """
            {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\(delta)"},"finish_reason":null}]}
            """
        }
        if let finishReason {
            events.append(
                """
                {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"\(finishReason)"}]}
                """
            )
        }
        return events
    }

    static func ollamaSSE(deltas: [String]) -> [String] {
        deltas.map { delta in
            """
            {"model":"qwen3:8b","message":{"role":"assistant","content":"\(delta)"},"done":false}
            """
        } + ["{\"model\":\"qwen3:8b\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}"]
    }
}

func collect(_ stream: AsyncThrowingStream<ChatChunk, Error>, max: Int = 100) async throws -> [ChatChunk] {
    var chunks: [ChatChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
        if chunks.count >= max { break }
    }
    return chunks
}
