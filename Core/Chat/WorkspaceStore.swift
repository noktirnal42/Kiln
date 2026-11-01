import Foundation

/// The projects (folders) the agent has been pointed at, and which one is current.
///
/// Kiln is sandboxed: a folder chosen in an open panel is readable only for that run unless a security-scoped
/// bookmark of it is kept. Remembering just the path, as before, meant the agent silently lost access to the
/// project after every relaunch. Each recent project keeps a bookmark, and access is started when it is opened.
public final class WorkspaceStore: @unchecked Sendable {
    public static let shared = WorkspaceStore()

    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var path: String
        public var bookmark: Data
        public var lastUsed: Date
        public var id: String { path }
        public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    static let entriesKey = "workspace.recents"
    static let currentKey = "workspace.currentPath"
    public static let maxRecents = 8

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var accessed: [String: URL] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: Self.entriesKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.entriesKey) }
    }

    /// Most recently used first.
    public func recents() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load().sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Remembers `url` (which must come from an open panel or an already-opened bookmark), makes it current, and
    /// keeps access to it open.
    @discardableResult
    public func remember(_ url: URL, now: Date = Date()) throws -> URL {
        let bookmark = try url.bookmarkData(options: .withSecurityScope)
        lock.lock(); defer { lock.unlock() }
        var entries = load().filter { $0.path != url.path }
        entries.append(Entry(path: url.path, bookmark: bookmark, lastUsed: now))
        entries = Array(entries.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.maxRecents))
        save(entries)
        defaults.set(url.path, forKey: Self.currentKey)
        if accessed[url.path] == nil, url.startAccessingSecurityScopedResource() { accessed[url.path] = url }
        return url
    }

    /// Resolves a remembered project's bookmark and starts access. nil if it is gone (a drive not attached).
    @discardableResult
    public func open(path: String, now: Date = Date()) -> URL? {
        lock.lock(); defer { lock.unlock() }
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return nil }
        if let url = accessed[path] {
            entries[index].lastUsed = now; save(entries); defaults.set(path, forKey: Self.currentKey)
            return url
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entries[index].bookmark, options: [.withSecurityScope, .withoutUI],
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        accessed[path] = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { entries[index].bookmark = fresh }
        entries[index].lastUsed = now
        save(entries)
        defaults.set(path, forKey: Self.currentKey)
        return url
    }

    /// The project that was open last time, with access restored.
    public var current: URL? {
        guard let path = defaults.string(forKey: Self.currentKey) else { return nil }
        return open(path: path)
    }

    /// Works without a project: file tools are then unavailable to the agent.
    public func clearCurrent() { defaults.removeObject(forKey: Self.currentKey) }

    public func forget(path: String) {
        lock.lock(); defer { lock.unlock() }
        accessed.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        save(load().filter { $0.path != path })
        if defaults.string(forKey: Self.currentKey) == path { defaults.removeObject(forKey: Self.currentKey) }
    }
}

/// A conversation's title, taken from its first message so the history reads as something other than a column of
/// "New Conversation".
public enum ConversationTitle {
    public static let placeholder = "New Conversation"

    public static func make(from message: String, limit: Int = 48) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let cleaned = words.trimmingCharacters(in: CharacterSet(charactersIn: "#*>`-_ "))
        guard !cleaned.isEmpty else { return placeholder }
        guard cleaned.count > limit else { return cleaned }
        let cut = cleaned.prefix(limit)
        // Break at the last space so a word is not sliced in half, unless that would throw most of it away.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}
