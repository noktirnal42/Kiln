import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXOptimizers
import MLXHuggingFace
import HuggingFace
import Tokenizers

public struct FineTuningJob: Sendable {
    public let baseModelRepoID: String
    public let trainingTexts: [String]
    public let validationTexts: [String]
    public let rank: Int
    public let numLayers: Int
    public let iterations: Int
    public let learningRate: Float
    public let batchSize: Int
    public let outputName: String

    public init(
        baseModelRepoID: String,
        trainingTexts: [String],
        validationTexts: [String] = [],
        rank: Int = 8,
        numLayers: Int = 4,
        iterations: Int = 200,
        learningRate: Float = 1e-5,
        batchSize: Int = 1,
        outputName: String
    ) {
        self.baseModelRepoID = baseModelRepoID
        self.trainingTexts = trainingTexts
        self.validationTexts = validationTexts
        self.rank = rank
        self.numLayers = numLayers
        self.iterations = iterations
        self.learningRate = learningRate
        self.batchSize = batchSize
        self.outputName = outputName
    }
}

public struct FineTuningResult: Sendable {
    public let adapterRelativePath: String
    public let finalTrainingLoss: Float?
    public let finalValidationLoss: Float?
    public let metrics: [MetricPoint]
}

public enum FineTuningError: LocalizedError {
    case unavailable(reason: String)
    case emptyTrainingData
    case incompatibleBaseModel(String)
    case cancelled
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .emptyTrainingData: "Add at least one training example before fine-tuning."
        case .incompatibleBaseModel(let id):
            "\(id) doesn't expose LoRA-adaptable layers in mlx-swift-lm's current model support."
        case .cancelled: "Fine-tuning was cancelled."
        case .invalidConfiguration(let reason): reason
        }
    }
}

/// Real LoRA fine-tuning via `mlx-swift-lm`'s `LoRATrain` API: freezes the
/// base model's weights, attaches trainable low-rank adapter layers to the
/// last `numLayers` transformer blocks, and trains them against plain-text
/// examples with cross-entropy loss. Produces an adapter directory
/// (`adapter_config.json` + `adapters.safetensors`, a few megabytes, not a
/// full model copy) in the format `LoRAContainer.from(directory:)` expects,
/// so `MLXInferenceProvider` can load it back and apply it to the same base
/// model for inference.
///
/// Honest caveat: this exercises the same MLX compute path that this app's
/// own investigation found crashes during plain generation on this specific
/// beta macOS/toolchain combination (see CAPABILITIES.md). The code here is
/// real, not a stub, but has not been verified to complete a training run to
/// success on this machine for that reason.
public struct MLXFineTuningProvider: Sendable {
    public let name = "MLX LoRA Fine-Tuning"

    public init() {}

    public func capability() -> CapabilityStatus {
        CapabilityDetector.detectMLX().status
    }

    public static func validate(job: FineTuningJob) throws {
        guard job.trainingTexts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw FineTuningError.emptyTrainingData
        }
        guard !job.baseModelRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FineTuningError.invalidConfiguration("Enter a base model repository.")
        }
        guard job.rank > 0, job.numLayers > 0, job.iterations > 0, job.batchSize > 0,
              job.learningRate.isFinite, job.learningRate > 0 else {
            throw FineTuningError.invalidConfiguration("Rank, layers, iterations, batch size, and learning rate must be positive.")
        }
        guard !job.outputName.isEmpty, job.outputName != ".", job.outputName != "..",
              !job.outputName.contains("/"), !job.outputName.contains("\\") else {
            throw FineTuningError.invalidConfiguration("The output name must be a single file name.")
        }
    }

    public func fineTune(
        job: FineTuningJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) async throws -> FineTuningResult {
        try Self.validate(job: job)
        guard capability().isAvailable else {
            throw FineTuningError.unavailable(reason: capability().reason ?? "MLX unavailable.")
        }
        try Task.checkCancellation()
        let adapterDirectory = LibraryPaths.models.appendingPathComponent(job.outputName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: adapterDirectory.path) else {
            throw FineTuningError.invalidConfiguration("An artifact with this output name already exists. Choose another name.")
        }

        onProgress(TrainingProgress(phase: .preparingData, message: "Loading base model \(job.baseModelRepoID)"))
        let configuration = ModelConfiguration(id: job.baseModelRepoID)
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration) { progress in
            _ = progress
        }

        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
        let adapterURL = adapterDirectory.appendingPathComponent("adapters.safetensors")
        let configURL = adapterDirectory.appendingPathComponent("adapter_config.json")

        // `LoRAContainer.from(directory:)` — the real load path this adapter
        // is meant to round-trip through later (see `MLXInferenceProvider`)
        // — expects exactly this pair of files, so the config is written
        // alongside the weights rather than just the `.safetensors` file.
        let loraConfig = LoRAConfiguration(numLayers: job.numLayers, loraParameters: .init(rank: job.rank))
        try JSONEncoder().encode(loraConfig).write(to: configURL)

        onProgress(TrainingProgress(
            phase: .training,
            message: "Training LoRA adapter (rank \(job.rank), \(job.numLayers) layers) for \(job.iterations) iterations"
        ))

        let validationTexts = job.validationTexts.isEmpty ? job.trainingTexts : job.validationTexts

        let (trainLoss, valLoss) = try await container.perform { context in
            do {
                _ = try LoRAContainer.from(model: context.model, configuration: loraConfig)
            } catch {
                throw FineTuningError.incompatibleBaseModel(job.baseModelRepoID)
            }

            let optimizer = Adam(learningRate: job.learningRate)
            let parameters = LoRATrain.Parameters(
                batchSize: job.batchSize,
                iterations: job.iterations,
                stepsPerReport: max(1, job.iterations / 20),
                stepsPerEval: max(1, job.iterations / 5),
                adapterURL: adapterURL
            )

            var lastTrainLoss: Float?
            var lastValLoss: Float?

            try LoRATrain.train(
                model: context.model,
                train: job.trainingTexts,
                validate: validationTexts,
                optimizer: optimizer,
                tokenizer: context.tokenizer,
                parameters: parameters
            ) { progress in
                switch progress {
                case .train(let iteration, let loss, _, let tokensPerSecond):
                    lastTrainLoss = loss
                    onProgress(TrainingProgress(
                        phase: .training,
                        message: "iteration \(iteration): loss \(String(format: "%.4f", loss)), \(Int(tokensPerSecond)) tok/s"
                    ))
                case .validation(let iteration, let validationLoss, _):
                    lastValLoss = validationLoss
                    onProgress(TrainingProgress(
                        phase: .evaluating,
                        message: "iteration \(iteration): validation loss \(String(format: "%.4f", validationLoss))"
                    ))
                case .save(let iteration, _):
                    onProgress(TrainingProgress(phase: .savingArtifact, message: "Checkpoint saved at iteration \(iteration)"))
                }
                return Task.isCancelled ? .stop : .more
            }

            try LoRATrain.saveLoRAWeights(model: context.model, url: adapterURL)
            return (lastTrainLoss, lastValLoss)
        }

        if Task.isCancelled {
            throw CancellationError()
        }

        onProgress(TrainingProgress(phase: .done, message: "Done"))
        var metrics: [MetricPoint] = []
        if let trainLoss { metrics.append(MetricPoint(name: "trainingLoss", value: Double(trainLoss))) }
        if let valLoss { metrics.append(MetricPoint(name: "validationLoss", value: Double(valLoss))) }

        return FineTuningResult(
            adapterRelativePath: job.outputName,
            finalTrainingLoss: trainLoss,
            finalValidationLoss: valLoss,
            metrics: metrics
        )
    }
}
