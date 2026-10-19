import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import MLXHuggingFace
import HuggingFace
import Tokenizers

public struct LogitDistillationJob: Sendable {
    public let teacherRepoID: String
    public let studentRepoID: String
    public let trainingTexts: [String]
    public let validationTexts: [String]
    public let rank: Int
    public let numLayers: Int
    public let iterations: Int
    public let learningRate: Float
    public let batchSize: Int
    /// Distillation temperature (Hinton et al.): both teacher and student
    /// logits are divided by this before softmax, softening the
    /// distributions so the student can learn from the teacher's relative
    /// confidence across *all* tokens, not just its single top pick.
    public let temperature: Float
    public let outputName: String

    public init(
        teacherRepoID: String,
        studentRepoID: String,
        trainingTexts: [String],
        validationTexts: [String] = [],
        rank: Int = 8,
        numLayers: Int = 4,
        iterations: Int = 200,
        learningRate: Float = 1e-5,
        batchSize: Int = 2,
        temperature: Float = 2.0,
        outputName: String
    ) {
        self.teacherRepoID = teacherRepoID
        self.studentRepoID = studentRepoID
        self.trainingTexts = trainingTexts
        self.validationTexts = validationTexts
        self.rank = rank
        self.numLayers = numLayers
        self.iterations = iterations
        self.learningRate = learningRate
        self.batchSize = batchSize
        self.temperature = temperature
        self.outputName = outputName
    }
}

public struct LogitDistillationResult: Sendable {
    public let adapterRelativePath: String
    public let finalTrainingLoss: Float?
    public let metrics: [MetricPoint]
}

public enum LogitDistillationError: LocalizedError {
    case unavailable(reason: String)
    case emptyTrainingData
    case incompatibleBaseModel(String)
    case vocabularyMismatch(teacherRepoID: String, teacherVocabSize: Int, studentRepoID: String, studentVocabSize: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .emptyTrainingData: "Add at least one training example before distilling."
        case .incompatibleBaseModel(let id):
            "\(id) doesn't expose LoRA-adaptable layers in mlx-swift-lm's current model support."
        case .vocabularyMismatch(let teacherRepoID, let teacherVocab, let studentRepoID, let studentVocab):
            "\(teacherRepoID) (vocab size \(teacherVocab)) and \(studentRepoID) (vocab size \(studentVocab)) don't share a vocabulary. Logit distillation compares per-token probability distributions directly, so the teacher and student must use the same tokenizer — typically the same model family (e.g. distilling a larger Llama into a smaller Llama)."
        case .cancelled: "Distillation was cancelled."
        }
    }
}

/// Real logit-level knowledge distillation, distinct from
/// `DistillationProvider`'s synthetic-data approach: rather than having the
/// teacher generate text examples for the student to imitate, this loads
/// both the teacher and student as plain (non-actor-wrapped) `ModelContext`
/// values via `#huggingFaceLoadModel` — giving direct, synchronous access to
/// both models' raw forward passes in the same scope — and trains a LoRA
/// adapter on the student to match the teacher's *softened output
/// distribution* (Hinton et al. knowledge distillation) at every token
/// position of a real text corpus, via KL-divergence-style loss and the same
/// `valueAndGrad`/`Adam` machinery `MLXFineTuningProvider` and
/// `SmallLMPretrainingProvider` already use.
///
/// Honest constraints:
/// - The teacher and student must share a tokenizer/vocabulary (checked
///   before training starts) — this only makes sense between models of the
///   same family, unlike `DistillationProvider`'s synthetic-data path which
///   places no such constraint on the teacher.
/// - Loading two full models into memory at once roughly doubles the memory
///   footprint versus a normal fine-tune; pick a small teacher/student pair
///   on memory-constrained machines.
/// - Exercises the same MLX compute path this app's own testing found is
///   intermittently crash-prone on this beta OS (see CAPABILITIES.md).
public struct LogitDistillationProvider: Sendable {
    public let name = "Logit Distillation"

    public init() {}

    public func capability() -> CapabilityStatus {
        CapabilityDetector.detectMLX().status
    }

    public func distill(
        job: LogitDistillationJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) async throws -> LogitDistillationResult {
        guard capability().isAvailable else {
            throw LogitDistillationError.unavailable(reason: capability().reason ?? "MLX unavailable.")
        }
        guard !job.trainingTexts.isEmpty else { throw LogitDistillationError.emptyTrainingData }
        try Task.checkCancellation()

        onProgress(TrainingProgress(phase: .preparingData, message: "Loading teacher model \(job.teacherRepoID)"))
        let teacherContext = try await #huggingFaceLoadModel(
            configuration: ModelConfiguration(id: job.teacherRepoID))
        try Task.checkCancellation()

