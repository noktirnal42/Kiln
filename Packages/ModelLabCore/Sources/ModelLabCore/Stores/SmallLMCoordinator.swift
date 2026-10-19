import Foundation
import Observation
import SwiftData

/// Orchestrates one from-scratch small-LM training run end to end, mirroring
/// `MLXFineTuningCoordinator`'s shape but for `SmallLMPretrainingProvider`,
/// whose job produces a brand new model rather than an adapter on top of an
/// existing one.
@Observable
@MainActor
public final class SmallLMCoordinator {
    public private(set) var runningExperimentID: String?
    public private(set) var latestPhase: TrainingProgress?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { runningExperimentID != nil }

    public func start(
        experiment: ExperimentRecord,
        job: SmallLMPretrainingJob,
        provider: SmallLMPretrainingProvider,
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
                logger.log("Starting from-scratch small LM training (\(job.numLayers) layers, \(job.dimensions) dims)", source: "Training", experimentID: experimentID)

                let result = try await provider.pretrain(job: job) { [weak self] progress in
                    Task { @MainActor in
                        self?.latestPhase = progress
                        logger.log(progress.message, source: "Training", experimentID: experimentID)
                    }
                }

                try Task.checkCancellation()

                let artifact = try registry.register(
                    name: job.outputName,
                    format: .mlxScratchModel,
                    origin: .trainedLocally,
                    relativePath: result.relativePath,
                    task: .smallLMPretraining,
                    experimentID: experiment.id
                )
                try store.recordCompletion(experiment, artifactID: artifact.id, metrics: result.metrics)
                let lossSummary = result.finalLoss.map { String(format: "%.4f", $0) } ?? "n/a"
                logger.log(
                    "From-scratch training complete: final loss \(lossSummary), vocab size \(result.vocabSize)",
                    source: "Training",
                    experimentID: experiment.id
                )
            } catch is CancellationError {
                try? store.recordCancellation(experiment)
                logger.log("Training cancelled", level: .warning, source: "Training", experimentID: experiment.id)
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
