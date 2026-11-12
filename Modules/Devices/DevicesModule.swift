import Foundation
import SwiftUI
import Observation
import AppKit

/// The Devices module: simulators and emulators in one list with a live-ish screen. The agent tools in
/// `Core/Devices` use the same `DeviceService`, so the view and the agent never disagree about a device.
@MainActor
@Observable
public final class DevicesModule: @preconcurrency Module, ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.devices"
    public nonisolated static let displayName = "Devices"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [.processSpawn, .simulatorControl, .fileSystemRead, .fileSystemWrite]

    @ObservationIgnored public let service = DeviceService()
    public private(set) var devices: [DeviceInfo] = []
    public private(set) var setup: DeviceSetup?
    public private(set) var warnings: [String] = []
    public private(set) var isRefreshing = false
    public var selectedID: String?
    /// Short status line for the last thing the user did ("iPhone 17 Pro is booted.", or an error).
    public private(set) var message: String?
    public private(set) var busyIDs: Set<String> = []

    // Live view
    public private(set) var frame: NSImage?
    public private(set) var frameSize: CGSize = .zero
    public private(set) var frameError: String?
    public var liveRefresh = true
    public var refreshInterval: Double = 0.8

    private var context: ModuleContext?
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    public nonisolated init() {}

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        context.logger.info("Devices module initialized")
    }

    public func activate() async throws {
        await refresh()
    }

    public func deactivate() async throws { stopLive() }
    public func shutdown() async throws { stopLive(); context = nil }

    public func makeRootView() -> AnyView { AnyView(DevicesRootView(module: self)) }

    public var selected: DeviceInfo? { devices.first { $0.id == selectedID } }

    // MARK: Listing

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let listing = await service.list()
        devices = listing.devices
        setup = listing.setup
        warnings = listing.warnings
        isRefreshing = false
        if selected == nil {
            selectedID = devices.first(where: { $0.state == .booted })?.id
        }
    }

    // MARK: Actions (user-initiated from the view; the agent's go through approval instead)

    public func boot(_ device: DeviceInfo) async {
        await run(device, "Booting \(device.name)…") { try await self.service.boot(id: device.id) }
        selectedID = devices.first(where: { $0.name == device.name && $0.state == .booted })?.id ?? device.id
    }

    public func shutdown(_ device: DeviceInfo) async {
        if selectedID == device.id { frame = nil }
        await run(device, "Shutting down \(device.name)…") { try await self.service.shutdown(id: device.id) }
    }

    public func install(_ device: DeviceInfo, path: String) async {
        await run(device, "Installing…") { try await self.service.install(id: device.id, path: path) }
    }

    public func launch(_ device: DeviceInfo, app: String) async {
        await run(device, "Launching \(app)…") { try await self.service.launch(id: device.id, app: app) }
    }

    public func openURL(_ device: DeviceInfo, url: String) async {
        await run(device, "Opening URL…") { try await self.service.openURL(id: device.id, url: url) }
    }

    public func send(_ device: DeviceInfo, input: DeviceService.Input) async {
        do { _ = try await service.send(id: device.id, input: input) } catch { message = error.localizedDescription }
        await captureFrame()
    }

    public func saveScreenshot(_ device: DeviceInfo) async -> URL? {
        do {
            let shot = try await service.screenshot(id: device.id)
            message = "Saved \(shot.width)×\(shot.height) screenshot."
            return shot.url
        } catch { message = error.localizedDescription; return nil }
    }

    public func record(_ device: DeviceInfo, seconds: Int) async -> URL? {
        await runValue(device, "Recording \(seconds)s…") { try await self.service.recordVideo(id: device.id, seconds: seconds) }
    }

    public func logs(_ device: DeviceInfo) async -> String {
        do { return try await service.logs(id: device.id, lines: 300, contains: nil) } catch { return error.localizedDescription }
    }

    private func run(_ device: DeviceInfo, _ working: String, _ work: @escaping () async throws -> String) async {
        busyIDs.insert(device.id)
        message = working
        do { message = try await work() } catch { message = error.localizedDescription }
        busyIDs.remove(device.id)
        // Look at the screen first: listing 70+ simulators takes several seconds and used to delay the mirror behind it.
        await followUp()
        await refresh()
    }

    /// An action (launch, open a URL, install) changes the screen a moment later. Look right away and again as it settles,
    /// instead of waiting for the next poll, so the mirror reacts to what was just pressed.
    private func followUp() async {
        for delay in [0.3, 1.0, 2.5] {
            try? await Task.sleep(for: .seconds(delay))
            await captureFrame()
        }
    }

    /// Brings this device's window in Simulator.app forward: the way to tap, swipe and type on an Apple simulator,
    /// because `simctl` has no input commands.
    public func openInSimulator(_ device: DeviceInfo) {
        guard device.platform == .apple else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.id]
        do { try process.run(); message = "Opened \(device.name) in Simulator." } catch { message = error.localizedDescription }
    }

    private func runValue<T>(_ device: DeviceInfo, _ working: String, _ work: @escaping () async throws -> T) async -> T? {
        busyIDs.insert(device.id)
        message = working
        defer { busyIDs.remove(device.id) }
        do { let value = try await work(); message = "Done."; return value } catch { message = error.localizedDescription; return nil }
    }

    // MARK: Live view

    /// Starts polling screenshots while the view is on screen. One capture at a time: a slow device is
    /// polled less often rather than piling up commands.
    public func startLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.liveRefresh, self.selected?.state == .booted { await self.captureFrame() }
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    public func stopLive() { liveTask?.cancel(); liveTask = nil }

    public func captureFrame() async {
        guard let device = selected, device.state == .booted else { return }
        do {
            let shot = try await service.screenshotData(id: device.id)
            guard selectedID == device.id else { return }
            frame = NSImage(data: shot.png)
            frameSize = CGSize(width: shot.width, height: shot.height)
            frameError = nil
        } catch {
            frameError = error.localizedDescription
        }
    }
}
