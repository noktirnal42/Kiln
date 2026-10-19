import Foundation
import SwiftData

/// A single metric observation recorded during a run. Stored as JSON inside
/// `ExperimentRecord.metricsHistoryJSON` since SwiftData does not model
/// nested value-type arrays as first-class relationships without their own
/// `@Model` type, and a run can emit metrics at a much higher frequency than
/// we want individual persisted rows for.
public struct MetricPoint: Codable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var name: String
    public var value: Double

    public init(timestamp: Date = Date(), name: String, value: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.name = name
        self.value = value
    }
}

@Model
public final class ExperimentRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var notes: String
    public var taskRaw: String
    public var statusRaw: String
    public var datasetID: String
    public var baseModelID: String?
    public var textColumn: String?
    public var labelColumn: String?
    public var featureColumns: [String]
    public var hyperparametersJSON: String
    public var metricsHistoryJSON: String
    public var producedArtifactID: String?
    public var parentExperimentID: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?

    public var task: TaskType {
        get { TaskType(rawValue: taskRaw) ?? .textClassification }
        set { taskRaw = newValue.rawValue }
    }

    public var status: ExperimentStatus {
        get { ExperimentStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    public var hyperparameters: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(hyperparametersJSON.utf8))) ?? [:] }
        set { hyperparametersJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }

    public var metricsHistory: [MetricPoint] {
        get { (try? JSONDecoder().decode([MetricPoint].self, from: Data(metricsHistoryJSON.utf8))) ?? [] }
        set { metricsHistoryJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    public var elapsedSeconds: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        notes: String = "",
        task: TaskType,
        datasetID: String,
        baseModelID: String? = nil,
        textColumn: String? = nil,
        labelColumn: String? = nil,
        featureColumns: [String] = [],
        hyperparameters: [String: String] = [:],
        parentExperimentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.taskRaw = task.rawValue
        self.statusRaw = ExperimentStatus.draft.rawValue
        self.datasetID = datasetID
        self.baseModelID = baseModelID
        self.textColumn = textColumn
        self.labelColumn = labelColumn
        self.featureColumns = featureColumns
        self.hyperparametersJSON = (try? String(data: JSONEncoder().encode(hyperparameters), encoding: .utf8)) ?? "{}"
        self.metricsHistoryJSON = "[]"
        self.producedArtifactID = nil
        self.parentExperimentID = parentExperimentID
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.errorMessage = nil
    }
}
