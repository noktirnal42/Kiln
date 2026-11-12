import Foundation
import Testing
@testable import Kiln

@Suite("Shortcuts and App Intents")
struct KilnIntentsTests {
    @Test func everyActivityCanBeOpenedFromShortcutsAndNothingStaleIsOffered() {
        let activityIDs = Set(ActivityCatalog.descriptors.map(\.id))
        let offered = Set(KilnDestination.allCases.map(\.rawValue))
        #expect(offered == activityIDs, "Shortcuts must offer exactly the registered activities. Missing: \(activityIDs.subtracting(offered)); stale: \(offered.subtracting(activityIDs))")
        #expect(KilnDestination.caseDisplayRepresentations.count == KilnDestination.allCases.count)
    }

    @Test func askKilnIsOneOfTheAppShortcuts() {
        #expect(KilnShortcuts.appShortcuts.count == 3)
    }
}
