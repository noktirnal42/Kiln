import Foundation
import Testing
@testable import ModelLabCore

struct CapabilityDetectorTests {
    @Test func hardwareReportReflectsActualHost() {
        let report = CapabilityDetector.detectHardware()
        #if arch(arm64)
        #expect(report.status.isAvailable)
        #else
        #expect(!report.status.isAvailable)
        #endif
    }

    @Test func coreMLAndCreateMLAreAlwaysAvailableOnThisSDK() {
        #expect(CapabilityDetector.detectCoreML().status.isAvailable)
        #expect(CapabilityDetector.detectCreateML().status.isAvailable)
    }

    @Test @MainActor func detectAllReturnsOneRowPerCapability() {
        let reports = CapabilityDetector.detectAll()
        #expect(reports.count == 7)
    }

    @Test func networkAndInferenceAreNotClaimedWithoutARun() {
        #expect(CapabilityDetector.detectNetwork().status == .notChecked)
        if CapabilityDetector.detectHardware().status.isAvailable {
            #expect(CapabilityDetector.detectMLX().status == .notChecked)
        }
    }
}
