import Foundation

public struct OpenRouterProvider: ModelProvider {
    public let id = "openrouter"
    public let name = "OpenRouter"
    public let providerType: ProviderType = .openRouter
    public let capabilities: ProviderCapabilities = [.streaming, .reasoning, .tools, .vision]

    private let baseURL: String
    private let secretProvider: SecretProvider?
    private let session: URLSession

    public init(
        baseURL: String? = nil,
        secretProvider: SecretProvider? = nil,
        session: URLSession = ProviderSessions.shared
    ) {
        self.baseURL = (baseURL ?? "https://openrouter.ai/api/v1").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.secretProvider = secretProvider
        self.session = session
    }

    public func checkAvailability() async -> ProviderAvailability {
        if (secretProvider?() ?? "").isEmpty {
            return .unavailable("No OpenRouter API key configured. Add one in Settings → Providers (stored in Keychain).")
        }
        return .available()
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        guard let url = URL(string: "\(baseURL)/models") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 15
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = secretProvider?() ?? ""
        if !key.isEmpty {
            wire.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: wire)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenAICompatibleTransport.providerError(status: status, body: data)
        }
        return try Self.catalog(from: data)
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        return OpenAICompatibleTransport.stream(
            url: url,
            apiKey: secretProvider?() ?? "",
            request: request,
            reasoning: reasoning,
            session: session
        )
    }

    static func catalog(from data: Data) throws -> [ModelDescriptor] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(OpenRouterModelsResponse.self, from: data)
        return response.data.map { model in
            let explicitlyFree = model.id == "openrouter/free" || model.id.hasSuffix(":free")
            let supportsReasoning = model.supportedParameters?.contains("reasoning") == true || model.id.contains("reasoning")
            let supportsTools = model.id == "openrouter/free" || model.supportedParameters?.contains("tools") == true
            let supportsVision = model.architecture?.inputModalities?.contains("image") == true
            return ModelDescriptor(
                id: "openrouter-\(model.id)",
                name: model.id == "openrouter/free" ? "OpenRouter Free Models Router" : model.name,
                providerID: "openrouter",
                providerType: .openRouter,
                contextWindow: model.contextLength ?? ModelDescriptor.unknownHostedWindow,
                supportsReasoning: supportsReasoning,
                supportsTools: supportsTools,
                supportsVision: supportsVision,
                isOnDevice: false,
                tags: explicitlyFree ? ["cloud", "openrouter", "free"] : ["cloud", "openrouter"]
            )
        }
    }
}

private struct OpenRouterModelsResponse: Codable {
    let data: [OpenRouterModel]
}

private struct OpenRouterModel: Codable {
    let id: String
    let name: String
    let contextLength: Int?
    let supportedParameters: [String]?
    let architecture: Architecture?

    struct Architecture: Codable {
        let inputModalities: [String]?
    }
}

public struct NVIDIANIMProvider: ModelProvider {
    public let id = "nvidia-nim"
    public let name = "NVIDIA NIM"
    public let providerType: ProviderType = .nvidiaNIM
    public let capabilities: ProviderCapabilities = [.streaming, .reasoning, .tools]

    private let baseURL: String
    private let secretProvider: SecretProvider?
    private let session: URLSession

    public init(
        baseURL: String? = nil,
        secretProvider: SecretProvider? = nil,
        session: URLSession = ProviderSessions.shared
    ) {
        self.baseURL = (baseURL ?? "https://integrate.api.nvidia.com/v1").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.secretProvider = secretProvider
        self.session = session
    }

