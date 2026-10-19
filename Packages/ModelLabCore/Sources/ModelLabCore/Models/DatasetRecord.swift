import Foundation
import SwiftData

@Model
public final class DatasetRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var datasetDescription: String?
    public var sourceKindRaw: String
    public var sourceURL: String?
    public var license: String?
    public var tags: [String]
    public var sizeBytes: Int64?
    public var localRelativePath: String?
    public var formatRaw: String
    public var downloadStatusRaw: String
    public var createdAt: Date
    public var updatedAt: Date
    public var columns: [String]
    public var rowCount: Int?
    public var trainSplitFraction: Double

    public var sourceKind: DatasetSourceKind {
        get { DatasetSourceKind(rawValue: sourceKindRaw) ?? .localImport }
        set { sourceKindRaw = newValue.rawValue }
    }

    public var format: DatasetFileFormat {
        get { DatasetFileFormat(rawValue: formatRaw) ?? .unknown }
        set { formatRaw = newValue.rawValue }
    }

    public var downloadStatus: DownloadStatus {
        get { DownloadStatus(rawValue: downloadStatusRaw) ?? .notStarted }
        set { downloadStatusRaw = newValue.rawValue }
    }

    public init(
        id: String,
        name: String,
        datasetDescription: String? = nil,
        sourceKind: DatasetSourceKind,
        sourceURL: String? = nil,
        license: String? = nil,
        tags: [String] = [],
        sizeBytes: Int64? = nil,
        localRelativePath: String? = nil,
        format: DatasetFileFormat = .unknown,
        downloadStatus: DownloadStatus = .notStarted,
        columns: [String] = [],
        rowCount: Int? = nil,
        trainSplitFraction: Double = 0.8
    ) {
        self.id = id
        self.name = name
        self.datasetDescription = datasetDescription
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceURL = sourceURL
        self.license = license
        self.tags = tags
        self.sizeBytes = sizeBytes
        self.localRelativePath = localRelativePath
        self.formatRaw = format.rawValue
        self.downloadStatusRaw = downloadStatus.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.columns = columns
        self.rowCount = rowCount
        self.trainSplitFraction = trainSplitFraction
    }
}
