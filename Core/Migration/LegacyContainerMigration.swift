import Foundation

/// Kiln used to run in the App Sandbox, which kept its data under
/// `~/Library/Containers/com.kiln.app/Data`. The Developer ID build is unsandboxed (an agent that replaces a
/// terminal coding tool needs real git, package managers and any folder), so the same code now reads the real
/// `~/Library/Application Support` and `~/Library/Preferences`. This copies the old data across once, never
/// overwriting anything already there and never deleting the container.
enum LegacyContainerMigration {
    static let bundleID = "com.kiln.app"
    static let supportFolders = ["Kiln", "ModelLab", "ReverseEngineering"]

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    @discardableResult
    static func runIfNeeded(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sandboxed: Bool = isSandboxed
    ) -> [String] {
        guard !sandboxed else { return [] }
        let fm = FileManager.default
        let container = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true)
        guard fm.fileExists(atPath: container.path) else { return [] }
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var copied: [String] = []
        for folder in supportFolders {
            let source = container.appendingPathComponent("Application Support/\(folder)", isDirectory: true)
            let destination = support.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let hasData = !isEmpty(destination)
            // Earlier unsandboxed development runs may have left a small, older copy. Keep it aside (never
            // delete) and prefer the container's data only when that is clearly the more recently used one.
            if hasData, !(age(of: source) > age(of: destination)) { continue }
            do {
                try fm.createDirectory(at: support, withIntermediateDirectories: true)
                if hasData {
                    let aside = support.appendingPathComponent("\(folder).before-container-migration", isDirectory: true)
                    if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
                    try fm.moveItem(at: destination, to: aside)
                }
                try fm.copyItem(at: source, to: destination)
                copied.append(folder)
            } catch {
                NSLog("Kiln migration: could not copy \(folder): \(error.localizedDescription)")
            }
        }
        if let legacy = NSDictionary(contentsOf: container.appendingPathComponent("Preferences/\(bundleID).plist")) {
            for (key, value) in legacy {
                guard let key = key as? String, !key.hasPrefix("NS"), !key.hasPrefix("Apple"),
                      UserDefaults.standard.object(forKey: key) == nil else { continue }
                UserDefaults.standard.set(value, forKey: key)
                copied.append("pref:\(key)")
            }
        }
        return copied
    }

    /// Modification time of the main store file, falling back to the newest top-level entry.
    private static func age(of folder: URL) -> Date {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
        }
        let store = folder.appendingPathComponent("Kiln.store")
        if fm.fileExists(atPath: store.path) { return modified(store) }
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.map(modified).max() ?? .distantPast
    }

    private static func isEmpty(_ url: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return items.isEmpty
    }
}
