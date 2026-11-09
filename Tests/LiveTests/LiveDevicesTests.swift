import Foundation
import Testing
@testable import Kiln

/// Drives the real `xcrun simctl` through `DeviceService`: boots one simulator that was shut down, takes a
/// screenshot, opens a URL, shuts it down again. Opt-in (`TEST_RUNNER_KILN_LIVE=1`) because it needs Xcode and
/// leaves nothing behind only when it passes; it restores the simulator to the state it found it in and writes
/// captures to a temporary folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"), .serialized)
struct LiveDevicesTests {
    @Test func bootScreenshotOpenURLAndShutdownARealSimulator() async throws {
        let captures = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-live-devices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: captures) }
        let service = DeviceService(capturesDirectory: captures)
        let listing = await service.list()
        try #require(listing.setup.simctl.isAvailable, "Xcode command-line tools are required")
        let target = try #require(listing.devices.first { $0.platform == .apple && $0.state == .shutdown && $0.isAvailable && $0.kind == .phone })
        print("LIVE device: \(target.name) \(target.runtime) \(target.id)")

        _ = try await service.boot(id: target.id)
        do {
            let shot = try await service.screenshot(id: target.id)
            #expect(shot.width > 300 && shot.height > 300)
            #expect(FileManager.default.fileExists(atPath: shot.url.path))
            print("LIVE screenshot: \(shot.width)x\(shot.height)")
            _ = try await service.openURL(id: target.id, url: "https://example.com")
            let relisted = await service.list()
            #expect(relisted.devices.first { $0.id == target.id }?.state == .booted)
        } catch {
            _ = try? await service.shutdown(id: target.id)
            throw error
        }
        _ = try await service.shutdown(id: target.id)
        let after = await service.list()
        #expect([DeviceInfo.State.shutdown, .shuttingDown].contains(after.devices.first { $0.id == target.id }?.state ?? .unknown))
    }
}
