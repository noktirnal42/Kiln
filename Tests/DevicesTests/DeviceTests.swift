import Foundation
import Testing
@testable import Kiln

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Devices/\(name)")
    return try Data(contentsOf: url)
}
private func fixtureText(_ name: String) throws -> String { String(decoding: try fixture(name), as: UTF8.self) }

@Suite("Device parsers")
struct DeviceParserTests {
    @Test func parsesSimctlDevices() throws {
        let devices = try DeviceParsers.parseSimctlDevices(try fixture("simctl-list-devices.json"))
        #expect(devices.allSatisfy { $0.platform == .apple && $0.origin == .simulator })
        let booted = devices.filter { $0.state == .booted }
        #expect(booted.count == 1)
        #expect(booted[0].runtime == "iOS 26.5")
        #expect(booted[0].kind == .phone || booted[0].kind == .tablet)
        #expect(devices.contains { $0.kind == .watch && $0.runtime.hasPrefix("watchOS") })
        #expect(devices.contains { $0.kind == .tv && $0.runtime.hasPrefix("tvOS") })
    }

    @Test func keepsUnavailableDevicesAndSaysWhy() throws {
        let devices = try DeviceParsers.parseSimctlDevices(try fixture("simctl-list-devices.json"))
        let missing = try #require(devices.first { !$0.isAvailable })
        #expect(missing.name == "iPhone 16")
        #expect(missing.detail?.contains("runtime profile not found") == true)
        #expect(!missing.canBoot)
    }

    @Test func rejectsUnexpectedSimctlJSON() {
        #expect(throws: DeviceError.self) { try DeviceParsers.parseSimctlDevices(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try DeviceParsers.parseSimctlDevices(Data("not json".utf8)) }
    }

    @Test func runtimeNames() {
        #expect(DeviceParsers.runtimeName(fromIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4") == "iOS 26.4")
        #expect(DeviceParsers.runtimeName(fromIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-0") == "visionOS 2.0")
        #expect(DeviceParsers.runtimeName(fromIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0") == "tvOS 27.0")
    }

    @Test func parsesAdbDevices() throws {
        let list = DeviceParsers.parseADBDevices(try fixtureText("adb-devices-l.txt"))
        #expect(list.map(\.serial) == ["emulator-5554", "R5CT1234ABC", "0123456789ABCDEF"])
        #expect(list[0].isEmulator && list[0].model == "sdk_gphone64_arm64" && list[0].status == "device")
        #expect(!list[1].isEmulator && DeviceParsers.adbState(list[1].status) == .unauthorized)
        #expect(DeviceParsers.adbState(list[2].status) == .offline)
    }

    @Test func ignoresAdbDaemonChatter() throws {
        #expect(DeviceParsers.parseADBDevices(try fixtureText("adb-devices-daemon-start.txt")).isEmpty)
    }

    @Test func parsesAVDListsWithAndWithoutEmulatorNoise() throws {
        #expect(DeviceParsers.parseAVDList(try fixtureText("emulator-list-avds.txt")) == ["Medium_Phone_API_36.1", "OpenCamp_QA"])
        #expect(DeviceParsers.parseAVDList(try fixtureText("emulator-list-avds-noisy.txt")) == ["Pixel_8_API_35", "Medium_Phone_API_36.1"])
    }

    @Test func parsesAVDNameAndScreenSize() throws {
        #expect(DeviceParsers.parseAVDName(try fixtureText("emu-avd-name.txt")) == "Pixel_8_API_35")
        let size = try #require(DeviceParsers.parseWMSize(try fixtureText("wm-size.txt")))
        #expect(size.width == 720 && size.height == 1600)   // the override is what the screen shows
        #expect(DeviceParsers.parseWMSize("garbage") == nil)
    }

    @Test func readsPNGSize() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 4, 56, 0, 0, 9, 96])
        let size = PNGInfo.size(of: png)
        #expect(size?.width == 1080 && size?.height == 2400)
        #expect(PNGInfo.size(of: Data("nope".utf8)) == nil)
    }
}