    public func checkAvailability() async -> ProviderAvailability {
        if (secretProvider?() ?? "").isEmpty {
            return .unavailable("No NVIDIA NIM API key configured. Add one in Settings → Providers (stored in Keychain).")
        }
        return .available()
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        guard let url = URL(string: "\(baseURL)/models") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 15
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = secretProvider?() ?? ""
        if !key.isEmpty {
            wire.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: wire)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenAICompatibleTransport.providerError(status: status, body: data)
        }
        return try Self.catalog(from: data)
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        // GLM models use NVIDIA's provider-specific reasoning fields; sending
        // the generic OpenAI `reasoning` object alongside them makes real NIM
        // deployments reject otherwise valid requests.
        return OpenAICompatibleTransport.stream(
            url: url,
            apiKey: secretProvider?() ?? "",
            request: request,
            reasoning: nil,
            session: session,
            extraFields: Self.requestOptions(model: request.model, reasoning: reasoning)
        )
    }

    static func catalog(from data: Data) throws -> [ModelDescriptor] {
        let response = try JSONDecoder().decode(NIMModelsResponse.self, from: data)
        return response.data.compactMap { item in
            let lowered = item.id.lowercased()
            guard !["embed", "rerank", "reward", "detector", "nemoguard", "safety", "nvclip", "calibration"]
                .contains(where: lowered.contains) else { return nil }
            let glmFlash = lowered == "z-ai/glm-5.3-flash"
            let glm = lowered.hasPrefix("z-ai/glm-")
            let supportsTools = Self.supportsTools(modelID: lowered)
            return ModelDescriptor(
                id: "nvidia-nim-\(item.id)",
                name: glmFlash ? "GLM 5.3 Flash" : item.id,
                providerID: "nvidia-nim",
                providerType: .nvidiaNIM,
                contextWindow: glmFlash ? 1_048_576 : ModelDescriptor.unknownHostedWindow,
                supportsReasoning: glm || lowered.contains("reasoning"),
                supportsTools: supportsTools,
                supportsVision: glmFlash || lowered.contains("vision") || lowered.contains("-vl"),
                isOnDevice: false,
                tags: ["cloud", "nvidia", "nim"] + (supportsTools ? ["tools"] : [])
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func supportsTools(modelID: String) -> Bool {
        ["z-ai/glm-4", "z-ai/glm-5", "meta/llama-3.1", "meta/llama-3.2", "meta/llama-3.3", "qwen", "mistral-small", "command-r", "nvidia/llama-3.1-nemotron"]
            .contains { modelID.contains($0) }
    }

    static func requestOptions(model: String, reasoning: ReasoningConfig?) -> [String: ProviderJSON] {
        guard model.hasPrefix("z-ai/glm-5.3") || model.hasSuffix("z-ai/glm-5.3-flash") || model.contains("z-ai/glm-5.3") else { return [:] }
        let effort: String
        if reasoning?.enabled != true || reasoning?.depth == .minimal {
            effort = "low"
        } else if reasoning?.depth == .balanced {
            effort = "high"
        } else {
            effort = "max"
        }
        return [
            "reasoning_effort": ProviderJSON(effort),
            "chat_template_kwargs": ProviderJSON(["clear_thinking": ProviderJSON(true)]),
        ]
    }
}

private struct NIMModelsResponse: Codable {
    let data: [NIMModel]
}

private struct NIMModel: Codable {
    let id: String
}

public struct CustomEndpointProvider: ModelProvider {
    public let id = "custom"
    public let name = "Custom Endpoint"
    public let providerType: ProviderType = .customEndpoint
    public let capabilities: ProviderCapabilities = [.streaming, .reasoning, .tools, .vision]

    private let baseURL: String
    private let extraHeaders: [String: String]
    private let secretProvider: SecretProvider?
    private let session: URLSession

    public init(
        baseURL: String,
        headers: [String: String] = [:],
        secretProvider: SecretProvider? = nil,
        session: URLSession = ProviderSessions.shared
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.extraHeaders = headers
        self.secretProvider = secretProvider
        self.session = session
    }

    public func checkAvailability() async -> ProviderAvailability {
        if baseURL.isEmpty {
            return .unavailable("No custom endpoint base URL configured. Set one in Settings → Providers.")
        }
        return .available()
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        guard let url = URL(string: "\(baseURL)/models") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        var wire = URLRequest(url: url)
        wire.timeoutInterval = 15
        wire.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = secretProvider?() ?? ""
        if !key.isEmpty {
            wire.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in extraHeaders {
            wire.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: wire)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenAICompatibleTransport.providerError(status: status, body: data)
        }
        let decoded = try JSONDecoder().decode(CustomModelsResponse.self, from: data)
        return decoded.data.map { item in
            ModelDescriptor(
                id: "custom-\(item.id)",
                name: item.name ?? item.id,
                providerID: "custom",
                providerType: .customEndpoint,
                contextWindow: item.contextLength ?? ModelDescriptor.unknownHostedWindow,
                supportsReasoning: true,
                supportsTools: true,
                supportsVision: true,
                isOnDevice: false,
                tags: ["custom", "openai-compatible"]
            )
        }
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.missingConfiguration("invalid base URL")
        }
        return OpenAICompatibleTransport.stream(
            url: url,
            apiKey: secretProvider?() ?? "",
            request: request,
            reasoning: reasoning,
            session: session,
            headers: extraHeaders
        )
    }
}

private struct CustomModelsResponse: Codable {
    let data: [CustomModel]
}

private struct CustomModel: Codable {
    let id: String
    let name: String?
    let contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case contextLength = "context_length"
    }
}
