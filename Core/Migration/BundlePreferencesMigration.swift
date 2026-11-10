import Foundation

/// Copies Kiln preferences when a build adopts its registered Apple App ID. The old domain remains intact.
enum BundlePreferencesMigration {
    static let legacyID = "com.kiln.app"
    static let registeredID = "dev.noktirnal.kiln"
    private static let marker = "kiln.migratedLegacyPreferences"

    static func runIfNeeded(defaults: UserDefaults = .standard, currentID: String? = Bundle.main.bundleIdentifier) {
        guard currentID == registeredID else { return }
        migrate(defaults: defaults, from: legacyID, to: registeredID)
    }

    /// Isolated domain arguments allow verification without touching real preferences.
    static func migrate(defaults: UserDefaults, from oldID: String, to newID: String) {
        let destination = defaults.persistentDomain(forName: newID) ?? [:]
        guard destination[marker] as? Bool != true else { return }
        guard let target = UserDefaults(suiteName: newID) else { return }
        for (key, value) in defaults.persistentDomain(forName: oldID) ?? [:] {
            guard !key.hasPrefix("NS"), !key.hasPrefix("Apple"), destination[key] == nil else { continue }
            target.set(value, forKey: key)
        }
        target.set(true, forKey: marker)
    }
}
