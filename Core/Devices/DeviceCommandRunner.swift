import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

/// Runs an executable and returns what it wrote. Injected so the service can be tested without Xcode or an SDK.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
    /// Starts the executable, lets it run for `duration`, then interrupts it (SIGINT) and waits for it to finish
    /// writing. For `simctl io recordVideo`, which only finalises its file when interrupted.
    func runInterrupted(_ executable: String, _ arguments: [String], after duration: TimeInterval) async throws -> CommandResult
    /// Starts the executable and returns immediately, leaving it running (a booting emulator).
    func spawnDetached(_ executable: String, _ arguments: [String]) throws
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var _timedOut = false
        var timedOut: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _timedOut }
            set { lock.lock(); _timedOut = newValue; lock.unlock() }
        }
        func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
        func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
        func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await execute(executable, arguments, interruptAfter: nil, killAfter: timeout)
    }

    public func runInterrupted(_ executable: String, _ arguments: [String], after duration: TimeInterval) async throws -> CommandResult {
        try await execute(executable, arguments, interruptAfter: duration, killAfter: duration + 30)
    }

    public func spawnDetached(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func execute(_ executable: String, _ arguments: [String], interruptAfter: TimeInterval?, killAfter: TimeInterval) async throws -> CommandResult {
        let label = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outPipe
                process.standardError = errPipe
                let capture = Capture()
                let group = DispatchGroup()
                do { try process.run() } catch {
                    continuation.resume(throwing: DeviceError.commandFailed("Starting \(label)", status: -1, output: error.localizedDescription))
                    return
                }
                group.enter()
                DispatchQueue.global().async { capture.setOut(outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.enter()
                DispatchQueue.global().async { capture.setErr(errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }

                if let interruptAfter {
                    DispatchQueue.global().asyncAfter(deadline: .now() + interruptAfter) { if process.isRunning { process.interrupt() } }
                }
                let killer = DispatchWorkItem { if process.isRunning { capture.timedOut = true; process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + killAfter, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                group.wait()
                if capture.timedOut {
                    continuation.resume(throwing: DeviceError.timedOut(label))
                    return
                }
                let (out, err) = capture.snapshot()
                continuation.resume(returning: CommandResult(status: process.terminationStatus, stdout: out,
                                                             stderr: String(decoding: err, as: UTF8.self)))
            }
        }
    }
}

/// Finds the Apple and Android command-line tools. Pure over its inputs so tests can pass a fake file system.
public struct DeviceToolLocator: Sendable {
    public var environment: [String: String]
    public var home: String
    public var isExecutable: @Sendable (String) -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory(),
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.environment = environment; self.home = home; self.isExecutable = isExecutable
    }

    public static let xcrunPath = "/usr/bin/xcrun"

    /// SDK roots in the order Android's own tooling prefers them.
    public var androidSDKRoots: [String] {
        var roots: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[key], !value.isEmpty { roots.append(value) }
        }
        roots.append("\(home)/Library/Android/sdk")
        roots.append("/opt/homebrew/share/android-commandlinetools")
        roots.append("/usr/local/share/android-commandlinetools")
        return roots
    }

    public func adbPath() -> String? { find("adb", sdkSubfolder: "platform-tools") }
    public func emulatorPath() -> String? { find("emulator", sdkSubfolder: "emulator") }

    private func find(_ tool: String, sdkSubfolder: String) -> String? {
        for root in androidSDKRoots {
            let candidate = "\(root)/\(sdkSubfolder)/\(tool)"
            if isExecutable(candidate) { return candidate }
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in pathDirs {
            let candidate = "\(dir)/\(tool)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
