import Foundation

/// Where the shared model store is, when the user has pointed Kiln at it.
///
/// Kiln runs in the App Sandbox, so `~/.cache/huggingface` and any external drive are invisible to it until
/// the user picks the folder (an open panel). A security-scoped bookmark of that choice is kept, and access
/// is held open for the life of the process so listing and loading can both read it.
public final class ModelStoreLocation: @unchecked Sendable {
    public static let shared = ModelStoreLocation()

    static let bookmarkKey = "modelStore.bookmark"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var accessed: URL?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The folder the user chose, with access started; nil if none was chosen or the drive is not attached.
    public var folder: URL? {
        lock.lock(); defer { lock.unlock() }
        if let accessed { return accessed }
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        accessed = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    public var hasChoice: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    /// Remembers `url` as the store. Call with a URL that came from an open panel (or equivalent).
    public func choose(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope)
        lock.lock()
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        defaults.set(data, forKey: Self.bookmarkKey)
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        lock.unlock()
    }

    /// The directory that actually holds `models--org--repo` folders: the chosen folder itself, or its `hub`
    /// subfolder when the user picked the Hugging Face home (`…/huggingface`) instead of `…/huggingface/hub`.
    public static func hubDirectory(in folder: URL) -> URL {
        let fm = FileManager.default
        func holdsModels(_ url: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasPrefix("models--") }
        }
        if holdsModels(folder) { return folder }
        let hub = folder.appendingPathComponent("hub", isDirectory: true)
        if holdsModels(hub) { return hub }
        return folder
    }
}
