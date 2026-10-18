import Foundation
import SwiftData

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case code, markdown, html, mermaid, data
}

public struct ArtifactSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: ArtifactKind
    public var language: String?
    public var version: Int
    public var byteCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, title: String, kind: ArtifactKind, language: String?, version: Int, byteCount: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.kind = kind
        self.language = language
        self.version = version
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ArtifactVersionSnapshot: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var version: Int
    public var byteCount: Int
    public var createdAt: Date

    public init(id: UUID, version: Int, byteCount: Int, createdAt: Date) {
        self.id = id
        self.version = version
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public enum ArtifactError: Error, Equatable, Sendable {
    case tooLarge(limit: Int)
    case notFound(String)
    case unknownKind(String)
}

/// Artifact persistence with version history over the shared SwiftData
/// container. Actor-isolated; every content write is bounded.
public actor ArtifactStore {
    public static let maxContentBytes = 4 * 1024 * 1024
    public static let maxVersions = 50

    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        context.autosaveEnabled = false
    }

    @discardableResult
    public func create(title: String, kind: ArtifactKind, content: Data, language: String? = nil) throws -> ArtifactSummary {
        guard content.count <= Self.maxContentBytes else {
            throw ArtifactError.tooLarge(limit: Self.maxContentBytes)
        }
        let artifact = Artifact(title: title, kind: kind.rawValue, content: content, language: language)
        context.insert(artifact)
        let initial = ArtifactVersion(version: 1, content: content)
        initial.artifact = artifact
        context.insert(initial)
        try context.save()
        return Self.summary(of: artifact)
    }

    public func artifacts(limit: Int = 500) throws -> [ArtifactSummary] {
        var descriptor = FetchDescriptor<Artifact>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(Self.summary(of:))
    }

    @discardableResult
    public func update(_ id: UUID, content: Data) throws -> ArtifactSummary {
        guard content.count <= Self.maxContentBytes else {
            throw ArtifactError.tooLarge(limit: Self.maxContentBytes)
        }
        guard let artifact = try Self.fetch(id, in: context) else {
            throw ArtifactError.notFound("artifact \(id)")
        }
        let nextVersion = artifact.version + 1
        artifact.content = content
        artifact.version = nextVersion
        artifact.updatedAt = Date()
        let version = ArtifactVersion(version: nextVersion, content: content)
        version.artifact = artifact
        context.insert(version)
        pruneVersions(artifact)
        try context.save()
        return Self.summary(of: artifact)
    }

    public func versions(of id: UUID) throws -> [ArtifactVersionSnapshot] {
        guard let artifact = try Self.fetch(id, in: context) else { return [] }
        return artifact.versions
            .sorted { $0.version > $1.version }
            .map { ArtifactVersionSnapshot(id: $0.id, version: $0.version, byteCount: $0.content.count, createdAt: $0.createdAt) }
    }

    public func content(of id: UUID, version: Int? = nil) throws -> Data {
        guard let artifact = try Self.fetch(id, in: context) else {
            throw ArtifactError.notFound("artifact \(id)")
        }
        guard let version else { return artifact.content }
        guard let match = artifact.versions.first(where: { $0.version == version }) else {
            throw ArtifactError.notFound("artifact \(id) version \(version)")
        }
        return match.content
    }

    public func delete(_ id: UUID) throws {
        guard let artifact = try Self.fetch(id, in: context) else { return }
        context.delete(artifact)
        try context.save()
    }

    private func pruneVersions(_ artifact: Artifact) {
        let sorted = artifact.versions.sorted { $0.version > $1.version }
        guard sorted.count > Self.maxVersions else { return }
        for stale in sorted[Self.maxVersions...] {
            context.delete(stale)
        }
    }

    private static func fetch(_ id: UUID, in context: ModelContext) throws -> Artifact? {
        var descriptor = FetchDescriptor<Artifact>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func summary(of artifact: Artifact) -> ArtifactSummary {
        let kind = ArtifactKind(rawValue: artifact.kind) ?? .code
        return ArtifactSummary(
            id: artifact.id,
            title: artifact.title,
            kind: kind,
            language: artifact.language,
            version: artifact.version,
            byteCount: artifact.content.count,
            createdAt: artifact.createdAt,
            updatedAt: artifact.updatedAt
        )
    }
}