@Suite("Device tool locator")
struct DeviceToolLocatorTests {
    @Test func prefersAndroidHomeThenDefaultSDKThenPath() {
        let present: Set<String> = ["/sdk/platform-tools/adb", "/home/u/Library/Android/sdk/emulator/emulator", "/usr/local/bin/adb"]
        let locator = DeviceToolLocator(environment: ["ANDROID_HOME": "/sdk", "PATH": "/usr/local/bin"], home: "/home/u",
                                        isExecutable: { present.contains($0) })
        #expect(locator.adbPath() == "/sdk/platform-tools/adb")
        #expect(locator.emulatorPath() == "/home/u/Library/Android/sdk/emulator/emulator")
        let pathOnly = DeviceToolLocator(environment: ["PATH": "/usr/local/bin"], home: "/nobody", isExecutable: { present.contains($0) })
        #expect(pathOnly.adbPath() == "/usr/local/bin/adb")
        #expect(pathOnly.emulatorPath() == nil)
    }
}

/// Scripted command runner: records every invocation and answers from a table.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _spawned: [Call] = []
    var responder: @Sendable (String, [String]) -> CommandResult = { _, _ in CommandResult(status: 1, stdout: Data(), stderr: "unscripted") }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var spawned: [Call] { lock.lock(); defer { lock.unlock() }; return _spawned }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        record(Call(executable: executable, arguments: arguments))
        return responder(executable, arguments)
    }
    func runInterrupted(_ executable: String, _ arguments: [String], after duration: TimeInterval) async throws -> CommandResult {
        try await run(executable, arguments, timeout: duration)
    }
    private func record(_ call: Call) { lock.lock(); _calls.append(call); lock.unlock() }
    func spawnDetached(_ executable: String, _ arguments: [String]) throws {
        lock.lock(); _spawned.append(Call(executable: executable, arguments: arguments)); lock.unlock()
    }
}

private func ok(_ text: String = "") -> CommandResult { CommandResult(status: 0, stdout: Data(text.utf8), stderr: "") }

private let fakeADB = "/sdk/platform-tools/adb"
private let fakeEmulator = "/sdk/emulator/emulator"

private func makeService(_ runner: FakeRunner, android: Bool = true, captures: URL? = nil) -> DeviceService {
    let present: Set<String> = android ? [fakeADB, fakeEmulator] : []
    return DeviceService(runner: runner,
                         locator: DeviceToolLocator(environment: ["ANDROID_HOME": "/sdk"], home: "/nobody", isExecutable: { present.contains($0) }),
                         capturesDirectory: captures ?? FileManager.default.temporaryDirectory.appendingPathComponent("kiln-device-tests-\(UUID().uuidString)"),
                         pollInterval: .milliseconds(10))
}

private func defaultResponder(simctlJSON: Data, adbDevices: String, avds: String) -> @Sendable (String, [String]) -> CommandResult {
    { exe, args in
        switch (exe, args) {
        case ("/usr/bin/xcrun", let a) where a.first == "--find": return ok("/Applications/Xcode.app/.../simctl\n")
        case ("/usr/bin/xcrun", let a) where a.prefix(3).elementsEqual(["simctl", "list", "devices"]): return CommandResult(status: 0, stdout: simctlJSON, stderr: "")
        case (fakeADB, let a) where a == ["devices", "-l"]: return ok(adbDevices)
        case (fakeADB, let a) where a.suffix(3) == ["emu", "avd", "name"]: return ok("Pixel_8_API_35\nOK\n")
        case (fakeADB, let a) where a.contains("getprop"): return ok("35\n")
        case (fakeEmulator, _): return ok(avds)
        default: return CommandResult(status: 1, stdout: Data(), stderr: "unscripted: \(exe) \(args.joined(separator: " "))")
        }
    }
}

@Suite("Device service")
struct DeviceServiceTests {
    private func listingRunner() throws -> FakeRunner {
        let runner = FakeRunner()
        runner.responder = defaultResponder(simctlJSON: try fixture("simctl-list-devices.json"),
                                            adbDevices: try fixtureText("adb-devices-l.txt"),
                                            avds: "Pixel_8_API_35\nOpenCamp_QA\n")
        return runner
    }

    @Test func mergesAppleAndAndroidIntoOneList() async throws {
        let listing = await makeService(try listingRunner()).list()
        #expect(listing.setup.simctl.isAvailable && listing.setup.adb.isAvailable && listing.setup.emulator.isAvailable)
        #expect(listing.warnings.isEmpty)
        let android = listing.devices.filter { $0.platform == .android }
        // The running emulator is listed once under its serial and AVD name; only the other AVD is "avd:".
        let running = try #require(android.first { $0.id == "emulator-5554" })
        #expect(running.name == "Pixel 8 API 35" && running.state == .booted && running.runtime == "Android API 35")
        #expect(android.contains { $0.id == "avd:OpenCamp_QA" && $0.state == .shutdown && $0.canBoot })
        #expect(!android.contains { $0.id == "avd:Pixel_8_API_35" })
        let usb = try #require(android.first { $0.id == "R5CT1234ABC" })
        #expect(usb.origin == .physical && usb.state == .unauthorized && !usb.canBoot && !usb.canShutdown)
    }

