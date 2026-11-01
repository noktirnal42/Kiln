import Foundation

public protocol ModelProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var providerType: ProviderType { get }
    var capabilities: ProviderCapabilities { get }

    func fetchModels() async throws -> [ModelDescriptor]
    func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error>
    func countTokens(_ messages: [ChatMessage]) async throws -> Int
    func checkAvailability() async -> ProviderAvailability
}

public extension ModelProvider {
    func countTokens(_ messages: [ChatMessage]) async throws -> Int {
        messages.reduce(0) { $0 + $1.content.count / 4 }
    }
}

public typealias SecretProvider = @Sendable () -> String?

public extension KeychainService {
    func secretProvider(module: String, key: String) -> SecretProvider {
        let service = self
        return { service.get(module: module, key: key) }
    }

    func staticSecretProvider(module: String, key: String, value: String?) -> SecretProvider {
        let service = self
        return {
            if let value {
                try? service.set(value, module: module, key: key)
            }
            return service.get(module: module, key: key)
        }
    }
}

public let providersKeychainModule = "com.kiln.providers"

public struct ModelSwitchedEvent: ModuleEvent, Encodable, Equatable {
    public let eventType = "model.switched"
    public let sourceModule = "com.kiln.modelregistry"
    public let timestamp = Date()
    public let fromModel: String?
    public let toModel: String

    public init(fromModel: String?, toModel: String) {
        self.fromModel = fromModel
        self.toModel = toModel
    }
}

public actor ModelRegistry {
    public static let cacheTTL: TimeInterval = 300

    private let eventBus: ModuleEventBus
    private var providers: [String: any ModelProvider] = [:]
    private var modelIndex: [String: String] = [:]
    private var modelCache: [String: [ModelDescriptor]] = [:]
    private var cacheStamp: [String: Date] = [:]
    private var activeModelID: String?

    public init(eventBus: ModuleEventBus = .shared) {
        self.eventBus = eventBus
    }

    public func register(_ provider: any ModelProvider) {
        providers[provider.id] = provider
        modelCache.removeValue(forKey: provider.id)
        cacheStamp.removeValue(forKey: provider.id)
    }

    public func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
        modelIndex = modelIndex.filter { $0.value != providerID }
        modelCache.removeValue(forKey: providerID)
        cacheStamp.removeValue(forKey: providerID)
    }

    public func provider(for id: String) async -> (any ModelProvider)? {
        providers[id]
    }

    public func allProviders() async -> [any ModelProvider] {
        providers.values.sorted { $0.id < $1.id }
    }

    public func availabilityMap() async -> [String: ProviderAvailability] {
        var result: [String: ProviderAvailability] = [:]
        for provider in providers.values {
            result[provider.id] = await provider.checkAvailability()
        }
        return result
    }

    public func currentModel() async -> String? {
        activeModelID
    }

    public func models(for providerID: String, forceRefresh: Bool = false) async throws -> [ModelDescriptor] {
        if !forceRefresh,
           let cached = modelCache[providerID],
           let stamp = cacheStamp[providerID],
           Date().timeIntervalSince(stamp) < Self.cacheTTL {
            return cached
        }
        guard let provider = providers[providerID] else {
            throw ProviderError.notFound(providerID)
        }
        let models = try await provider.fetchModels()
        modelCache[providerID] = models
        cacheStamp[providerID] = Date()
        for model in models {
            modelIndex[model.id] = providerID
        }
        return models
    }

    public func allModels(forceRefresh: Bool = false) async -> [ModelDescriptor] {
        var result: [ModelDescriptor] = []
        for provider in providers.values.sorted(by: { $0.id < $1.id }) {
            let availability = await provider.checkAvailability()
            guard availability.isAvailable else { continue }
            if let models = try? await models(for: provider.id, forceRefresh: forceRefresh) {
                result.append(contentsOf: models)
            }
        }
        return result
    }

    public func resolveProvider(
        preferredProviderID: String? = nil,
        requiring capabilities: ProviderCapabilities = []
    ) async -> (any ModelProvider)? {
        var candidates: [any ModelProvider] = []
        if let preferredProviderID, let preferred = providers[preferredProviderID] {
            candidates.append(preferred)
        }
        let others = providers.values
            .filter { $0.id != preferredProviderID }
            .sorted { $0.id < $1.id }
        candidates.append(contentsOf: others)

        for provider in candidates {
            guard provider.capabilities.contains(capabilities) else { continue }
            let availability = await provider.checkAvailability()
            if availability.isAvailable {
                return provider
            }
        }
        return nil
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig? = nil
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let (provider, bare) = try await resolve(modelID: request.model)
        let previous = activeModelID
        if previous != request.model {
            activeModelID = request.model
            await eventBus.publish(ModelSwitchedEvent(fromModel: previous, toModel: request.model))
        }
        let known = modelCache.values.joined().first { $0.id == request.model }
        var forProvider = request
        forProvider.model = bare
        return try await provider.streamChat(
            forProvider, reasoning: Self.reasoning(reasoning, forModelSupporting: known?.supportsReasoning))
    }

    /// Reasoning is on by default, but a model that does not do it rejects the request outright
    /// (Ollama: "does not support thinking"). When the catalog says the model cannot reason, turn
    /// the flag off and keep every other setting; when the catalog has no answer, change nothing.
    public static func reasoning(_ config: ReasoningConfig?, forModelSupporting supports: Bool?) -> ReasoningConfig? {
        guard var config, config.enabled, supports == false else { return config }
        config.enabled = false
        return config
    }

    /// One non-interactive completion, returned as text.
    ///
    /// Unlike `streamChat` this leaves the registry's active model alone and publishes no
    /// `ModelSwitchedEvent`. Background callers (the behavior monitor) use it so scoring a run with
    /// some other model never changes what the user's chat is talking to. Output is capped.
    public func completeSilently(_ request: ChatRequest, maxCharacters: Int = 64 * 1024) async throws -> String {
        let (provider, bare) = try await resolve(modelID: request.model)
        var forProvider = request
        forProvider.model = bare
        var text = ""
        for try await chunk in try await provider.streamChat(forProvider, reasoning: nil) {
            text += chunk.delta?.content ?? ""
            if text.count >= maxCharacters { break }
        }
        return String(text.prefix(maxCharacters))
    }

    /// Finds the provider that serves a catalog model id and the name that provider's own API knows it
    /// by. Catalog ids are "<provider id>-<model name>" so that names from different providers cannot
    /// collide; the provider's API wants only the model name, and sending it the prefixed id is a 404.
    private func resolve(modelID: String) async throws -> (provider: any ModelProvider, bareModelID: String) {
        if let providerID = modelIndex[modelID], let provider = providers[providerID] {
            return (provider, Self.bareModelID(modelID, providerID: providerID))
        }
        // Not catalogued yet: prefer the longest matching provider id ("ollama-cloud" over "ollama").
        for (prefix, provider) in providers.sorted(by: { $0.key.count > $1.key.count }) where modelID.hasPrefix("\(prefix)-") {
            modelIndex[modelID] = prefix
            return (provider, Self.bareModelID(modelID, providerID: prefix))
        }
        throw ProviderError.notFound("model '\(modelID)' (no registered provider serves it)")
    }

    public static func bareModelID(_ modelID: String, providerID: String) -> String {
        let prefix = "\(providerID)-"
        return modelID.hasPrefix(prefix) ? String(modelID.dropFirst(prefix.count)) : modelID
    }
}
