import Foundation

/// Preference suites for tests. Every suite made here is removed when the test process exits, so a run never leaves
/// `kiln.tests.*` plists behind in ~/Library/Preferences (hundreds piled up before this existed).
enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: Set<String> = []
    nonisolated(unsafe) private static var registered = false

    /// Same as `UserDefaults(suiteName:)`, with removal at process exit.
    static func suite(_ name: String) -> UserDefaults? {
        lock.lock(); defer { lock.unlock() }
        names.insert(name)
        if !registered {
            registered = true
            atexit {
                let all = TestDefaults.snapshot()
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
                for name in all {
                    UserDefaults().removePersistentDomain(forName: name)
                    // The preferences daemon may not have written (or may re-write) the file before the process ends.
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).plist"))
                }
            }
        }
        return UserDefaults(suiteName: name)
    }

    fileprivate static func snapshot() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return names
    }
}