    @Test func missingToolsGiveASetupStateNotAnError() async throws {
        let runner = FakeRunner()
        runner.responder = { exe, args in
            args.first == "--find" ? CommandResult(status: 1, stdout: Data(), stderr: "xcrun: error: unable to find utility \"simctl\"") : ok()
        }
        let listing = await makeService(runner, android: false).list()
        #expect(listing.devices.isEmpty && listing.warnings.isEmpty)
        #expect(!listing.setup.simctl.isAvailable && listing.setup.simctl.detail.contains("Xcode"))
        #expect(listing.setup.adb.detail.contains("never downloads"))
        // Nothing but the detection probe ran: no list, no adb.
        #expect(runner.calls.allSatisfy { $0.arguments.first == "--find" })
        let text = DeviceAgentTool.render(listing)
        #expect(text.contains("No devices found.") && text.contains("simctl: not found"))
    }

    @Test func oneFailingPlatformDoesNotHideTheOther() async throws {
        let runner = try listingRunner()
        let base = runner.responder
        runner.responder = { exe, args in
            args.prefix(3).elementsEqual(["simctl", "list", "devices"]) ? CommandResult(status: 1, stdout: Data(), stderr: "CoreSimulatorService connection invalid") : base(exe, args)
        }
        let listing = await makeService(runner).list()
        #expect(listing.devices.contains { $0.platform == .android })
        #expect(listing.warnings.count == 1 && listing.warnings[0].contains("CoreSimulatorService"))
    }

    @Test func bootingASimulatorRunsBootThenBootstatus() async throws {
        let runner = try listingRunner()
        let base = runner.responder
        runner.responder = { exe, args in args.prefix(2) == ["simctl", "boot"] || args.prefix(2) == ["simctl", "bootstatus"] ? ok() : base(exe, args) }
        let shutdown = try #require(try DeviceParsers.parseSimctlDevices(try fixture("simctl-list-devices.json")).first { $0.state == .shutdown && $0.isAvailable })
        let message = try await makeService(runner).boot(id: shutdown.id)
        #expect(message.contains("booted"))
        let verbs = runner.calls.compactMap { $0.arguments.count > 2 && $0.arguments[0] == "simctl" ? $0.arguments[1] : nil }
        #expect(verbs.contains("boot") && verbs.contains("bootstatus"))
        #expect(verbs.firstIndex(of: "boot")! < verbs.firstIndex(of: "bootstatus")!)
    }

    @Test func bootingAnAlreadyBootedSimulatorDoesNothing() async throws {
        let runner = try listingRunner()
        let booted = try #require(try DeviceParsers.parseSimctlDevices(try fixture("simctl-list-devices.json")).first { $0.state == .booted })
        let message = try await makeService(runner).boot(id: booted.id)
        #expect(message.contains("already booted"))
        #expect(!runner.calls.contains { $0.arguments.prefix(2) == ["simctl", "boot"] })
    }

    @Test func aPhysicalAndroidDeviceCannotBeBootedOrShutDown() async throws {
        let service = makeService(try listingRunner())
        await #expect(throws: DeviceError.self) { _ = try await service.boot(id: "R5CT1234ABC") }
        await #expect(throws: DeviceError.self) { _ = try await service.shutdown(id: "R5CT1234ABC") }
    }

    @Test func androidBootSpawnsTheEmulatorWithTheAVDName() async throws {
        let runner = try listingRunner()
        let base = runner.responder
        // After the spawn the emulator shows up in `adb devices` and reports boot_completed.
        runner.responder = { exe, args in
            if exe == fakeADB, args == ["devices"] { return ok("List of devices attached\nemulator-5556\tdevice\n") }
            if exe == fakeADB, args.contains("emu"), args.contains("emulator-5556") { return ok("OpenCamp_QA\nOK\n") }
            if exe == fakeADB, args.contains("sys.boot_completed"), !args.contains("emulator-5556") { return ok("0\n") }
            if exe == fakeADB, args.contains("sys.boot_completed") { return ok("1\n") }
            return base(exe, args)
        }
        let message = try await makeService(runner).boot(id: "avd:OpenCamp_QA", waitSeconds: 10)
        #expect(message.contains("emulator-5556"))
        #expect(runner.spawned == [.init(executable: fakeEmulator, arguments: ["-avd", "OpenCamp_QA", "-no-snapshot-save"])])
    }

