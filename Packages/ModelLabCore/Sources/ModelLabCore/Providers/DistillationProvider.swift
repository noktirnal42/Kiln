import Foundation

public struct DistillationJob: Sendable {
    public let seedPrompts: [String]
    public let teacherProvider: any InferenceProvider
    public let responseInstructionPrefix: String
    public let studentBaseModelRepoID: String
    public let rank: Int
    public let numLayers: Int
    public let iterations: Int
    public let learningRate: Float
    public let batchSize: Int
    public let datasetOutputName: String
    public let adapterOutputName: String

    public init(
        seedPrompts: [String],
        teacherProvider: any InferenceProvider,
        responseInstructionPrefix: String = "",
        studentBaseModelRepoID: String,
        rank: Int = 8,
        numLayers: Int = 4,
        iterations: Int = 200,
        learningRate: Float = 1e-5,
        batchSize: Int = 1,
        datasetOutputName: String,
        adapterOutputName: String
    ) {
        self.seedPrompts = seedPrompts
        self.teacherProvider = teacherProvider
        self.responseInstructionPrefix = responseInstructionPrefix
        self.studentBaseModelRepoID = studentBaseModelRepoID
        self.rank = rank
        self.numLayers = numLayers
        self.iterations = iterations
        self.learningRate = learningRate
        self.batchSize = batchSize
        self.datasetOutputName = datasetOutputName
        self.adapterOutputName = adapterOutputName
    }
}

public struct DistillationResult: Sendable {
    public let datasetRelativePath: String
    public let exampleCount: Int
    public let fineTuning: FineTuningResult
}

public enum DistillationError: LocalizedError {
    case unavailable(reason: String)
    case noSeedPrompts
    case teacherProducedNoOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .noSeedPrompts: "Add at least one seed prompt for the teacher to respond to."
        case .teacherProducedNoOutput: "The teacher model didn't produce any usable responses for the seed prompts given."
        case .cancelled: "Distillation was cancelled."
        }
    }
}

/// Automated distillation via synthetic data, not logit/soft-target
/// distillation: a teacher `InferenceProvider` (Apple Intelligence or an MLX
/// model) generates a real response for each seed prompt, those
/// (prompt, response) pairs are written out as a real `.jsonl` training
/// dataset, and a real MLX LoRA fine-tune of a smaller student model runs
/// against it automatically — reusing `MLXFineTuningProvider` for the
/// training step rather than reimplementing it. True logit-level
/// distillation (matching the student's output distribution to the
/// teacher's) isn't implemented; it would need access to the teacher's raw
/// logits, which `InferenceProvider` (a streaming-text abstraction over
/// both Apple Intelligence and MLX backends) doesn't expose.
public struct DistillationProvider: Sendable {
    public let name = "Automated Distillation"
    private let fineTuningProvider = MLXFineTuningProvider()

    public init() {}

    public func capability() -> CapabilityStatus {
        CapabilityDetector.detectMLX().status
    }

    public func distill(
        job: DistillationJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) async throws -> DistillationResult {
        guard capability().isAvailable else {
            throw DistillationError.unavailable(reason: capability().reason ?? "MLX unavailable.")
        }
        guard !job.seedPrompts.isEmpty else { throw DistillationError.noSeedPrompts }
        try Task.checkCancellation()

        onProgress(TrainingProgress(
            phase: .preparingData,
            message: "Generating synthetic examples from teacher model for \(job.seedPrompts.count) seed prompts"
        ))

        var examples: [String] = []
        for (index, prompt) in job.seedPrompts.enumerated() {
            try Task.checkCancellation()
            var response = ""
            for try await chunk in job.teacherProvider.streamRespond(prompt: prompt, history: []) {
                response += chunk
            }
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            examples.append("\(job.responseInstructionPrefix)\(prompt)\n\(trimmed)")
            onProgress(TrainingProgress(
                phase: .preparingData,
                message: "Generated \(index + 1)/\(job.seedPrompts.count) synthetic examples"
            ))
        }
        guard !examples.isEmpty else { throw DistillationError.teacherProducedNoOutput }

        try FileManager.default.createDirectory(at: LibraryPaths.datasets, withIntermediateDirectories: true)
        let datasetFileName = "\(job.datasetOutputName).jsonl"
        let datasetURL = LibraryPaths.datasets.appendingPathComponent(datasetFileName)
        let lines = try examples.map { text -> String in
            let data = try JSONEncoder().encode(["text": text])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").write(to: datasetURL, atomically: true, encoding: .utf8)

        onProgress(TrainingProgress(
            phase: .training,
            message: "Fine-tuning \(job.studentBaseModelRepoID) on \(examples.count) distilled examples"
        ))

        let splitIndex = max(1, Int(Double(examples.count) * 0.9))
        let trainTexts = Array(examples.prefix(splitIndex))
        let validationTexts = examples.count > splitIndex ? Array(examples.suffix(from: splitIndex)) : trainTexts

        let fineTuneJob = FineTuningJob(
            baseModelRepoID: job.studentBaseModelRepoID,
            trainingTexts: trainTexts,
            validationTexts: validationTexts,
            rank: job.rank,
            numLayers: job.numLayers,
            iterations: job.iterations,
            learningRate: job.learningRate,
            batchSize: job.batchSize,
            outputName: job.adapterOutputName
        )
        let fineTuningResult = try await fineTuningProvider.fineTune(job: fineTuneJob, onProgress: onProgress)

        if Task.isCancelled { throw DistillationError.cancelled }

        return DistillationResult(
            datasetRelativePath: datasetFileName,
            exampleCount: examples.count,
            fineTuning: fineTuningResult
        )
    }
}
