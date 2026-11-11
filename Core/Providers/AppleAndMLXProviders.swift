import Foundation
import ModelLabCore
import FoundationModels

public struct AppleFoundationProvider: ModelProvider {
    public let id = "apple-foundation"
    public let name = "Apple Foundation Models"
    public let providerType: ProviderType = .appleFoundation
    public let capabilities: ProviderCapabilities = [.streaming, .onDevice]

    public init() {}

    public func checkAvailability() async -> ProviderAvailability {
        guard #available(macOS 26.0, *) else {
            return .unavailable("Apple Foundation Models require macOS 26.0 or later.")
        }
        return Self.availability(from: SystemLanguageModel.default.availability)
    }

    @available(macOS 26.0, *)
    static func availability(from modelAvailability: SystemLanguageModel.Availability) -> ProviderAvailability {
        switch modelAvailability {
        case .available:
            return .available()
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac does not support Apple Intelligence (device not eligible).")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is not enabled. Turn it on in System Settings → Apple Intelligence & Siri.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading or preparing its on-device model.")
        case .unavailable:
            return .unavailable("Apple Foundation Models are unavailable on this Mac.")
        }
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        let availability = await checkAvailability()
        guard availability.isAvailable else {
            throw ProviderError.engineUnavailable(availability.reason ?? "Apple Foundation Models unavailable")
        }
        let catalog = [
            ModelDescriptor(
                id: "apple-foundation-model",
                name: "Foundation Model",
                providerID: id,
                providerType: .appleFoundation,
                contextWindow: 4096,
                isOnDevice: true,
                tags: ["apple", "on-device", "private"]
            ),
        ]
        return catalog
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard request.messages.allSatisfy({ $0.images.isEmpty }) else {
            throw ProviderError.engineUnavailable("Image input is not yet supported by Apple Foundation Models in Kiln.")
        }
        guard #available(macOS 26.0, *) else {
            throw ProviderError.engineUnavailable("Apple Foundation Models require macOS 26.0 or later.")
        }
        guard SystemLanguageModel.default.availability == .available else {
            let availability = Self.availability(from: SystemLanguageModel.default.availability)
            throw ProviderError.engineUnavailable(availability.reason ?? "Apple Foundation Models unavailable")
        }

        let instructions = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n")
        let session = LanguageModelSession(instructions: instructions.isEmpty ? nil : instructions)
        let prompt = request.messages
            .filter { $0.role != .system }
            .map { "\($0.role.rawValue.capitalized):\n\($0.content)" }
            .joined(separator: "\n\n")
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: min(request.maxTokens, 4096)
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        // streamResponse yields cumulative snapshots; the wire
                        // contract here is deltas only, so diff each snapshot
                        // against everything already emitted.
                        let complete = snapshot.content
                        let delta = complete.hasPrefix(emitted) ? String(complete.dropFirst(emitted.count)) : complete
                        emitted = complete
                        if !delta.isEmpty {
                            continuation.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: delta)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// An explicit cloud choice; on-device requests never fall back to this provider automatically.
public struct ApplePrivateCloudProvider: ModelProvider {
    public let id = "apple-private-cloud"
    public let name = "Apple Private Cloud Compute"
    public let providerType: ProviderType = .appleFoundation
    public let capabilities: ProviderCapabilities = [.streaming, .privateCloud]

    public init() {}

    public func checkAvailability() async -> ProviderAvailability {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else {
            return .unavailable("Private Cloud Compute requires macOS 27 or later.")
        }
        switch PrivateCloudComputeLanguageModel().availability {
        case .available: return .available()
        case .unavailable(.deviceNotEligible): return .unavailable("This Mac is not eligible for Private Cloud Compute.")
        case .unavailable(.systemNotReady): return .unavailable("Private Cloud Compute is not ready. Check Apple Intelligence, network access, and the app's entitlement.")
        case .unavailable: return .unavailable("Private Cloud Compute is unavailable on this Mac.")
        }
        #else
        return .unavailable("This build does not include the macOS 27 SDK required for Private Cloud Compute.")
        #endif
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        let status = await checkAvailability()
        guard status.isAvailable else { throw ProviderError.engineUnavailable(status.reason ?? "Private Cloud Compute unavailable") }
        return [ModelDescriptor(id: "apple-private-cloud-model", name: "Private Cloud Compute", providerID: id,
                                providerType: .appleFoundation, contextWindow: 32768, isOnDevice: false,
                                tags: ["apple", "private-cloud"])]
    }

