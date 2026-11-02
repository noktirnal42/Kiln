import Foundation
import ModelLabCore
import FoundationModels

public struct AppleFoundationProvider: ModelProvider {
    public let id = "apple-foundation"
    public let name = "Apple Foundation Models"
    public let providerType: ProviderType = .appleFoundation
    public let capabilities: ProviderCapabilities = [.streaming, .onDevice, .privateCloud]

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
        let current = store()
        // The registry hands over the bare repo id ("org/repo").
        guard let model = await current.installedOffPool().last(where: { $0.repoID == request.model && $0.isLanguageModel }) else {
            throw ProviderError.notFound("model '\(request.model)' is not in the model store at \(current.root.path)")
        }
        let engine = MLXEngineCache.shared.engine(for: URL(fileURLWithPath: model.path))
        guard let prompt = request.messages.last(where: { $0.role == .user })?.content else {
            throw ProviderError.invalidResponse("no user message to answer")
        }
        let lastUser = request.messages.lastIndex(where: { $0.role == .user }) ?? request.messages.endIndex
        let history = request.messages[..<lastUser].map { ChatTurn(role: $0.role.rawValue, text: $0.content) }
        let stream = engine.streamRespond(prompt: prompt, history: Array(history))
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
