import Foundation
import SwiftData

@Model
public final class ModelArtifactRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var formatRaw: String
    public var originRaw: String
    public var localRelativePath: String
    public var sizeBytes: Int64?
    public var sourceIdentifier: String?
    public var taskRaw: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var experimentID: String?
    public var notes: String

    public var format: ModelFormat {
        get { ModelFormat(rawValue: formatRaw) ?? .unknown }
        set { formatRaw = newValue.rawValue }
    }

    public var origin: ModelOrigin {
        get { ModelOrigin(rawValue: originRaw) ?? .importedLocal }
        set { originRaw = newValue.rawValue }
    }

    public var task: TaskType? {
        get { taskRaw.flatMap(TaskType.init(rawValue:)) }
        set { taskRaw = newValue?.rawValue }
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        format: ModelFormat,
        origin: ModelOrigin,
        localRelativePath: String,
        sizeBytes: Int64? = nil,
        sourceIdentifier: String? = nil,
        task: TaskType? = nil,
        experimentID: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.formatRaw = format.rawValue
        self.originRaw = origin.rawValue
        self.localRelativePath = localRelativePath
        self.sizeBytes = sizeBytes
        self.sourceIdentifier = sourceIdentifier
        self.taskRaw = task?.rawValue
        self.createdAt = Date()
        self.lastUsedAt = nil
        self.experimentID = experimentID
        self.notes = notes
    }
}
