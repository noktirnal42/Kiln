import Foundation
import Observation
import SwiftData

/// Orchestrates one logit-level distillation run end to end, mirroring
/// `MLXFineTuningProvider`'s and `DistillationCoordinator`'s shape. Unlike
/// `DistillationCoordinator` (synthetic-data distillation), this registers a
/// single artifact — the resulting LoRA adapter — since no intermediate
/// dataset is produced.
@Observable
@MainActor
public final class LogitDistillationCoordinator {
    public private(set) var runningExperimentID: String?
    public private(set) var latestPhase: TrainingProgress?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { runningExperimentID != nil }

    public func start(
        experiment: ExperimentRecord,
        job: LogitDistillationJob,
        provider: LogitDistillationProvider,
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
                logger.log(
                    "Starting logit distillation of \(job.teacherRepoID) into \(job.studentRepoID)",
                    source: "Training", experimentID: experimentID
                )

                let result = try await provider.distill(job: job) { [weak self] progress in
                    Task { @MainActor in
                        self?.latestPhase = progress
                        logger.log(progress.message, source: "Training", experimentID: experimentID)
                    }
                }

                try Task.checkCancellation()

                let artifact = try registry.register(
                    name: job.outputName,
                    format: .mlxLoraAdapter,
                    origin: .trainedLocally,
                    relativePath: result.adapterRelativePath,
                    task: .logitDistillation,
                    experimentID: experiment.id,
                    sourceIdentifier: job.studentRepoID
                )
                try store.recordCompletion(experiment, artifactID: artifact.id, metrics: result.metrics)
                let lossSummary = result.finalTrainingLoss.map { String(format: "%.4f", $0) } ?? "n/a"
                logger.log(
                    "Logit distillation complete: final distillation loss \(lossSummary)",
                    source: "Training",
                    experimentID: experiment.id
                )
            } catch is CancellationError {
                try? store.recordCancellation(experiment)
                logger.log("Logit distillation cancelled", level: .warning, source: "Training", experimentID: experiment.id)
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
