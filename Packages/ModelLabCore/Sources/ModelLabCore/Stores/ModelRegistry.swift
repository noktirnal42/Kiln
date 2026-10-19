import Foundation
import SwiftData

/// Discovers what's actually on disk in the model library and reconciles it
/// with SwiftData records, so an artifact copied in by hand (e.g. dragging
/// a `.mlpackage` into the Models folder in Finder) still shows up.
@MainActor
public struct ModelRegistry {
    private let context: ModelContext
    private let artifactStore = ArtifactStore()

    public init(context: ModelContext) {
        self.context = context
    }

    public func register(
        name: String,
        format: ModelFormat,
        origin: ModelOrigin,
        relativePath: String,
        task: TaskType? = nil,
        experimentID: String? = nil,
        sourceIdentifier: String? = nil,
        notes: String = ""
    ) throws -> ModelArtifactRecord {
        let size = artifactStore.sizeOnDisk(relativePath: relativePath, in: .models)
        let record = ModelArtifactRecord(
            name: name,
            format: format,
            origin: origin,
            localRelativePath: relativePath,
            sizeBytes: size,
            sourceIdentifier: sourceIdentifier,
            task: task,
            experimentID: experimentID,
            notes: notes
        )
        context.insert(record)
        try context.save()
        return record
    }

    public func registerHuggingFaceMLXRepository(
        id: String,
        task: TaskType? = .textGeneration,
        notes: String = ""
    ) throws -> ModelArtifactRecord {
        if let existing = try findBySourceIdentifier(id) {
            existing.lastUsedAt = Date()
            try context.save()
            return existing
        }
        let record = ModelArtifactRecord(
            name: id,
            format: .mlxHubRepository,
            origin: .downloadedMLX,
            localRelativePath: id,
            sizeBytes: nil,
            sourceIdentifier: id,
            task: task,
            notes: notes
        )
        context.insert(record)
        try context.save()
        return record
    }

    public func importLocalModel(at sourceURL: URL) throws -> ModelArtifactRecord {
        let format = Self.detectFormat(sourceURL)
        guard format != .unknown else { throw ModelRegistryError.unsupportedFormat(sourceURL.pathExtension) }
        let relativePath = try artifactStore.importItem(at: sourceURL, into: .models)
        return try register(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            format: format,
            origin: .importedLocal,
            relativePath: relativePath
        )
    }

    public func markUsed(_ record: ModelArtifactRecord) throws {
        record.lastUsedAt = Date()
        try context.save()
    }

    public func delete(_ record: ModelArtifactRecord) throws {
        if record.format != .mlxHubRepository {
            try? artifactStore.delete(relativePath: record.localRelativePath, in: .models)
        }
        context.delete(record)
        try context.save()
    }

    public func findBySourceIdentifier(_ sourceIdentifier: String) throws -> ModelArtifactRecord? {
        let descriptor = FetchDescriptor<ModelArtifactRecord>(
            predicate: #Predicate { record in
                record.sourceIdentifier == sourceIdentifier
            }
        )
        return try context.fetch(descriptor).first
    }

    /// Imports artifacts that were placed directly in the library folder by
    /// another tool or Finder. Existing records are matched by relative path.
    public func reconcile() throws {
        let descriptor = FetchDescriptor<ModelArtifactRecord>()
        let knownPaths = Set(try context.fetch(descriptor).map(\.localRelativePath))
        let items = try FileManager.default.contentsOfDirectory(
            at: LibraryPaths.models,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in items {
            let format = Self.detectFormat(item)
            guard format != .unknown, !knownPaths.contains(item.lastPathComponent) else { continue }
            let record = ModelArtifactRecord(
                name: item.deletingPathExtension().lastPathComponent,
                format: format,
                origin: .importedLocal,
                localRelativePath: item.lastPathComponent,
                sizeBytes: artifactStore.sizeOnDisk(relativePath: item.lastPathComponent, in: .models)
            )
            context.insert(record)
        }
        try context.save()
    }

    public static func detectFormat(_ url: URL) -> ModelFormat {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        switch url.pathExtension.lowercased() {
        case "mlmodel": return .mlmodel
        case "mlpackage": return .mlpackage
        default:
            if isDirectory.boolValue {
                let fm = FileManager.default
                let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
                let hasWeights = fm.enumerator(at: url, includingPropertiesForKeys: nil)?
                    .compactMap { ($0 as? URL)?.pathExtension.lowercased() }
                    .contains("safetensors") ?? false
                if hasConfig && hasWeights { return .mlxFolder }
            }
            return .unknown
        }
    }
}

public enum ModelRegistryError: LocalizedError {
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let extensionName):
            let suffix = extensionName.isEmpty ? "that item" : ".\(extensionName)"
            return "Model Lab cannot import \(suffix) as a supported model artifact."
        }
    }
}
