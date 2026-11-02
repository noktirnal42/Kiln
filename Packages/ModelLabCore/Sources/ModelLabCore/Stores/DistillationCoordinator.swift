import Foundation
import Observation
import SwiftData

/// Orchestrates one automated-distillation run end to end: teacher-generated
/// synthetic dataset, then a LoRA fine-tune of the student against it.
/// Mirrors `MLXFineTuningCoordinator`'s shape, but registers two artifacts
/// on success — the synthetic dataset `DistillationProvider` wrote, and the
/// resulting adapter — instead of one.
@Observable
@MainActor
public final class DistillationCoordinator {
    public private(set) var runningExperimentID: String?
    public private(set) var latestPhase: TrainingProgress?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { runningExperimentID != nil }

    public func start(
        experiment: ExperimentRecord,
        job: DistillationJob,
        provider: DistillationProvider,
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
                logger.log("Starting automated distillation into \(job.studentBaseModelRepoID)", source: "Training", experimentID: experimentID)

                let result = try await provider.distill(job: job) { [weak self] progress in
                    Task { @MainActor in
                        self?.latestPhase = progress
                        logger.log(progress.message, source: "Training", experimentID: experimentID)
                    }
                }

                try Task.checkCancellation()

                let datasetRecord = DatasetRecord(
                    id: UUID().uuidString,
                    name: "\(experiment.name) — Distillation Dataset",
                    sourceKind: .localImport,
                    format: .jsonl,
                    downloadStatus: .completed,
                    rowCount: result.exampleCount
                )
                datasetRecord.localRelativePath = result.datasetRelativePath
                context.insert(datasetRecord)
                try context.save()

                let artifact = try registry.register(
                    name: "\(experiment.name) — Student Adapter",
                    format: .mlxLoraAdapter,
                    origin: .trainedLocally,
                    relativePath: result.fineTuning.adapterRelativePath,
                    task: .distillation,
                    experimentID: experiment.id,
                    sourceIdentifier: job.studentBaseModelRepoID
                )
                try store.recordCompletion(experiment, artifactID: artifact.id, metrics: result.fineTuning.metrics)
                let lossSummary = result.fineTuning.finalValidationLoss.map { String(format: "%.4f", $0) } ?? "n/a"
                logger.log(
                    "Distillation complete: \(result.exampleCount) synthetic examples, adapter validation loss \(lossSummary)",
                    source: "Training",
                    experimentID: experiment.id
                )
            } catch is CancellationError {
                try? store.recordCancellation(experiment)
                logger.log("Distillation cancelled", level: .warning, source: "Training", experimentID: experiment.id)
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
