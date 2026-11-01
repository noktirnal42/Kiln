import Foundation
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

/// MLX local inference. The MLX runtime (mlx-swift) is not linked into this
/// build; this provider reports that honestly and still lists models from the
/// shared Hugging Face cache so the model catalog works across modules.
public struct MLXProvider: ModelProvider {
    public let id = "mlx"
    public let name = "MLX (Local)"
    public let providerType: ProviderType = .mlx
    public let capabilities: ProviderCapabilities = [.streaming, .onDevice, .metalAcceleration, .removableStore]

    private let store: UniversalModelStore

    public init(store: UniversalModelStore = UniversalModelStore()) {
        self.store = store
    }

    public static let unavailabilityReason = "MLX runtime is not linked into this build. Local MLX inference arrives with the Phase 2 Model Lab engine integration (AILab workarounds: MLX.compile(enable:false), GUI-context pattern)."

    public func checkAvailability() async -> ProviderAvailability {
        .unavailable(Self.unavailabilityReason)
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        store.installed().map { installed in
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
        throw ProviderError.engineUnavailable(Self.unavailabilityReason)
    }
}
