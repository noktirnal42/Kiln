import Foundation

/// Ollama (local) and Ollama Cloud. Local scope also accepts OpenAI-compatible
/// local servers (LM Studio, vLLM, Jan) by falling back from /api/tags to
/// /v1/models and from /api/chat to /v1/chat/completions.
public struct OpenCodeProvider: ModelProvider {
    public enum Scope: String, Sendable {
        case local
        case cloud
    }

    public let id: String
    public let name: String
    public let providerType: ProviderType
    public let capabilities: ProviderCapabilities

    private let scope: Scope
    private let baseURL: String
    private let secretProvider: SecretProvider?
    private let session: URLSession

    public init(
        scope: Scope = .local,
        baseURL: String? = nil,
        secretProvider: SecretProvider? = nil,
        session: URLSession = ProviderSessions.shared
    ) {
        self.scope = scope
        self.session = session
        self.secretProvider = secretProvider
        switch scope {
        case .local:
            id = "ollama"
            name = "Ollama (Local)"
            providerType = .ollama
            capabilities = [.streaming, .reasoning, .tools, .onDevice, .metalAcceleration]
            self.baseURL = (baseURL ?? "http://localhost:11434").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .cloud:
            id = "ollama-cloud"
            name = "Ollama Cloud"
            providerType = .ollamaCloud
            capabilities = [.streaming, .reasoning, .tools]
            self.baseURL = (baseURL ?? "https://ollama.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    public func checkAvailability() async -> ProviderAvailability {
        if await probeOllama() { return .available() }
        if await probeOpenAICompatible() { return .available() }
        if scope == .local {
            return .unavailable("No local model server is reachable at \(baseURL). Start Ollama (or an OpenAI-compatible server such as LM Studio) and try again.")
        }
        return .unavailable("Ollama Cloud is unreachable at \(baseURL). Check your network connection and API key.")
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        do {
            let models = try await fetchOllamaCatalog()
            return models
        } catch {
            let models = try await fetchOpenAICompatibleCatalog()
            return models
        }
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        if await probeOllama() {
            return try ollamaNativeStream(request, reasoning: reasoning)
        }
        guard let url = URL(string: Self.openAIChatURL(for: baseURL)) else {
            throw ProviderError.missingConfiguration("invalid base URL '\(baseURL)'")
        }
        return OpenAICompatibleTransport.stream(
            url: url,
            apiKey: apiKey(),
            request: request,
            reasoning: reasoning,
            session: session
        )
    }

    // MARK: Ollama native

    private func ollamaNativeStream(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw ProviderError.missingConfiguration("invalid base URL '\(baseURL)'")
        }
        let model = Self.strippedModelID(request.model, scope: scope)
        var payload: [String: ProviderJSON] = [
            "model": ProviderJSON(model),
            "stream": ProviderJSON(true),
            "messages": ProviderJSON(request.messages.map { message in
                var value: [String: ProviderJSON] = [
                    "role": ProviderJSON(message.role.rawValue),
                    "content": ProviderJSON(message.content),
                ]
                if !message.images.isEmpty {
                    value["images"] = ProviderJSON(message.images.map { ProviderJSON($0.data.base64EncodedString()) })
                }
                if !message.toolCalls.isEmpty {
                    value["tool_calls"] = ProviderJSON(message.toolCalls.map { call in
                        var function: [String: ProviderJSON] = [
                            "name": ProviderJSON(call.name),
                        ]
                        if let parsed = try? JSONDecoder().decode(ProviderJSON.self, from: Data(call.arguments.utf8)) {
                            function["arguments"] = parsed
                        } else {
                            function["arguments"] = ProviderJSON("{}")
                        }
                        return ProviderJSON([
                            "id": ProviderJSON(call.id),
                            "type": ProviderJSON("function"),
                            "function": ProviderJSON(function),
                        ])
                    })
                }
                if let toolCallID = message.metadata["tool_call_id"] {
                    value["tool_call_id"] = ProviderJSON(toolCallID)
                }
                return ProviderJSON(value)
            }),
        ]
        var options = reasoning?.toOllamaOptions() ?? OllamaOptions(
            num_predict: request.maxTokens,
            temperature: request.temperature,
            top_p: request.topP
        )
        if options.temperature == nil { options.temperature = request.temperature }
        if options.top_p == nil { options.top_p = request.topP }
        if options.num_predict == nil { options.num_predict = request.maxTokens }
        if let think = Self.thinkValue(reasoning) { payload["think"] = think }
        // Without this the model is never told it has tools, and answers that it cannot act.
        if !request.tools.isEmpty {
            payload["tools"] = OpenAICompatibleTransport.toolsJSON(request.tools)
        }
        // Some Ollama catalogs advertise the full training context rather
        // than a practical runtime budget; passing it through makes llama.cpp
        // allocate a huge KV cache before the first token. Bound it to 8K.
        payload["options"] = ProviderJSON([
            "temperature": ProviderJSON(options.temperature ?? request.temperature),
            "top_p": ProviderJSON(options.top_p ?? request.topP),
            "num_predict": ProviderJSON(options.num_predict ?? request.maxTokens),
            "num_ctx": ProviderJSON(Self.runtimeContextTokens),
        ])

        let key = apiKey()
        let body = try JSONEncoder().encode(payload)
        let encodedURL = url

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var wire = URLRequest(url: encodedURL)
                    wire.httpMethod = "POST"
                    wire.timeoutInterval = 300
                    wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !key.isEmpty {
                        wire.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    wire.httpBody = body
                    let (bytes, response) = try await session.bytes(for: wire)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.invalidResponse("missing HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let bodyData = try await OpenAICompatibleTransport.boundedBody(from: bytes, limit: 16 * 1024)
                        throw OpenAICompatibleTransport.providerError(status: http.statusCode, body: bodyData)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let text = line.hasPrefix("data:") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : line
                        if text == "[DONE]" { break }
                        guard !text.isEmpty else { continue }
                        let chunk = try Self.decodeEvent(Data(text.utf8))
                        continuation.yield(chunk)
                        if chunk.finishReason != nil { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decodeEvent(_ data: Data) throws -> ChatChunk {
        let event = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
        if let error = event.error {
            throw ProviderError.invalidResponse(error)
        }
        return ChatChunk(
            delta: ChatMessage(role: .assistant, content: event.message?.content ?? ""),
            finishReason: event.done == true ? .stop : nil,
            toolCalls: (event.message?.toolCalls ?? []).enumerated().map { index, call in
                let arguments = (try? JSONEncoder().encode(call.function.arguments))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return ToolCall(id: call.id ?? "", name: call.function.name, arguments: arguments, index: call.function.index ?? index)
            }
        )
    }

    // MARK: Catalogs

    /// The context Kiln asks a local Ollama model to run with (`num_ctx`). A model's trained maximum (often 128K to 256K) is far larger;
    /// the window shown and used for compaction is the smaller of the two, so the meter matches what the server really keeps.
    static let runtimeContextTokens = 8192

    /// What Ollama says about one model: `/api/show` lists its capabilities (completion, tools, thinking, vision) and its trained context.
    /// Reading this instead of guessing from the name keeps new model families (Qwen3.5 and later, Gemma 4, Devstral, GLM 4.7) working without a code change.
    struct ShowInfo: Equatable, Sendable {
        var capabilities: Set<String>
        var trainedContext: Int?
    }

    static func parseShow(_ data: Data) -> ShowInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let capabilities = Set(((object["capabilities"] as? [String]) ?? []).map { $0.lowercased() })
        var context: Int?
        if let info = object["model_info"] as? [String: Any] {
            for (key, value) in info where key.hasSuffix(".context_length") { context = (value as? Int) ?? (value as? NSNumber)?.intValue }
        }
        guard !capabilities.isEmpty || context != nil else { return nil }
        return ShowInfo(capabilities: capabilities, trainedContext: context)
    }

    private func ollamaShow(_ name: String) async -> ShowInfo? {
        guard let url = URL(string: "\(baseURL)/api/show") else { return nil }
        var wire = URLRequest(url: url)
        wire.httpMethod = "POST"
        wire.timeoutInterval = 8
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        guard let (data, response) = try? await session.data(for: wire),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return Self.parseShow(data)
    }

    private func fetchOllamaCatalog() async throws -> [ModelDescriptor] {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 10
        if !apiKey().isEmpty {
            wire.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: wire)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse("Ollama /api/tags returned HTTP \(status)")
        }
        let decoded = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
        let entries = decoded.models
            .filter { model in
                guard scope == .local else { return true }
                let cloud = model.remoteHost != nil || model.name.hasSuffix(":cloud") || model.name.hasSuffix("-cloud")
                return !cloud
            }
        // Local models are asked directly (cheap, same machine). Hosted ones advertise capabilities in the listing already.
        var shown: [String: ShowInfo] = [:]
        if scope == .local {
            await withTaskGroup(of: (String, ShowInfo?).self) { group in
                for entry in entries { group.addTask { (entry.name, await self.ollamaShow(entry.name)) } }
                for await (name, info) in group { if let info { shown[name] = info } }
            }
        }
        return entries
            .map { entry in
                let advertised = Set((entry.capabilities ?? []).map { $0.lowercased() }).union(shown[entry.name]?.capabilities ?? [])
                let known = shown[entry.name] != nil || !advertised.isEmpty
                // A model Ollama described is trusted; the name lists are only the fallback for a server that did not say.
                let supportsReasoning = known ? advertised.contains("thinking") : Self.supportsReasoning(modelName: entry.name)
                let supportsTools = known ? advertised.contains("tools") : Self.supportsTools(modelName: entry.name)
                let trained = shown[entry.name]?.trainedContext ?? entry.details?.contextLength
                let window = scope == .local ? min(trained ?? Self.estimateContextWindow(for: entry.name), Self.runtimeContextTokens)
                                             : (trained ?? Self.estimateContextWindow(for: entry.name))
                return ModelDescriptor(
                    id: "\(id)-\(entry.name)",
                    name: entry.name,
                    providerID: id,
                    providerType: providerType,
                    contextWindow: window,
                    supportsReasoning: supportsReasoning,
                    supportsTools: supportsTools,
                    supportsVision: advertised.contains("vision") || entry.name.lowercased().contains("llava") || entry.name.lowercased().contains("vision"),
                    isOnDevice: scope == .local,
                    tags: scope == .local ? ["local", "ollama"] : ["cloud", "ollama"]
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fetchOpenAICompatibleCatalog() async throws -> [ModelDescriptor] {
        guard let url = URL(string: Self.openAIModelsURL(for: baseURL)) else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 10
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey().isEmpty {
            wire.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: wire)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse("OpenAI-compatible /models returned HTTP \(status)")
        }
        let decoded = try JSONDecoder().decode(CompatibleModelsResponse.self, from: data)
        return decoded.data
            .map { item in
                ModelDescriptor(
                    id: "\(id)-\(item.id)",
                    name: item.id,
                    providerID: id,
                    providerType: providerType,
                    contextWindow: item.contextWindow ?? 32768,
                    supportsTools: true,
                    isOnDevice: scope == .local,
                    tags: scope == .local ? ["local", "openai-compatible"] : ["cloud", "openai-compatible"]
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Probes

    private func probeOllama() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 5
        if !apiKey().isEmpty {
            wire.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: wire)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func probeOpenAICompatible() async -> Bool {
        guard let url = URL(string: Self.openAIModelsURL(for: baseURL)) else { return false }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 5
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey().isEmpty {
            wire.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: wire)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func apiKey() -> String {
        secretProvider?() ?? ""
    }

    // MARK: Helpers

    public static func openAIModelsURL(for endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/v1") ? "\(trimmed)/models" : "\(trimmed)/v1/models"
    }

    public static func openAIChatURL(for endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/v1") ? "\(trimmed)/chat/completions" : "\(trimmed)/v1/chat/completions"
    }

    public static func strippedModelID(_ id: String, scope: Scope) -> String {
        let prefix = scope == .cloud ? "ollama-cloud-" : "ollama-"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// What Ollama's `think` gets: a named level (gpt-oss), true, or an explicit false when the person turned thinking off on a model
    /// that has the switch. A model that cannot think never gets the field (the registry has already switched reasoning off for it).
    static func thinkValue(_ reasoning: ReasoningConfig?) -> ProviderJSON? {
        guard let reasoning else { return nil }
        if reasoning.enabled { return reasoning.level.map { ProviderJSON($0) } ?? ProviderJSON(true) }
        return reasoning.chosenOff ? ProviderJSON(false) : nil
    }

    static func supportsTools(modelName: String) -> Bool {
        let value = modelName.lowercased()
        return ["qwen2.5", "qwen3", "llama3.1", "llama-3.1", "llama3.2", "llama-3.2", "llama3.3", "llama-3.3", "mistral-small", "command-r", "granite", "firefunction", "nemotron", "gpt-oss", "glm-4.5", "glm-4.7", "glm-5.3", "gemma4", "gemma-4", "devstral"]
            .contains { value.contains($0) }
    }

    static func supportsReasoning(modelName: String) -> Bool {
        let value = modelName.lowercased()
        return ["qwen3", "qwq", "deepseek-r1", "deepseek-v3", "gpt-oss", "phi4-reasoning", "magistral", "cogito", "glm-4.5", "glm-5.3"]
            .contains { value.contains($0) }
    }

    static func estimateContextWindow(for modelName: String) -> Int {
        let name = modelName.lowercased()
        if name.contains("llama3") { return 8192 }
        if name.contains("llama2") { return 4096 }
        if name.contains("mistral") { return 32768 }
        if name.contains("codellama") { return 16384 }
        if name.contains("phi") { return 4096 }
        if name.contains("gemma") { return 8192 }
        if name.contains("qwen") { return 32768 }
        return 4096
    }
}

private struct OllamaModelsResponse: Codable {
    let models: [OllamaModel]
}

private struct OllamaModel: Codable {
    let name: String
    let remoteHost: String?
    let capabilities: [String]?
    let details: OllamaModelDetails?
}

private struct OllamaModelDetails: Codable {
    let contextLength: Int?
}

private struct CompatibleModelsResponse: Codable {
    let data: [CompatibleModel]
}

private struct CompatibleModel: Codable {
    let id: String
    let contextWindow: Int?
}

private struct OllamaChatChunk: Decodable {
    let message: ResponseMessage?
    let done: Bool?
    let error: String?

    struct ResponseMessage: Decodable {
        let content: String?
        let toolCalls: [Call]?
        enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls" }
    }

    struct Call: Decodable {
        let id: String?
        let function: Function
    }

    struct Function: Decodable {
        let name: String
        let arguments: ProviderJSON
        let index: Int?
    }
}
