import Foundation
import ModelLabCore

/// Prompt 5 item 7 — the comparison half of the ExperimentTracker. The engine
/// already persists runs, hyperparameters, metric history, and produced
/// artifacts (`ExperimentRecord`/`ExperimentStore`); this adds the
/// side-by-side comparison over those records, on the same data the UI will
/// render, so it is testable without a view layer.
public struct ExperimentComparisonEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let task: TaskType
    public let status: ExperimentStatus
    public let elapsedSeconds: TimeInterval?
    public let finalMetrics: [String: Double]
    public let hyperparameters: [String: String]
    public let producedArtifactID: String?

    public init(
        id: String,
        name: String,
        task: TaskType,
        status: ExperimentStatus,
        elapsedSeconds: TimeInterval?,
        finalMetrics: [String: Double],
        hyperparameters: [String: String],
        producedArtifactID: String?
    ) {
        self.id = id
        self.name = name
        self.task = task
        self.status = status
        self.elapsedSeconds = elapsedSeconds
        self.finalMetrics = finalMetrics
        self.hyperparameters = hyperparameters
        self.producedArtifactID = producedArtifactID
    }
}

public struct ExperimentComparison: Sendable, Equatable {
    public let entries: [ExperimentComparisonEntry]

    public init(entries: [ExperimentComparisonEntry]) {
        self.entries = entries
    }

    /// The latest value recorded for each metric name across a run's
    /// history. Metrics like training loss improve over a run, so the last
    /// observation is the run's result.
    public static func finalMetrics(from points: [MetricPoint]) -> [String: Double] {
        var result: [String: Double] = [:]
        for point in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            result[point.name] = point.value
        }
        return result
    }

    public static func entry(from record: ExperimentRecord) -> ExperimentComparisonEntry {
        ExperimentComparisonEntry(
            id: record.id,
            name: record.name,
            task: record.task,
            status: record.status,
            elapsedSeconds: record.elapsedSeconds,
            finalMetrics: finalMetrics(from: record.metricsHistory),
            hyperparameters: record.hyperparameters,
            producedArtifactID: record.producedArtifactID
        )
    }

    public static func compare(_ records: [ExperimentRecord]) -> ExperimentComparison {
        ExperimentComparison(entries: records.map(entry(from:)))
    }

    /// Metric names present in at least one entry, sorted alphabetically so
    /// the table layout is stable across refreshes.
    public var metricNames: [String] {
        Array(Set(entries.flatMap { $0.finalMetrics.keys })).sorted()
    }

    /// Best entry for a metric. Lower-is-better metrics (names containing
    /// "loss" or "perplexity") invert the comparison; everything else is
    /// higher-is-better. Runs that never recorded the metric are excluded;
    /// nil when no entry recorded it.
    public func best(forMetric metric: String) -> ExperimentComparisonEntry? {
        let candidates = entries.filter { $0.finalMetrics[metric] != nil }
        guard !candidates.isEmpty else { return nil }
        let lowerIsBetter = metric.lowercased().contains("loss") || metric.lowercased().contains("perplexity")
        return candidates.min { lhs, rhs in
            let l = lhs.finalMetrics[metric]!
            let r = rhs.finalMetrics[metric]!
            return lowerIsBetter ? l < r : l > r
        }
    }

    /// Improvement of one entry over another for a metric, signed so the UI
    /// can color it: positive means `improved` did better than `baseline`
    /// under the metric's own direction.
    public func delta(improved: ExperimentComparisonEntry, baseline: ExperimentComparisonEntry, metric: String) -> Double? {
        guard let a = improved.finalMetrics[metric], let b = baseline.finalMetrics[metric] else { return nil }
        let lowerIsBetter = metric.lowercased().contains("loss") || metric.lowercased().contains("perplexity")
        return lowerIsBetter ? b - a : a - b
    }
}
