import Foundation

/// Lists and drives Apple simulators (`xcrun simctl`) and Android emulators/devices (`adb`, `emulator`).
/// One actor so concurrent UI and agent calls never interleave two boot or install commands on one device.
/// Nothing here downloads an SDK, runtime or system image; a missing tool is reported with how to get it.
public actor DeviceService {
    public static let screenshotTimeout: TimeInterval = 20
    public static let maxRecordSeconds = 180

    private let runner: CommandRunning
    private let locator: DeviceToolLocator
    private let capturesDirectory: URL
    private let pollInterval: Duration

    public init(runner: CommandRunning = SystemCommandRunner(),
                locator: DeviceToolLocator = DeviceToolLocator(),
                capturesDirectory: URL? = nil,
                pollInterval: Duration = .seconds(3)) {
        self.pollInterval = pollInterval
        self.runner = runner
        self.locator = locator
        self.capturesDirectory = capturesDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kiln/Devices/Captures", isDirectory: true)
    }

    // MARK: Setup

    public func setup() async -> DeviceSetup {
        let simctl: DeviceSetup.Tool
        if let result = try? await runner.run(DeviceToolLocator.xcrunPath, ["--find", "simctl"], timeout: 10), result.succeeded {
            simctl = .init(name: "simctl", path: result.text.trimmingCharacters(in: .whitespacesAndNewlines), detail: "Xcode command-line tools found.")
        } else {
            simctl = .init(name: "simctl", path: nil, detail: DeviceSetup.simctlHint)
        }
        let adb = locator.adbPath()
        let emulator = locator.emulatorPath()
        return DeviceSetup(
            simctl: simctl,
            adb: .init(name: "adb", path: adb, detail: adb == nil ? DeviceSetup.androidHint : "Android platform-tools found."),
            emulator: .init(name: "emulator", path: emulator,
                            detail: emulator == nil ? "The Android emulator is not installed, so Android virtual devices cannot be started from Kiln. " + DeviceSetup.androidHint : "Android emulator found."))
    }

    // MARK: Listing

    public struct Listing: Sendable, Equatable {
        public var devices: [DeviceInfo]
        public var setup: DeviceSetup
        /// Per-platform problems that did not stop the other platform from listing.
        public var warnings: [String]
    }

    public func list() async -> Listing {
        let setup = await setup()
        var devices: [DeviceInfo] = []
        var warnings: [String] = []
        if setup.simctl.isAvailable {
            do { devices += try await appleDevices() } catch { warnings.append("Apple simulators: \(error.localizedDescription)") }
        }
        if setup.adb.isAvailable || setup.emulator.isAvailable {
            do { devices += try await androidDevices(setup: setup) } catch { warnings.append("Android: \(error.localizedDescription)") }
        }
        return Listing(devices: devices, setup: setup, warnings: warnings)
    }

    func appleDevices() async throws -> [DeviceInfo] {
        let result = try await simctl(["list", "devices", "-j"], timeout: 30)
        return try DeviceParsers.parseSimctlDevices(result.stdout)
    }

    func androidDevices(setup: DeviceSetup) async throws -> [DeviceInfo] {
        var devices: [DeviceInfo] = []
        var runningAVDs: Set<String> = []
        if let adb = setup.adb.path {
            // `adb devices` starts the adb server (a background process) if it is not running; that is adb's own behaviour.
            let result = try await runner.run(adb, ["devices", "-l"], timeout: 20)
            for entry in DeviceParsers.parseADBDevices(result.text) {
                var name = entry.model?.replacingOccurrences(of: "_", with: " ") ?? entry.serial
                let state = DeviceParsers.adbState(entry.status)
                var runtime = "Android"
                if state == .booted {
                    if entry.isEmulator,
                       let avd = try? await runner.run(adb, ["-s", entry.serial, "emu", "avd", "name"], timeout: 10),
                       let avdName = DeviceParsers.parseAVDName(avd.text) {
                        name = avdName.replacingOccurrences(of: "_", with: " ")
                        runningAVDs.insert(avdName)
                    }
                    if let api = try? await runner.run(adb, ["-s", entry.serial, "shell", "getprop", "ro.build.version.sdk"], timeout: 10) {
                        runtime = DeviceParsers.androidRuntime(apiLevel: api.text)
                    }
                }
                devices.append(DeviceInfo(
                    id: entry.serial, name: name, platform: .android, kind: .phone,
                    origin: entry.isEmulator ? .emulator : .physical, state: state, runtime: runtime,
                    detail: state == .unauthorized ? "Accept the USB-debugging prompt on the device, then refresh." : nil))
            }
        }
        if let emulator = setup.emulator.path {
            let result = try await runner.run(emulator, ["-list-avds"], timeout: 20)
            for avd in DeviceParsers.parseAVDList(result.text) where !runningAVDs.contains(avd) {
                devices.append(DeviceInfo(id: "avd:\(avd)", name: avd.replacingOccurrences(of: "_", with: " "), platform: .android,
                                          kind: .phone, origin: .emulator, state: .shutdown, runtime: "Android"))
            }
        }
        return devices
    }

    // MARK: Lifecycle

    public func boot(id: String, waitSeconds: Int = 120) async throws -> String {
        let device = try await resolve(id)
        guard device.isAvailable else { throw DeviceError.unsupported("\(device.name) cannot be booted: \(device.detail ?? "unavailable").") }
        switch device.platform {
        case .apple:
            if device.state == .booted { return "\(device.name) is already booted." }
            let result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "boot", device.id], timeout: 60)
            // simctl exits 149 with "current state: Booted" when a race already booted it; that is success.
            if !result.succeeded && !result.stderr.contains("current state: Booted") {
                throw DeviceError.commandFailed("Booting \(device.name)", status: result.status, output: result.stderr.trimmed)
            }
            let status = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "bootstatus", device.id], timeout: TimeInterval(waitSeconds))
            guard status.succeeded else { throw DeviceError.commandFailed("Waiting for \(device.name) to finish booting", status: status.status, output: status.stderr.trimmed) }
            return "\(device.name) is booted."
        case .android:
            guard device.origin == .emulator else { throw DeviceError.unsupported("\(device.name) is a physical device; it cannot be booted from Kiln.") }
            if device.state == .booted { return "\(device.name) is already booted." }
            let setup = await setup()
            guard let emulator = setup.emulator.path else { throw DeviceError.toolMissing("The Android emulator", hint: DeviceSetup.androidHint) }
            guard let adb = setup.adb.path else { throw DeviceError.toolMissing("adb", hint: DeviceSetup.androidHint) }
            let avd = device.id.hasPrefix("avd:") ? String(device.id.dropFirst(4)) : device.name
            try runner.spawnDetached(emulator, ["-avd", avd, "-no-snapshot-save"])
            return try await waitForAndroidBoot(adb: adb, avd: avd, seconds: waitSeconds)
        }
    }

    private func waitForAndroidBoot(adb: String, avd: String, seconds: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            try await Task.sleep(for: pollInterval)
            let listed = try await runner.run(adb, ["devices"], timeout: 15)
            for entry in DeviceParsers.parseADBDevices(listed.text) where entry.isEmulator && entry.status == "device" {
                let name = try? await runner.run(adb, ["-s", entry.serial, "emu", "avd", "name"], timeout: 10)
                guard let name, DeviceParsers.parseAVDName(name.text) == avd else { continue }
                let done = try? await runner.run(adb, ["-s", entry.serial, "shell", "getprop", "sys.boot_completed"], timeout: 10)
                if done?.text.trimmed == "1" { return "\(avd) is booted as \(entry.serial)." }
            }
        }
        return "\(avd) was started but has not finished booting after \(seconds)s. It may still be starting; call device_list to check."
    }

    public func shutdown(id: String) async throws -> String {
        let device = try await resolve(id)
        guard device.origin != .physical else { throw DeviceError.unsupported("\(device.name) is a physical device; Kiln does not power it off.") }
        guard device.state != .shutdown else { return "\(device.name) is already shut down." }
        switch device.platform {
        case .apple:
            let result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "shutdown", device.id], timeout: 60)
            if !result.succeeded && !result.stderr.contains("current state: Shutdown") {
                throw DeviceError.commandFailed("Shutting down \(device.name)", status: result.status, output: result.stderr.trimmed)
            }
        case .android:
            let adb = try await requireADB()
            let result = try await runner.run(adb, ["-s", device.id, "emu", "kill"], timeout: 30)
            guard result.succeeded else { throw DeviceError.commandFailed("Shutting down \(device.name)", status: result.status, output: result.stderr.trimmed) }
        }
        return "\(device.name) is shutting down."
    }

    // MARK: Screen

    public struct Screenshot: Sendable {
        public var png: Data
        public var width: Int
        public var height: Int
    }

    /// The device's screen as PNG bytes, without writing anywhere. The live view and `screenshot` both use this.
    public func screenshotData(id: String) async throws -> Screenshot {
        let device = try await requireBooted(id)
        var result: CommandResult
        switch device.platform {
        case .apple:
            // `simctl io … screenshot -` is documented to write to stdout but tries to save a file named "-" on
            // current Xcodes, so the picture goes through a temporary file instead.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-simshot-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temp) }
            result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "io", device.id, "screenshot", "--type=png", temp.path], timeout: Self.screenshotTimeout)
            if result.succeeded, let data = try? Data(contentsOf: temp) { result.stdout = data }
        case .android:
            result = try await runner.run(try await requireADB(), ["-s", device.id, "exec-out", "screencap", "-p"], timeout: Self.screenshotTimeout)
        }
        guard result.succeeded, let size = PNGInfo.size(of: result.stdout) else {
            throw DeviceError.commandFailed("Taking a screenshot of \(device.name)", status: result.status,
                                            output: result.stderr.trimmed.isEmpty ? "the device returned no image" : result.stderr.trimmed)
        }
        return Screenshot(png: result.stdout, width: size.width, height: size.height)
    }

    /// Saves a screenshot under Kiln's captures folder and returns where.
    public func screenshot(id: String) async throws -> (url: URL, width: Int, height: Int) {
        let shot = try await screenshotData(id: id)
        let url = try captureURL(prefix: "screenshot", id: id, ext: "png")
        try shot.png.write(to: url, options: .atomic)
        return (url, shot.width, shot.height)
    }

    public func recordVideo(id: String, seconds: Int) async throws -> URL {
        guard (1...Self.maxRecordSeconds).contains(seconds) else {
            throw DeviceError.invalidArgument("seconds must be between 1 and \(Self.maxRecordSeconds).")
        }
        let device = try await requireBooted(id)
        let url = try captureURL(prefix: "recording", id: id, ext: device.platform == .apple ? "mov" : "mp4")
        switch device.platform {
        case .apple:
            let result = try await runner.runInterrupted(DeviceToolLocator.xcrunPath,
                ["simctl", "io", device.id, "recordVideo", "--codec=h264", "--force", url.path], after: TimeInterval(seconds))
            // SIGINT is how simctl is asked to stop, and it exits 0 once the file is finalised.
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DeviceError.commandFailed("Recording \(device.name)", status: result.status, output: result.stderr.trimmed)
            }
        case .android:
            let adb = try await requireADB()
            let remote = "/sdcard/kiln-recording-\(UUID().uuidString.prefix(8)).mp4"
            let record = try await runner.run(adb, ["-s", device.id, "shell", "screenrecord", "--time-limit", String(min(seconds, 180)), remote],
                                              timeout: TimeInterval(seconds + 30))
            guard record.succeeded else { throw DeviceError.commandFailed("Recording \(device.name)", status: record.status, output: record.stderr.trimmed) }
            let pull = try await runner.run(adb, ["-s", device.id, "pull", remote, url.path], timeout: 120)
            _ = try? await runner.run(adb, ["-s", device.id, "shell", "rm", remote], timeout: 15)
            guard pull.succeeded else { throw DeviceError.commandFailed("Copying the recording", status: pull.status, output: pull.stderr.trimmed) }
        }
        return url
    }

    // MARK: Apps and URLs

    public func install(id: String, path: String) async throws -> String {
        let device = try await requireBooted(id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw DeviceError.invalidArgument("No file at \(path).") }
        switch device.platform {
        case .apple:
            guard path.hasSuffix(".app"), isDirectory.boolValue else { throw DeviceError.invalidArgument("An iOS simulator install needs a built .app bundle (a folder ending in .app).") }
            let result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "install", device.id, path], timeout: 180)
            guard result.succeeded else { throw DeviceError.commandFailed("Installing on \(device.name)", status: result.status, output: result.stderr.trimmed) }
        case .android:
            guard path.hasSuffix(".apk"), !isDirectory.boolValue else { throw DeviceError.invalidArgument("An Android install needs an .apk file.") }
            let result = try await runner.run(try await requireADB(), ["-s", device.id, "install", "-r", path], timeout: 300)
            guard result.succeeded, !result.text.contains("Failure") else {
                throw DeviceError.commandFailed("Installing on \(device.name)", status: result.status, output: (result.text + result.stderr).trimmed)
            }
        }
        return "Installed \(URL(fileURLWithPath: path).lastPathComponent) on \(device.name)."
    }

    /// `app` is a bundle id (Apple) or a package name (Android); `activity` is optional and Android-only.
    public func launch(id: String, app: String, activity: String? = nil) async throws -> String {
        let device = try await requireBooted(id)
        try Self.validateIdentifier(app, what: "App id")
        switch device.platform {
        case .apple:
            let result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "launch", device.id, app], timeout: 60)
            guard result.succeeded else { throw DeviceError.commandFailed("Launching \(app)", status: result.status, output: result.stderr.trimmed) }
            return "Launched \(app) on \(device.name). " + result.text.trimmed
        case .android:
            let adb = try await requireADB()
            var args = ["-s", device.id, "shell"]
            if let activity, !activity.isEmpty {
                try Self.validateIdentifier(activity, what: "Activity")
                args += ["am", "start", "-n", "\(app)/\(activity)"]
            } else {
                args += ["monkey", "-p", app, "-c", "android.intent.category.LAUNCHER", "1"]
            }
            let result = try await runner.run(adb, args, timeout: 60)
            let text = (result.text + result.stderr)
            guard result.succeeded, !text.contains("Error") , !text.contains("No activities found") else {
                throw DeviceError.commandFailed("Launching \(app)", status: result.status, output: text.trimmed)
            }
            return "Launched \(app) on \(device.name)."
        }
    }

    public func openURL(id: String, url: String) async throws -> String {
        let device = try await requireBooted(id)
        let trimmed = url.trimmed
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme, !scheme.isEmpty,
              !trimmed.contains(where: \.isWhitespace) else {
            throw DeviceError.invalidArgument("That is not a valid URL (it needs a scheme such as https:// and no spaces).")
        }
        switch device.platform {
        case .apple:
            let result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "openurl", device.id, trimmed], timeout: 30)
            guard result.succeeded else { throw DeviceError.commandFailed("Opening the URL", status: result.status, output: result.stderr.trimmed) }
        case .android:
            let result = try await runner.run(try await requireADB(), ["-s", device.id, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", Self.shellQuote(trimmed)], timeout: 30)
            guard result.succeeded, !result.text.contains("Error") else { throw DeviceError.commandFailed("Opening the URL", status: result.status, output: (result.text + result.stderr).trimmed) }
        }
        return "Opened \(trimmed) on \(device.name)."
    }

    // MARK: Logs

    public func logs(id: String, lines: Int, contains filter: String?) async throws -> String {
        let device = try await requireBooted(id)
        let count = max(1, min(2000, lines))
        let result: CommandResult
        switch device.platform {
        case .android:
            result = try await runner.run(try await requireADB(), ["-s", device.id, "logcat", "-d", "-t", String(count * (filter == nil ? 1 : 10))], timeout: 30)
        case .apple:
            result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl", "spawn", device.id, "log", "show", "--last", "2m", "--style", "compact"], timeout: 60)
        }
        guard result.succeeded else { throw DeviceError.commandFailed("Reading logs from \(device.name)", status: result.status, output: result.stderr.trimmed) }
        return Self.tail(result.text, lines: count, contains: filter)
    }

    static func tail(_ text: String, lines: Int, contains filter: String?) -> String {
        var all = text.split(whereSeparator: \.isNewline).map(String.init)
        if let filter, !filter.isEmpty { all = all.filter { $0.localizedCaseInsensitiveContains(filter) } }
        return all.suffix(lines).joined(separator: "\n")
    }

    // MARK: Input (Android only; simctl has no touch or keyboard injection)

    public enum Input: Sendable, Equatable {
        case tap(x: Int, y: Int)
        case swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int)
        case text(String)
        case key(String)
    }

    public static let appleInputUnsupported = "Touch and keyboard forwarding is not available for Apple simulators: `simctl` has no input commands. Use device_open_url or device_launch to move around, or drive the simulator with an accessibility-based tool."

    public func send(id: String, input: Input) async throws -> String {
        let device = try await requireBooted(id)
        guard device.platform == .android else { throw DeviceError.unsupported(Self.appleInputUnsupported) }
        let args = try Self.adbInputArguments(input)
        let result = try await runner.run(try await requireADB(), ["-s", device.id, "shell"] + args, timeout: 20)
        guard result.succeeded else { throw DeviceError.commandFailed("Sending input to \(device.name)", status: result.status, output: (result.text + result.stderr).trimmed) }
        return "Sent \(Self.describe(input)) to \(device.name)."
    }

    static func adbInputArguments(_ input: Input) throws -> [String] {
        switch input {
        case .tap(let x, let y):
            guard x >= 0, y >= 0 else { throw DeviceError.invalidArgument("Coordinates must not be negative.") }
            return ["input", "tap", String(x), String(y)]
        case .swipe(let x1, let y1, let x2, let y2, let ms):
            guard [x1, y1, x2, y2].allSatisfy({ $0 >= 0 }) else { throw DeviceError.invalidArgument("Coordinates must not be negative.") }
            return ["input", "swipe", String(x1), String(y1), String(x2), String(y2), String(max(50, min(ms, 5000)))]
        case .text(let text):
            guard !text.isEmpty, text.count <= 500 else { throw DeviceError.invalidArgument("text must be 1–500 characters.") }
            // `input text` treats %s as a space; everything else is passed through a quoted shell word.
            return ["input", "text", shellQuote(text.replacingOccurrences(of: " ", with: "%s"))]
        case .key(let key):
            guard key.range(of: #"^(KEYCODE_[A-Z0-9_]+|[0-9]+)$"#, options: .regularExpression) != nil else {
                throw DeviceError.invalidArgument("key must be an Android keycode such as KEYCODE_HOME or KEYCODE_BACK.")
            }
            return ["input", "keyevent", key]
        }
    }

    static func describe(_ input: Input) -> String {
        switch input {
        case .tap(let x, let y): "tap at (\(x), \(y))"
        case .swipe(let x1, let y1, let x2, let y2, _): "swipe (\(x1), \(y1)) → (\(x2), \(y2))"
        case .text(let t): "text of \(t.count) characters"
        case .key(let k): "key \(k)"
        }
    }

    // MARK: Helpers

    static func validateIdentifier(_ value: String, what: String) throws {
        guard value.range(of: #"^[A-Za-z0-9_.$/]+$"#, options: .regularExpression) != nil, value.count <= 200 else {
            throw DeviceError.invalidArgument("\(what) “\(value)” contains characters that are not allowed.")
        }
    }

    /// Single-quotes a word for the device's shell. adb joins its arguments into one command line for `sh`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func simctl(_ args: [String], timeout: TimeInterval) async throws -> CommandResult {
        let result: CommandResult
        do { result = try await runner.run(DeviceToolLocator.xcrunPath, ["simctl"] + args, timeout: timeout) }
        catch let error as DeviceError { throw error }
        guard result.succeeded else {
            throw DeviceError.commandFailed("xcrun simctl \(args.first ?? "")", status: result.status, output: result.stderr.trimmed)
        }
        return result
    }

    private func requireADB() async throws -> String {
        guard let adb = locator.adbPath() else { throw DeviceError.toolMissing("adb", hint: DeviceSetup.androidHint) }
        return adb
    }

    private func resolve(_ id: String) async throws -> DeviceInfo {
        let listing = await list()
        let wanted = id.trimmed
        if let match = listing.devices.first(where: { $0.id == wanted }) { return match }
        // Accept an exact name when it is unambiguous, so the agent can say "iPhone 17 Pro" once and be understood.
        let byName = listing.devices.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame && $0.isAvailable }
        let booted = byName.filter { $0.state == .booted }
        if booted.count == 1 { return booted[0] }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw DeviceError.invalidArgument("“\(wanted)” matches \(byName.count) devices; use an id from device_list.") }
        throw DeviceError.notFound(wanted)
    }

    private func requireBooted(_ id: String) async throws -> DeviceInfo {
        let device = try await resolve(id)
        guard device.state == .booted else { throw DeviceError.notBooted(device.name) }
        return device
    }

    private func captureURL(prefix: String, id: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let safeID = String(id.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(12))
        return capturesDirectory.appendingPathComponent("\(prefix)-\(safeID)-\(stamp)-\(UUID().uuidString.prefix(4)).\(ext)")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
