import Foundation

/// The Devices module as agent tools (`device_*`), registered like `re_*` and `lab_*`, and so also served by
/// Kiln's MCP endpoint. Reading and screenshots are read-level; anything that changes a device is write or
/// execute and goes through approval.
public enum DeviceAgentTools {
    public static let prefix = "device_"

    @MainActor
    public static func register(service: DeviceService, into registry: ToolRegistry = .shared) {
        for kind in Kind.allCases { registry.register(DeviceAgentTool(kind: kind, service: service)) }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case list, status, screenshot, logs
        case boot, shutdown, install, launch
        case openURL = "open_url"
        case input
        case recordVideo = "record_video"

        static let deviceParam = ToolParam(name: "device_id", description: "Device id from device_list (a simulator UDID, an adb serial such as emulator-5554, or avd:<name>). An exact device name also works when unambiguous.")

        public var spec: ToolSpec {
            switch self {
            case .list:
                ToolSpec(name: "device_list", summary: "List Apple simulators and Android emulators/devices with id, platform, runtime and state, plus which tools (simctl, adb, emulator) were found.",
                         permission: .read)
            case .status:
                ToolSpec(name: "device_status", summary: "Report which device tools Kiln found (simctl, adb, emulator) and how to set up any that are missing.", permission: .read)
            case .screenshot:
                ToolSpec(name: "device_screenshot", summary: "Capture the screen of a booted device as a PNG saved in Kiln's captures folder; returns the file path and pixel size.",
                         parameters: [Self.deviceParam], permission: .read)
            case .logs:
                ToolSpec(name: "device_logs", summary: "Tail the device log: Android logcat, or the last two minutes of an Apple simulator's unified log.",
                         parameters: [Self.deviceParam,
                                      ToolParam(name: "lines", type: "integer", description: "Lines to return from the end (default 200, max 2000)", required: false),
                                      ToolParam(name: "contains", description: "Only lines containing this text (case-insensitive)", required: false)],
                         permission: .read)
            case .boot:
                ToolSpec(name: "device_boot", summary: "Boot a simulator or start an Android virtual device and wait until it is ready. Starts a process and uses compute; requires approval.",
                         parameters: [Self.deviceParam], permission: .execute)
            case .shutdown:
                ToolSpec(name: "device_shutdown", summary: "Shut down a running simulator or emulator. Unsaved state in the device is lost; requires approval.",
                         parameters: [Self.deviceParam], permission: .execute)
            case .install:
                ToolSpec(name: "device_install", summary: "Install a built .app (Apple simulator) or .apk (Android) on a booted device. Changes the device; requires approval.",
                         parameters: [Self.deviceParam, ToolParam(name: "path", description: "Absolute path to the .app bundle or .apk")], permission: .execute)
            case .launch:
                ToolSpec(name: "device_launch", summary: "Launch an installed app by bundle id (Apple) or package name (Android) on a booted device. Requires approval.",
                         parameters: [Self.deviceParam, ToolParam(name: "app", description: "Bundle id or package name"),
                                      ToolParam(name: "activity", description: "Android only: activity class to start instead of the launcher activity", required: false)],
                         permission: .execute)
            case .openURL:
                ToolSpec(name: "device_open_url", summary: "Open a URL or deep link on a booted device. Changes what the device shows; requires approval.",
                         parameters: [Self.deviceParam, ToolParam(name: "url", description: "URL with a scheme, e.g. https://example.com or myapp://settings")], permission: .write)
            case .input:
                ToolSpec(name: "device_input", summary: "Send touch or keyboard input to an Android device or emulator: tap, swipe, text or key. Not supported for Apple simulators (simctl has no input commands). Requires approval.",
                         parameters: [Self.deviceParam,
                                      ToolParam(name: "action", description: "tap, swipe, text or key"),
                                      ToolParam(name: "x", type: "integer", description: "tap: x in device pixels (same scale as the screenshot)", required: false),
                                      ToolParam(name: "y", type: "integer", description: "tap: y in device pixels", required: false),
                                      ToolParam(name: "x2", type: "integer", description: "swipe: end x", required: false),
                                      ToolParam(name: "y2", type: "integer", description: "swipe: end y", required: false),
                                      ToolParam(name: "duration_ms", type: "integer", description: "swipe duration, default 300", required: false),
                                      ToolParam(name: "text", description: "text: characters to type", required: false),
                                      ToolParam(name: "key", description: "key: Android keycode such as KEYCODE_HOME", required: false)],
                         permission: .write)
            case .recordVideo:
                ToolSpec(name: "device_record_video", summary: "Record the screen of a booted device for a number of seconds (max 180) into Kiln's captures folder; returns the file path. Blocks until finished; requires approval.",
                         parameters: [Self.deviceParam, ToolParam(name: "seconds", type: "integer", description: "1–180")], permission: .write)
            }
        }
    }
}

