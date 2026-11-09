import Foundation

/// A simulator, emulator or attached device Kiln can show and drive. Backends (simctl, adb, and later
/// UTM/QEMU or Virtualization.framework guests) all produce this one shape, so the Devices view, the
/// agent tools and the MCP tools never care which platform a device belongs to.
public struct DeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public enum Platform: String, Codable, Sendable { case apple, android }
    public enum Kind: String, Codable, Sendable { case phone, tablet, watch, tv, vision, desktop, other }
    public enum State: String, Codable, Sendable {
        case booted, booting, shutdown, shuttingDown, offline, unauthorized, unknown

        public var isRunning: Bool { self == .booted }
    }
    /// Where the device runs. Only simulators and emulators can be booted and shut down by Kiln.
    public enum Origin: String, Codable, Sendable { case simulator, emulator, physical }

    /// Apple: the simulator UDID. Android: the adb serial (`emulator-5554`) while running, `avd:<name>` while not.
    public var id: String
    public var name: String
    public var platform: Platform
    public var kind: Kind
    public var origin: Origin
    public var state: State
    /// "iOS 26.4", "Android API 36", …
    public var runtime: String
    public var isAvailable: Bool
    /// Why the device cannot be used (a missing runtime, an unauthorized adb key), when it cannot.
    public var detail: String?

    public init(id: String, name: String, platform: Platform, kind: Kind = .other, origin: Origin,
                state: State, runtime: String = "", isAvailable: Bool = true, detail: String? = nil) {
        self.id = id; self.name = name; self.platform = platform; self.kind = kind; self.origin = origin
        self.state = state; self.runtime = runtime; self.isAvailable = isAvailable; self.detail = detail
    }

    public var canBoot: Bool { origin != .physical && isAvailable && state == .shutdown }
    public var canShutdown: Bool { origin != .physical && state == .booted }
    public var symbol: String {
        switch kind {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .watch: "applewatch"
        case .tv: "tv"
        case .vision: "visionpro"
        case .desktop: "desktopcomputer"
        case .other: platform == .android ? "smartphone" : "iphone"
        }
    }
}

/// What Kiln found on this Mac for each platform, and what to do when something is missing.
public struct DeviceSetup: Equatable, Sendable {
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var path: String?
        public var detail: String
        public var isAvailable: Bool { path != nil }
        public init(name: String, path: String?, detail: String) { self.name = name; self.path = path; self.detail = detail }
    }
    public var simctl: Tool
    public var adb: Tool
    public var emulator: Tool

    public init(simctl: Tool, adb: Tool, emulator: Tool) { self.simctl = simctl; self.adb = adb; self.emulator = emulator }

    public static let simctlHint = "Install Xcode from the App Store, open it once (or run `sudo xcodebuild -runFirstLaunch`), then add an iOS runtime under Xcode → Settings → Components. Kiln never downloads Xcode or simulator runtimes on its own."
    public static let androidHint = "Install the Android SDK (Android Studio, or `brew install --cask android-commandlinetools`), then `sdkmanager \"platform-tools\" \"emulator\"` and create a virtual device in Android Studio's Device Manager. Kiln looks in $ANDROID_HOME, $ANDROID_SDK_ROOT, ~/Library/Android/sdk and your PATH, and never downloads SDKs or system images on its own."
}

public enum DeviceError: LocalizedError, Equatable, Sendable {
    case toolMissing(String, hint: String)
    case commandFailed(String, status: Int32, output: String)
    case timedOut(String)
    case notFound(String)
    case notBooted(String)
    case unsupported(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool, let hint): "\(tool) is not available. \(hint)"
        case .commandFailed(let what, let status, let output):
            "\(what) failed (exit \(status))" + (output.isEmpty ? "." : ": \(output)")
        case .timedOut(let what): "\(what) did not finish in time."
        case .notFound(let id): "No device with id “\(id)”. Call device_list for current ids."
        case .notBooted(let name): "\(name) is not booted. Boot it first."
        case .unsupported(let why): why
        case .invalidArgument(let why): why
        }
    }
}

/// Image size read from a PNG header, so views can map clicks to device pixels without decoding.
public enum PNGInfo {
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func u32(_ at: Int) -> Int {
            data[data.startIndex + at..<data.startIndex + at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        let w = u32(16), h = u32(20)
        return w > 0 && h > 0 ? (w, h) : nil
    }
}