    @Test func screenshotsCommandsPerPlatform() async throws {
        let runner = try listingRunner()
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 2, 0, 0, 0, 4, 0])
        let base = runner.responder
        let image = png
        runner.responder = { exe, args in
            if args.contains("screencap") { return CommandResult(status: 0, stdout: image, stderr: "") }
            // simctl writes the picture to the file path it is given (the last argument).
            if args.contains("screenshot"), let path = args.last { try? image.write(to: URL(fileURLWithPath: path)); return ok() }
            return base(exe, args)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-shot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = makeService(runner, captures: dir)
        let android = try await service.screenshot(id: "emulator-5554")
        #expect(android.width == 512 && android.height == 1024 && FileManager.default.fileExists(atPath: android.url.path))
        #expect(runner.calls.contains { $0.executable == fakeADB && $0.arguments == ["-s", "emulator-5554", "exec-out", "screencap", "-p"] })
        let booted = try #require(try DeviceParsers.parseSimctlDevices(try fixture("simctl-list-devices.json")).first { $0.state == .booted })
        _ = try await service.screenshotData(id: booted.id)
        #expect(runner.calls.contains { $0.arguments.prefix(5) == ["simctl", "io", booted.id, "screenshot", "--type=png"] })
    }

    @Test func aScreenshotOfAShutdownDeviceSaysToBootIt() async throws {
        let service = makeService(try listingRunner())
        await #expect(throws: DeviceError.notBooted("OpenCamp QA")) { _ = try await service.screenshotData(id: "avd:OpenCamp_QA") }
    }

    @Test func notFoundNamesTheId() async throws {
        let service = makeService(try listingRunner())
        await #expect(throws: DeviceError.notFound("nope")) { _ = try await service.screenshotData(id: "nope") }
    }

    @Test func installAndLaunchValidateBeforeTouchingTheDevice() async throws {
        let runner = try listingRunner()
        let service = makeService(runner)
        await #expect(throws: DeviceError.self) { _ = try await service.install(id: "emulator-5554", path: "/does/not/exist.apk") }
        await #expect(throws: DeviceError.self) { _ = try await service.launch(id: "emulator-5554", app: "com.x; rm -rf /") }
        await #expect(throws: DeviceError.self) { _ = try await service.openURL(id: "emulator-5554", url: "not a url") }
        #expect(!runner.calls.contains { $0.arguments.contains("install") || $0.arguments.contains("monkey") || $0.arguments.contains("VIEW") })
    }

    @Test func androidOpenURLIsShellQuoted() async throws {
        let runner = try listingRunner()
        let base = runner.responder
        runner.responder = { exe, args in args.contains("am") ? ok("Starting: Intent\n") : base(exe, args) }
        _ = try await makeService(runner).openURL(id: "emulator-5554", url: "https://x.test/a?b=1&c='2'")
        let call = try #require(runner.calls.last { $0.arguments.contains("am") })
        #expect(call.arguments.last == "'https://x.test/a?b=1&c='\\''2'\\'''")
    }

    @Test func appleInputIsReportedUnsupportedNotFaked() async throws {
        let runner = try listingRunner()
        let booted = try #require(try DeviceParsers.parseSimctlDevices(try fixture("simctl-list-devices.json")).first { $0.state == .booted })
        await #expect(throws: DeviceError.unsupported(DeviceService.appleInputUnsupported)) {
            _ = try await makeService(runner).send(id: booted.id, input: .tap(x: 1, y: 1))
        }
    }

    @Test func androidInputBuildsAdbShellCommands() throws {
        #expect(try DeviceService.adbInputArguments(.tap(x: 10, y: 20)) == ["input", "tap", "10", "20"])
        #expect(try DeviceService.adbInputArguments(.swipe(x1: 1, y1: 2, x2: 3, y2: 4, durationMs: 1)) == ["input", "swipe", "1", "2", "3", "4", "50"])
        #expect(try DeviceService.adbInputArguments(.text("hi there")) == ["input", "text", "'hi%sthere'"])
        #expect(try DeviceService.adbInputArguments(.key("KEYCODE_HOME")) == ["input", "keyevent", "KEYCODE_HOME"])
        #expect(throws: DeviceError.self) { try DeviceService.adbInputArguments(.key("HOME; reboot")) }
        #expect(throws: DeviceError.self) { try DeviceService.adbInputArguments(.tap(x: -1, y: 0)) }
        #expect(throws: DeviceError.self) { try DeviceService.adbInputArguments(.text("")) }
    }

    @Test func recordingRejectsOutOfRangeDurations() async throws {
        let service = makeService(try listingRunner())
        for seconds in [0, -3, 181] {
            await #expect(throws: DeviceError.self) { _ = try await service.recordVideo(id: "emulator-5554", seconds: seconds) }
        }
    }

    @Test func logTailKeepsTheEndAndFilters() {
        let text = (1...10).map { "line \($0) \($0 % 2 == 0 ? "ERROR" : "info")" }.joined(separator: "\n")
        #expect(DeviceService.tail(text, lines: 2, contains: nil) == "line 9 info\nline 10 ERROR")
        #expect(DeviceService.tail(text, lines: 2, contains: "error") == "line 8 ERROR\nline 10 ERROR")
    }
}

