import Foundation

/// Owns the app-controlled local library: copying/moving files into the
/// right subdirectory, and computing stable relative paths that survive an
/// app-container path changing between launches (SwiftData records store
/// the relative path, never the absolute one).
public struct ArtifactStore: Sendable {
    public enum Category: String, Sendable {
        case datasets = "Datasets"
        case models = "Models"
        case experiments = "Experiments"
    }

    public init() {}

    public func absoluteURL(for relativePath: String, in category: Category) -> URL {
        LibraryPaths.root.appendingPathComponent(category.rawValue).appendingPathComponent(relativePath)
    }

    /// Copies a user-selected file or folder into the library, returning the
    /// path stored on the record (relative to `category`'s directory).
    @discardableResult
    public func importItem(at sourceURL: URL, into category: Category, suggestedName: String? = nil) throws -> String {
        let categoryRoot = LibraryPaths.root.appendingPathComponent(category.rawValue)
        try FileManager.default.createDirectory(at: categoryRoot, withIntermediateDirectories: true)

        let baseName = suggestedName ?? sourceURL.lastPathComponent
        var candidate = baseName
        var attempt = 1
        while FileManager.default.fileExists(atPath: categoryRoot.appendingPathComponent(candidate).path) {
            attempt += 1
            let ext = (baseName as NSString).pathExtension
            let stem = (baseName as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem)-\(attempt)" : "\(stem)-\(attempt).\(ext)"
        }

        let destination = categoryRoot.appendingPathComponent(candidate)
        let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { sourceURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return candidate
    }

    public func sizeOnDisk(relativePath: String, in category: Category) -> Int64? {
        let url = absoluteURL(for: relativePath, in: category)
        return Self.directorySize(url)
    }

    public func delete(relativePath: String, in category: Category) throws {
        let url = absoluteURL(for: relativePath, in: category)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func directorySize(_ url: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