        onProgress(TrainingProgress(phase: .preparingData, message: "Loading student model \(job.studentRepoID)"))
        let studentContext = try await #huggingFaceLoadModel(
            configuration: ModelConfiguration(id: job.studentRepoID))
        try Task.checkCancellation()

        // A one-token dummy forward pass on each model is the cheapest real
        // way to compare vocabulary sizes before committing to a full run.
        let probe = MLXArray([0], [1, 1])
        let teacherVocabSize = teacherContext.model(probe, cache: nil).dim(-1)
        let studentVocabSize = studentContext.model(probe, cache: nil).dim(-1)
        guard teacherVocabSize == studentVocabSize else {
            throw LogitDistillationError.vocabularyMismatch(
                teacherRepoID: job.teacherRepoID, teacherVocabSize: teacherVocabSize,
                studentRepoID: job.studentRepoID, studentVocabSize: studentVocabSize
            )
        }

        let adapterDirectory = LibraryPaths.models.appendingPathComponent(job.outputName, isDirectory: true)
        try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
        let adapterURL = adapterDirectory.appendingPathComponent("adapters.safetensors")
        let configURL = adapterDirectory.appendingPathComponent("adapter_config.json")

        let loraConfig = LoRAConfiguration(numLayers: job.numLayers, loraParameters: .init(rank: job.rank))
        try JSONEncoder().encode(loraConfig).write(to: configURL)
        do {
            _ = try LoRAContainer.from(model: studentContext.model, configuration: loraConfig)
        } catch {
            throw LogitDistillationError.incompatibleBaseModel(job.studentRepoID)
        }

        onProgress(TrainingProgress(
            phase: .training,
            message: "Distilling \(job.teacherRepoID) into \(job.studentRepoID) (rank \(job.rank), \(job.numLayers) layers) for \(job.iterations) iterations"
        ))

        let tokenizer = studentContext.tokenizer
        let teacherModel = teacherContext.model
        let temperature = job.temperature

        func distillationLoss(model: Module, inputs: MLXArray, targets: MLXArray, lengths: MLXArray) -> (
            MLXArray, MLXArray
        ) {
            let studentModel = model as! any LanguageModel
            let studentLogits = studentModel(inputs, cache: nil).asType(.float32)
            let teacherLogits = stopGradient(teacherModel(inputs, cache: nil).asType(.float32))

            let lengthMask = MLXArray(0 ..< inputs.dim(1))[.newAxis, 0...] .< lengths[0..., .newAxis]
            let ntoks = lengthMask.sum()

            let teacherProbs = softmax(teacherLogits / temperature, axis: -1)
            let studentLogProbs = logSoftmax(studentLogits / temperature, axis: -1)
            let perTokenLoss = -(teacherProbs * studentLogProbs).sum(axis: -1) * (temperature * temperature)
            let loss = (perTokenLoss * lengthMask).sum() / ntoks
            return (loss, ntoks)
        }

        let lossValueGrad = valueAndGrad(model: studentContext.model) { model, arrays in
            let (loss, ntoks) = distillationLoss(model: model, inputs: arrays[0], targets: arrays[1], lengths: arrays[2])
            return [loss, ntoks]
        }

        let optimizer = Adam(learningRate: job.learningRate)
        var lastLoss: Float?
        var metrics: [MetricPoint] = []
        let reportEvery = max(1, job.iterations / 20)

        for iteration in 1 ... job.iterations {
            if Task.isCancelled { throw LogitDistillationError.cancelled }

            let indices = (0 ..< job.batchSize).map { _ in Int.random(in: 0 ..< job.trainingTexts.count) }
            let (inputs, targets, lengths) = Self.makeBatch(
                texts: job.trainingTexts, indices: indices, tokenizer: tokenizer)

            let (resultArray, grad) = lossValueGrad(studentContext.model, [inputs, targets, lengths])
            optimizer.update(model: studentContext.model, gradients: grad)
            eval(studentContext.model, optimizer, resultArray[0])

            let lossValue = resultArray[0].item(Float.self)
            lastLoss = lossValue
            if iteration % reportEvery == 0 || iteration == job.iterations {
                onProgress(TrainingProgress(
                    phase: .training,
                    message: "iteration \(iteration)/\(job.iterations): distillation loss \(String(format: "%.4f", lossValue))"
                ))
                metrics.append(MetricPoint(name: "distillationLoss", value: Double(lossValue)))
            }
        }

        if Task.isCancelled { throw LogitDistillationError.cancelled }

        onProgress(TrainingProgress(phase: .savingArtifact, message: "Saving distilled LoRA adapter"))
        try LoRATrain.saveLoRAWeights(model: studentContext.model, url: adapterURL)

        onProgress(TrainingProgress(phase: .done, message: "Done"))
        if let lastLoss { metrics.append(MetricPoint(name: "finalDistillationLoss", value: Double(lastLoss))) }

        return LogitDistillationResult(
            adapterRelativePath: job.outputName,
            finalTrainingLoss: lastLoss,
            metrics: metrics
        )
    }

    /// Real tokenization (via the student's tokenizer, which the teacher
    /// must share) and padding, mirroring `mlx-swift-lm`'s own
    /// `LoRABatchIterator` shape: `inputs` is each sequence shifted left by
    /// one token, `targets` is shifted right by one, `lengths` records each
    /// sequence's real (unpadded) token count for loss masking.
    private static func makeBatch(
        texts: [String], indices: [Int], tokenizer: MLXLMCommon.Tokenizer
    ) -> (MLXArray, MLXArray, MLXArray) {
        let batch = indices.map { tokenizer.encode(text: texts[$0]) }
        let lengths = batch.map { $0.count }
        let maxLength = max(2, lengths.max() ?? 2)

        let batchArray = MLXArray.zeros([batch.count, maxLength], type: Int32.self)
        for (row, tokens) in batch.enumerated() {
            guard !tokens.isEmpty else { continue }
            batchArray[row, 0 ..< tokens.count] = MLXArray(tokens)
        }

        let inputs = batchArray[0..., .stride(to: -1)]
        let targets = batchArray[0..., 1...]
        return (inputs, targets, MLXArray(lengths))
    }
}