@Suite("Device tools")
struct DeviceToolSpecTests {
    private func spec(_ kind: DeviceAgentTools.Kind) -> ToolSpec { kind.spec }

    @Test func everyToolIsPrefixedAndNamedAfterItsKind() {
        for kind in DeviceAgentTools.Kind.allCases {
            #expect(kind.spec.name == "device_" + kind.rawValue)
            #expect(ExecutionPolicy.isModuleTool(kind.spec.name))
            #expect(!kind.spec.summary.isEmpty)
        }
    }

    @Test func permissionLevelsMatchWhatEachToolChanges() {
        // Reading and screenshots are read-level.
        for kind in [DeviceAgentTools.Kind.list, .status, .screenshot, .logs] { #expect(spec(kind).permission == .read) }
        // Starting, stopping, installing and launching are execute-level.
        for kind in [DeviceAgentTools.Kind.boot, .shutdown, .install, .launch] { #expect(spec(kind).permission == .execute) }
        // Other things that change what a device shows or records are write-level.
        for kind in [DeviceAgentTools.Kind.openURL, .input, .recordVideo] { #expect(spec(kind).permission == .write) }
    }

    @Test func deviceToolsAreOfferedByNameWildcardAndGatedByMode() {
        let set = ToolPermissionSet(enabledTools: ["device_*"])
        #expect(DeviceAgentTools.Kind.allCases.allSatisfy { set.isEnabled($0.spec.name) })
        var readOnly = ExecutionPolicy(mode: .review, requiredApprovals: [])
        readOnly.toolsAllowed = []
        let registry = ToolRegistry()
        for kind in DeviceAgentTools.Kind.allCases { registry.register(DeviceAgentTool(kind: kind, service: DeviceService(runner: FakeRunner()))) }
        let offered = Set(readOnly.offeredTools(from: registry, permissions: set, workspaceRoot: nil).map(\.name))
        #expect(offered.contains("device_list") && offered.contains("device_screenshot"))
        #expect(!offered.contains("device_boot") && !offered.contains("device_install") && !offered.contains("device_input"))
    }

    @Test func workstationAgentGetsDeviceTools() {
        let profile = AgentProfile.builtIns.first { $0.name == "Workstation Agent" }
        #expect(profile?.toolPermissions.isEnabled("device_boot") == true)
        let research = AgentProfile.builtIns.first { $0.name == "Research Assistant" }
        #expect(research?.toolPermissions.isEnabled("device_boot") != true)
    }

    @Test func requiredArgumentsAreEnforcedBeforeAnyCommandRuns() async throws {
        let runner = FakeRunner()
        let tool = DeviceAgentTool(kind: .launch, service: DeviceService(runner: runner))
        await #expect(throws: DeviceError.self) { _ = try await tool.execute(argumentsJSON: #"{"device_id":"x"}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())) }
        await #expect(throws: DeviceError.self) { _ = try await tool.execute(argumentsJSON: "{}", context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())) }
        #expect(runner.calls.isEmpty)
    }
}
