import Foundation
import SwiftData

/// Thin, testable CRUD wrapper around SwiftData for experiments. Kept
/// separate from the UI layer: views hold a `ModelContext` from the
/// environment for live `@Query`s, and use this store for actions that
/// don't map cleanly onto a single `context.insert`/`delete` call (cloning,
/// recording a training result).
@MainActor
public struct ExperimentStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func create(_ experiment: ExperimentRecord) throws {
        context.insert(experiment)
        try context.save()
    }

    public func clone(_ source: ExperimentRecord, newName: String) throws -> ExperimentRecord {
        let clone = ExperimentRecord(
            name: newName,
            notes: source.notes,
            task: source.task,
            datasetID: source.datasetID,
            baseModelID: source.baseModelID,
            textColumn: source.textColumn,
            labelColumn: source.labelColumn,
            featureColumns: source.featureColumns,
            hyperparameters: source.hyperparameters,
            parentExperimentID: source.id
        )
        context.insert(clone)
        try context.save()
        return clone
    }

    public func recordStart(_ experiment: ExperimentRecord) throws {
        experiment.status = .running
        experiment.startedAt = Date()
        experiment.completedAt = nil
        experiment.errorMessage = nil
        try context.save()
    }

    public func recordProgress(_ experiment: ExperimentRecord, metric: MetricPoint) throws {
        var history = experiment.metricsHistory
        history.append(metric)
        experiment.metricsHistory = history
        try context.save()
    }

    public func recordCompletion(_ experiment: ExperimentRecord, artifactID: String, metrics: [MetricPoint]) throws {
        experiment.status = .completed
        experiment.completedAt = Date()
        experiment.producedArtifactID = artifactID
        var history = experiment.metricsHistory
        history.append(contentsOf: metrics)
        experiment.metricsHistory = history
        try context.save()
    }

    public func recordFailure(_ experiment: ExperimentRecord, error: String) throws {
        experiment.status = .failed
        experiment.completedAt = Date()
        experiment.errorMessage = error
        try context.save()
    }

    public func recordCancellation(_ experiment: ExperimentRecord) throws {
        experiment.status = .cancelled
        experiment.completedAt = Date()
        try context.save()
    }

    public func delete(_ experiment: ExperimentRecord) throws {
        context.delete(experiment)
        try context.save()
    }
}
