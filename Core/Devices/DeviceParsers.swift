import Foundation

/// Pure parsers for `xcrun simctl` and `adb`/`emulator` output. Kept free of processes so they can be
/// tested against recorded fixtures.
public enum DeviceParsers {
    // MARK: simctl

    /// `xcrun simctl list devices -j`. Unavailable devices are kept (marked) so the UI can explain them.
    public static func parseSimctlDevices(_ data: Data) throws -> [DeviceInfo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: Any] else {
            throw DeviceError.commandFailed("Reading simctl output", status: 0, output: "unexpected JSON shape")
        }
        var result: [DeviceInfo] = []
        for (runtimeID, value) in byRuntime {
            guard let entries = value as? [[String: Any]] else { continue }
            let runtime = runtimeName(fromIdentifier: runtimeID)
            for entry in entries {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                let available = (entry["isAvailable"] as? Bool) ?? true
                let state = simulatorState(entry["state"] as? String ?? "")
                result.append(DeviceInfo(
                    id: udid, name: name, platform: .apple,
                    kind: kind(fromDeviceType: entry["deviceTypeIdentifier"] as? String ?? "", name: name),
                    origin: .simulator, state: state, runtime: runtime, isAvailable: available,
                    detail: available ? nil : (entry["availabilityError"] as? String ?? "Runtime not installed")))
            }
        }
        return result.sorted { ($0.runtime, $0.name, $0.id) < ($1.runtime, $1.name, $1.id) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` → `iOS 26.4`.
    public static func runtimeName(fromIdentifier id: String) -> String {
        let tail = id.components(separatedBy: "SimRuntime.").last ?? id
        var parts = tail.split(separator: "-").map(String.init)
        guard let os = parts.first else { return id }
        parts.removeFirst()
        let name = os == "xrOS" ? "visionOS" : os
        return parts.isEmpty ? name : "\(name) \(parts.joined(separator: "."))"
    }

    static func simulatorState(_ raw: String) -> DeviceInfo.State {
        switch raw {
        case "Booted": .booted
        case "Booting": .booting
        case "Shutdown": .shutdown
        case "Shutting Down": .shuttingDown
        default: .unknown
        }
    }

    static func kind(fromDeviceType id: String, name: String) -> DeviceInfo.Kind {
        let s = (id + " " + name).lowercased()
        if s.contains("watch") { return .watch }
        if s.contains("apple-tv") || s.contains("apple tv") { return .tv }
        if s.contains("vision") { return .vision }
        if s.contains("ipad") { return .tablet }
        if s.contains("iphone") { return .phone }
        return .other
    }

    // MARK: adb

    /// One line of `adb devices -l`:
    /// `emulator-5554 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1`
    public struct ADBDevice: Equatable, Sendable {
        public var serial: String
        public var status: String
        public var model: String?
        public var product: String?
        public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    }

    public static func parseADBDevices(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            if line.hasPrefix("List of devices") || line.hasPrefix("*") || line.hasPrefix("adb server") { return nil }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            var model: String?, product: String?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("model:") { model = String(field.dropFirst(6)) }
                if field.hasPrefix("product:") { product = String(field.dropFirst(8)) }
            }
            // "no permissions (…)" and similar multi-word statuses: keep the first word as the status.
            return ADBDevice(serial: fields[0], status: fields[1], model: model, product: product)
        }
    }

    public static func adbState(_ status: String) -> DeviceInfo.State {
        switch status {
        case "device": .booted
        case "offline": .offline
        case "unauthorized": .unauthorized
        default: .unknown
        }
    }

    /// `emulator -list-avds`: one name per line; the emulator also prints `INFO |` and `WARNING |` lines.
    public static func parseAVDList(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" | ") && !$0.hasPrefix("INFO") && !$0.hasPrefix("WARNING") && !$0.hasPrefix("ERROR") }
    }

    /// `adb -s emulator-5554 emu avd name` prints the AVD name, then `OK`.
    public static func parseAVDName(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    /// `Physical size: 1080x2400` (an `Override size:` line, when present, is what the screen really shows).
    public static func parseWMSize(_ text: String) -> (width: Int, height: Int)? {
        var found: (Int, Int)?
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("size:"), let spec = line.split(separator: ":").last else { continue }
            let dims = spec.trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) }
            if dims.count == 2 { found = (dims[0], dims[1]) }
        }
        return found
    }

    /// Android API level → the release name people recognise. Unknown levels fall back to the number.
    public static func androidRuntime(apiLevel: String?) -> String {
        guard let level = apiLevel?.trimmingCharacters(in: .whitespacesAndNewlines), !level.isEmpty else { return "Android" }
        return "Android API \(level)"
    }
}
