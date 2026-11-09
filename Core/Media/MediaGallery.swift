import Foundation

/// One saved thing in the gallery: something the agent or the user generated (an image, a spoken file) or imported.
public struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case generated, speech, imported }

    public let id: UUID
    public let kind: MediaKind
    public let fileName: String
    public let createdAt: Date
    public let title: String
    public let origin: Origin
    /// The prompt or spoken text that made it, when there was one.
    public let prompt: String?
    /// Which provider produced it ("apple-image-playground", "avspeech", …).
    public let provider: String?

    public init(id: UUID = UUID(), kind: MediaKind, fileName: String, createdAt: Date = Date(), title: String,
                origin: Origin, prompt: String? = nil, provider: String? = nil) {
        self.id = id; self.kind = kind; self.fileName = fileName; self.createdAt = createdAt
        self.title = title; self.origin = origin; self.prompt = prompt; self.provider = provider
    }
}

/// Generated media under the app's data folder: `<root>/Items/<id>.<ext>` plus `<root>/index.json`.
/// Synchronous and lock-guarded so the tools (off the main actor) and the views share one store.
public final class MediaGallery: @unchecked Sendable {
    public static let `default` = MediaGallery(root: AgentPaths.supportDirectory.appendingPathComponent("Media", isDirectory: true))

    public let root: URL
    private let lock = NSLock()
    private var cache: [MediaItem]?

    public init(root: URL) { self.root = root }

    private var itemsDirectory: URL { root.appendingPathComponent("Items", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    public func fileURL(for item: MediaItem) -> URL { itemsDirectory.appendingPathComponent(item.fileName) }

    /// Newest first. Entries whose file has gone are left out (and forgotten on the next write).
    public func items() -> [MediaItem] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func item(id: UUID) -> MediaItem? { items().first { $0.id == id } }

    /// Writes `data` into the gallery and records it. The file name is the item id, so nothing can collide or escape the folder.
    @discardableResult
    public func add(data: Data, fileExtension: String, kind: MediaKind, title: String, origin: MediaItem.Origin,
                    prompt: String? = nil, provider: String? = nil) throws -> MediaItem {
        let ext = Self.sanitised(fileExtension)
        let id = UUID()
        let item = MediaItem(id: id, kind: kind, fileName: "\(id.uuidString).\(ext)", title: title, origin: origin, prompt: prompt, provider: provider)
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: item), options: .atomic)
        try appendLocked(item)
        return item
    }

    /// Records a file something else already wrote inside the gallery (the speech synthesiser streams into it).
    @discardableResult
    public func adopt(fileAt url: URL, kind: MediaKind, title: String, origin: MediaItem.Origin,
                      prompt: String? = nil, provider: String? = nil) throws -> MediaItem {
        let ext = Self.sanitised(url.pathExtension)
        let id = UUID()
        let item = MediaItem(id: id, kind: kind, fileName: "\(id.uuidString).\(ext)", title: title, origin: origin, prompt: prompt, provider: provider)
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: fileURL(for: item))
        try appendLocked(item)
        return item
    }

    /// A fresh path inside the gallery's staging area for a producer that writes its own file.
    public func stagingURL(fileExtension: String) throws -> URL {
        let dir = root.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).\(Self.sanitised(fileExtension))")
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        try? FileManager.default.removeItem(at: fileURL(for: all[index]))
        all.remove(at: index)
        try? saveLocked(all)
        return true
    }

    // MARK: Storage

    private func loadLocked() -> [MediaItem] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        let loaded = (try? Data(contentsOf: indexURL)).flatMap { try? decoder.decode([MediaItem].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    private func appendLocked(_ item: MediaItem) throws {
        var all = loadLocked().filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        all.append(item)
        try saveLocked(all)
    }

    private func saveLocked(_ all: [MediaItem]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: indexURL, options: .atomic)
        cache = all
    }

    static func sanitised(_ ext: String) -> String {
        let clean = ext.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(5)
        return clean.isEmpty ? "bin" : String(clean)
    }
}
