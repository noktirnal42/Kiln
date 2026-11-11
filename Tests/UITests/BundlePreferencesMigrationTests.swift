import Foundation
import Testing
@testable import Kiln

struct BundlePreferencesMigrationTests {
    @Test func migrationPreservesExistingPreferencesAndRunsOnlyOnce() throws {
        let suffix = UUID().uuidString
        let oldID = "kiln.migration.old.\(suffix)"
        let newID = "kiln.migration.new.\(suffix)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: oldID)
            defaults.removePersistentDomain(forName: newID)
        }
        defaults.setPersistentDomain(["workspace": "old", "theme": "dark", "NSWindow Frame": "ignored"], forName: oldID)
        defaults.setPersistentDomain(["workspace": "new"], forName: newID)
        BundlePreferencesMigration.migrate(defaults: defaults, from: oldID, to: newID)
        let migrated = try #require(defaults.persistentDomain(forName: newID))
        #expect(migrated["workspace"] as? String == "new")
        #expect(migrated["theme"] as? String == "dark")
        #expect(migrated["NSWindow Frame"] == nil)
        #expect(defaults.persistentDomain(forName: oldID)?["workspace"] as? String == "old")
        TestDefaults.suite(oldID)?.set("light", forKey: "theme")
        BundlePreferencesMigration.migrate(defaults: defaults, from: oldID, to: newID)
        #expect(defaults.persistentDomain(forName: newID)?["theme"] as? String == "dark")
    }
}
