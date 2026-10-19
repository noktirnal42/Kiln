import Foundation
import Observation
import SwiftData

/// Orchestrates one training run end to end: starts the provider, mirrors
/// progress into the Activity log and the experiment's metric history,
/// registers the resulting artifact, and supports cancellation via
/// structured concurrency (`Task.cancel()` — cooperative, per the honest
/// limitation documented in `CreateMLTrainingProvider`).
@Observable
@MainActor
public final class TrainingCoordinator {
    public private(set) var runningExperimentID: String?
    public private(set) var latestPhase: TrainingProgress?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { runningExperimentID != nil }

    public func start(
        experiment: ExperimentRecord,
        job: TrainingJob,
        provider: some TrainingProvider,
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
                logger.log("Starting \(job.task.displayName) training", source: "Training", experimentID: experimentID)

                let result = try await provider.train(job: job) { [weak self] progress in
                    Task { @MainActor in
                        self?.latestPhase = progress
                        logger.log(progress.message, source: "Training", experimentID: experimentID)
                    }
                }

                try Task.checkCancellation()

                let artifact = try registry.register(
                    name: job.outputName,
                    format: .mlmodel,
                    origin: .trainedLocally,
                    relativePath: result.modelFileRelativePath,
                    task: job.task,
                    experimentID: experiment.id
                )
                try store.recordCompletion(experiment, artifactID: artifact.id, metrics: result.metrics)
                logger.log(
                    "Training complete: \(String(format: "%.1f%%", result.validationAccuracy * 100)) validation accuracy",
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