struct DeviceAgentTool: ToolExecuting {
    let kind: DeviceAgentTools.Kind
    let service: DeviceService

    var spec: ToolSpec { kind.spec }

    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        func string(_ key: String) -> String? { (args[key] as? String)?.trimmed.nilIfEmpty }
        func int(_ key: String) -> Int? { (args[key] as? Int) ?? (args[key] as? Double).map(Int.init) ?? (args[key] as? String).flatMap(Int.init) }
        func required(_ key: String) throws -> String {
            guard let value = string(key) else { throw DeviceError.invalidArgument("Missing required argument “\(key)”.") }
            return value
        }

        switch kind {
        case .list:
            return Self.render(await service.list())
        case .status:
            return Self.render(await service.setup())
        case .screenshot:
            let shot = try await service.screenshot(id: try required("device_id"))
            return "Saved screenshot \(shot.width)×\(shot.height) px to \(shot.url.path)"
        case .logs:
            let text = try await service.logs(id: try required("device_id"), lines: int("lines") ?? 200, contains: string("contains"))
            return text.isEmpty ? "No matching log lines." : text
        case .boot:
            return try await service.boot(id: try required("device_id"))
        case .shutdown:
            return try await service.shutdown(id: try required("device_id"))
        case .install:
            return try await service.install(id: try required("device_id"), path: try required("path"))
        case .launch:
            return try await service.launch(id: try required("device_id"), app: try required("app"), activity: string("activity"))
        case .openURL:
            return try await service.openURL(id: try required("device_id"), url: try required("url"))
        case .recordVideo:
            guard let seconds = int("seconds") else { throw DeviceError.invalidArgument("Missing required integer argument “seconds”.") }
            let url = try await service.recordVideo(id: try required("device_id"), seconds: seconds)
            return "Saved \(seconds)s recording to \(url.path)"
        case .input:
            let id = try required("device_id")
            let input: DeviceService.Input
            switch try required("action").lowercased() {
            case "tap":
                guard let x = int("x"), let y = int("y") else { throw DeviceError.invalidArgument("tap needs integer x and y.") }
                input = .tap(x: x, y: y)
            case "swipe":
                guard let x = int("x"), let y = int("y"), let x2 = int("x2"), let y2 = int("y2") else { throw DeviceError.invalidArgument("swipe needs integer x, y, x2 and y2.") }
                input = .swipe(x1: x, y1: y, x2: x2, y2: y2, durationMs: int("duration_ms") ?? 300)
            case "text": input = .text(try required("text"))
            case "key": input = .key(try required("key"))
            default: throw DeviceError.invalidArgument("action must be tap, swipe, text or key.")
            }
            return try await service.send(id: id, input: input)
        }
    }

    // MARK: Rendering

    static func render(_ listing: DeviceService.Listing) -> String {
        var lines: [String] = []
        if listing.devices.isEmpty { lines.append("No devices found.") }
        for device in listing.devices where device.isAvailable {
            lines.append("\(device.id) · \(device.name) · \(device.platform.rawValue) \(device.origin.rawValue) · \(device.runtime) · \(device.state.rawValue)"
                         + (device.detail.map { " · \($0)" } ?? ""))
        }
        let unavailable = listing.devices.filter { !$0.isAvailable }
        if !unavailable.isEmpty { lines.append("(\(unavailable.count) more simulators are unavailable: their runtime is not installed.)") }
        lines += listing.warnings.map { "Warning: \($0)" }
        lines.append("")
        lines.append(render(listing.setup))
        return lines.joined(separator: "\n")
    }

    static func render(_ setup: DeviceSetup) -> String {
        [setup.simctl, setup.adb, setup.emulator].map { tool in
            tool.isAvailable ? "\(tool.name): \(tool.path ?? "")" : "\(tool.name): not found. \(tool.detail)"
        }.joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
