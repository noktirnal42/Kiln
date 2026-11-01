import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Local LLM inference via MLX Swift LM. Backed by Metal, so it only makes
/// sense on Apple silicon. The model container is loaded lazily on first use
/// (downloading from Hugging Face if it isn't cached yet) and kept resident
/// for subsequent turns in the same Playground session.
public actor MLXInferenceProvider: InferenceProvider {
    public nonisolated let name = "MLX (local)"

    /// Works around a crash reproduced on this machine (macOS 27 beta /
    /// mlx-swift 0.31.6): a real segfault inside MLX's own C++ core
    /// (`mlx::core::detail::CompilerCache::__emplace_unique`, a bad pointer
    /// dereference), not application code. `compile(enable:)` is MLX's
    /// documented global switch for its graph-compilation cache; disabling
    /// it routes around the crashing code path at the cost of skipping that
    /// JIT optimization. Runs exactly once per process via `static let`.
    /// See CAPABILITIES.md for the full crash report.
    private static let disableCompileCacheWorkaround: Void = {
        MLX.compile(enable: false)
    }()

    private let repoID: String
    private let adapterDirectory: URL?
    /// When set, weights and tokenizer are read from this folder (a Hugging Face cache snapshot) and nothing is
    /// downloaded. Each reply is generated from the history it is given, not from a resident session.
    private let modelDirectory: URL?
    private var container: ModelContainer?
    private var session: ChatSession?
    public private(set) var loadProgress: Double = 0

    /// - Parameter adapterDirectory: an optional LoRA adapter, produced by
    ///   `MLXFineTuningProvider`, to apply on top of the base model
    ///   (`adapter_config.json` + `adapters.safetensors`). Must have been
    ///   trained against this same `repoID`, or `LoRAContainer.load(into:)`
    ///   throws `ModelAdapterError.incompatibleModelType`.
    public init(repoID: String, adapterDirectory: URL? = nil) {
        self.repoID = repoID
        self.adapterDirectory = adapterDirectory
        self.modelDirectory = nil
        _ = Self.disableCompileCacheWorkaround
    }

    /// Loads an already-downloaded model from `modelDirectory` (a snapshot with config.json and safetensors).
    public init(modelDirectory: URL) {
        self.repoID = modelDirectory.lastPathComponent
        self.adapterDirectory = nil
        self.modelDirectory = modelDirectory
        _ = Self.disableCompileCacheWorkaround
    }

    public nonisolated func capability() -> CapabilityStatus {
        CapabilityDetector.detectHardware().status
    }

    public nonisolated func streamRespond(prompt: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(prompt: prompt, history: history, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Keeps `ChatSession` (non-Sendable) entirely inside the actor's
    /// isolation domain; only the Sendable `String` chunks and `Error`
    /// cross the continuation boundary.
    private func runStream(prompt: String, history: [ChatTurn], continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            if let modelDirectory {
                guard capability().isAvailable else {
                    throw InferenceError.unavailable(reason: capability().reason ?? "MLX unavailable.")
                }
                let container = try await ensureContainer(from: modelDirectory)
                let messages: [Chat.Message] = history.compactMap { turn in
                    switch turn.role {
                    case "system": .system(turn.text)
                    case "user": .user(turn.text)
                    case "assistant": .assistant(turn.text)
                    default: nil
                    }
                }
                let local = ChatSession(container, history: messages)
                for try await chunk in local.streamResponse(to: prompt) { continuation.yield(chunk) }
                continuation.finish()
                return
            }
            let session = try await ensureSession()
            for try await chunk in session.streamResponse(to: prompt) {
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func ensureContainer(from directory: URL) async throws -> ModelContainer {
        if let container { return container }
        let loaded = try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
        self.container = loaded
        return loaded
    }

    private func ensureSession() async throws -> ChatSession {
        if let session { return session }
        guard capability().isAvailable else {
            throw InferenceError.unavailable(reason: capability().reason ?? "MLX unavailable.")
        }
        let configuration = ModelConfiguration(id: repoID)
        let loaded = try await #huggingFaceLoadModelContainer(configuration: configuration) { [weak self] progress in
            Task { await self?.setProgress(progress.fractionCompleted) }
        }
        if let adapterDirectory {
            let adapter = try LoRAContainer.from(directory: adapterDirectory)
            try await loaded.perform { context in
                try adapter.load(into: context.model)
            }
        }
        self.container = loaded
        let newSession = ChatSession(loaded)
        self.session = newSession
        return newSession
    }

    private func setProgress(_ value: Double) {
        loadProgress = value
    }
}
