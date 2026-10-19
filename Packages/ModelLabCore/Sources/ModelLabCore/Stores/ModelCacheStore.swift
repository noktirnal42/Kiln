import Foundation
import HuggingFace

public struct ModelCacheEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let repoID: String
    public let directory: URL
    public let sizeBytes: Int64
    public let snapshotCount: Int
    public let updatedAt: Date?
}

public struct ModelCacheStore: Sendable {
    public let cacheRoot: URL

    public init(cacheRoot: URL = HubCache.default.cacheDirectory) {
        self.cacheRoot = cacheRoot
    }

    public func listModelCaches() throws -> [ModelCacheEntry] {
        guard FileManager.default.fileExists(atPath: cacheRoot.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { url in
            guard url.lastPathComponent.hasPrefix("models--") else { return nil }
            let repoID = url.lastPathComponent
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")
            let snapshots = url.appendingPathComponent("snapshots")
            let snapshotCount = ((try? FileManager.default.contentsOfDirectory(
                at: snapshots,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).count
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return ModelCacheEntry(
                id: repoID,
                repoID: repoID,
                directory: url,
                sizeBytes: directorySize(url),
                snapshotCount: snapshotCount,
                updatedAt: values?.contentModificationDate
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public func cacheEntry(for repoID: String) -> ModelCacheEntry? {
        try? listModelCaches().first { $0.repoID == repoID }
    }

    public func deleteCache(repoID: String) throws {
        guard let repo = Repo.ID(rawValue: repoID) else { return }
        let directory = HubCache(cacheDirectory: cacheRoot).repoDirectory(repo: repo, kind: .model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