    public func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard request.messages.allSatisfy({ $0.images.isEmpty }) else {
            throw ProviderError.engineUnavailable("Image input is not yet supported by Apple Private Cloud Compute in Kiln.")
        }
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { throw ProviderError.engineUnavailable("Private Cloud Compute requires macOS 27 or later.") }
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            let status = await checkAvailability()
            throw ProviderError.engineUnavailable(status.reason ?? "Private Cloud Compute unavailable")
        }
        let instructions = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: instructions.isEmpty ? nil : instructions)
        let prompt = request.messages.filter { $0.role != .system }.map { "\($0.role.rawValue.capitalized):\n\($0.content)" }.joined(separator: "\n\n")
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: min(request.maxTokens, 4096))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let complete = snapshot.content
                        let delta = complete.hasPrefix(emitted) ? String(complete.dropFirst(emitted.count)) : complete
                        emitted = complete
                        if !delta.isEmpty { continuation.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: delta))) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        throw ProviderError.engineUnavailable("This build does not include the macOS 27 SDK required for Private Cloud Compute.")
        #endif
    }
}

/// Local MLX inference over the shared Hugging Face cache (the "universal model store"). Lists the
/// language models installed there and runs them with the MLX engine, reading weights straight from the
/// snapshot folder; nothing is downloaded.
public struct MLXProvider: ModelProvider {
    public let id = "mlx"
    public let name = "MLX (Local)"
    public let providerType: ProviderType = .mlx
    public let capabilities: ProviderCapabilities = [.streaming, .onDevice, .metalAcceleration, .removableStore]

    private let store: @Sendable () -> UniversalModelStore

    /// `store` is resolved on every call, so a folder chosen in Settings takes effect without a restart.
    public init(store: @escaping @Sendable () -> UniversalModelStore = { UniversalModelStore() }) {
        self.store = store
    }

    public init(store fixed: UniversalModelStore) {
        self.store = { fixed }
    }

    static func missingStoreMessage(_ root: URL) -> String {
        "No language models were found in the model store (\(root.path)). In Settings → Local model store, choose the folder that holds your models--org--repo folders."
    }

    public func checkAvailability() async -> ProviderAvailability {
        let current = store()
        let models = await current.installedOffPool().filter(\.isLanguageModel)
        return models.isEmpty ? .unavailable(Self.missingStoreMessage(current.root)) : .available()
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        await store().installedOffPool().filter(\.isLanguageModel).map { installed in
            ModelDescriptor(
                id: "mlx-\(installed.repoID)",
                name: installed.repoID,
                providerID: "mlx",
                providerType: .mlx,
                contextWindow: 4096,
                supportsTools: false,
                isOnDevice: true,
                tags: ["local", "mlx", "huggingface"]
            )
        }
    }

    public func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        guard request.messages.allSatisfy({ $0.images.isEmpty }) else {
            throw ProviderError.engineUnavailable("Image input is not yet supported by the MLX chat engine in Kiln.")
        }
        let current = store()
        // The registry hands over the bare repo id ("org/repo").
        guard let model = await current.installedOffPool().last(where: { $0.repoID == request.model && $0.isLanguageModel }) else {
            throw ProviderError.notFound("model '\(request.model)' is not in the model store at \(current.root.path)")
        }
        let engine = MLXEngineCache.shared.engine(for: URL(fileURLWithPath: model.path))
        guard !request.messages.isEmpty else { throw ProviderError.invalidResponse("no messages to answer") }
        let turns = request.messages.map { message in
            ChatTurn(role: message.role.rawValue, text: message.content, toolCallID: message.metadata["tool_call_id"],
                     calls: message.toolCalls.map { .init(id: $0.id, name: $0.name, arguments: $0.arguments) })
        }
        let stream = engine.streamConversation(turns)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in stream { continuation.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: piece))) }
                    continuation.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: ""), finishReason: .stop))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Keeps the most recently used model resident. Loading is the slow part, and two multi-gigabyte models
/// should not be in memory at once, so switching models drops the previous one.
final class MLXEngineCache: @unchecked Sendable {
    static let shared = MLXEngineCache()
    private let lock = NSLock()
    private var path: String?
    private var current: MLXInferenceProvider?

    func engine(for directory: URL) -> MLXInferenceProvider {
        lock.lock(); defer { lock.unlock() }
        if let current, path == directory.path { return current }
        let engine = MLXInferenceProvider(modelDirectory: directory)
        current = engine
        path = directory.path
        return engine
    }
}
