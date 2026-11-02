import Foundation
import Observation
import SwiftData

/// Orchestrates one MLX LoRA fine-tuning run end to end, mirroring
/// `TrainingCoordinator`'s shape but for `MLXFineTuningProvider`, whose job
/// and result types (a base model repo + plain-text examples, an adapter
/// file) don't fit the CSV/column-shaped `TrainingProvider` protocol.
@Observable
@MainActor
public final class MLXFineTuningCoordinator {
    public private(set) var runningExperimentID: String?
    public private(set) var latestPhase: TrainingProgress?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { runningExperimentID != nil }

    public func start(
        experiment: ExperimentRecord,
        job: FineTuningJob,
        provider: MLXFineTuningProvider,
        context: ModelContext
    ) {
        guard runningExperimentID == nil else { return }
        let experimentID = experiment.id
        runningExperimentID = experimentID
        let store = ExperimentStore(context: context)
        let registry = ModelRegistry(context: context)

        currentTask = Task { [weak self] in
            guard let self else { return }
            let logger = ActivityLogger.shared
            do {
                try store.recordStart(experiment)
                logger.log("Starting MLX LoRA fine-tune of \(job.baseModelRepoID)", source: "Training", experimentID: experimentID)

                let result = try await provider.fineTune(job: job) { [weak self] progress in
                    Task { @MainActor in
                        self?.latestPhase = progress
                        logger.log(progress.message, source: "Training", experimentID: experimentID)
                    }
                }

                try Task.checkCancellation()

                let artifact = try registry.register(
                    name: experiment.name,
                    format: .mlxLoraAdapter,
                    origin: .trainedLocally,
                    relativePath: result.adapterRelativePath,
                    task: .mlxFineTuning,
                    experimentID: experiment.id,
                    sourceIdentifier: job.baseModelRepoID
                )
                try store.recordCompletion(experiment, artifactID: artifact.id, metrics: result.metrics)
                let lossSummary = result.finalValidationLoss.map { String(format: "%.4f", $0) } ?? "n/a"
                logger.log(
                    "Fine-tuning complete: validation loss \(lossSummary)",
                    source: "Training",
                    experimentID: experiment.id
                )
            } catch is CancellationError {
                try? store.recordCancellation(experiment)
                logger.log("Fine-tuning cancelled", level: .warning, source: "Training", experimentID: experiment.id)
            } catch {
                try? store.recordFailure(experiment, error: error.localizedDescription)
                logger.log(error.localizedDescription, level: .error, source: "Training", experimentID: experiment.id)
            }
            self.runningExperimentID = nil
            self.latestPhase = nil
        }
    }

    public func cancel() {
        currentTask?.cancel()
    }
}
