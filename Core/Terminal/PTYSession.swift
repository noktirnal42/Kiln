import Foundation
import Darwin

public enum TerminalError: Error, Equatable, Sendable {
    case shellNotFound(String)
    case workspaceRootInvalid(String)
    case ptyAllocationFailed
    case sessionClosed
    case resizeFailed
}

public struct CommandHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var line: String
    public var timestamp: Date

    public init(line: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.line = line
        self.timestamp = timestamp
    }
}

/// One live pseudoterminal. The PTY master is allocated with
/// posix_openpt/grantpt/unlockpt and the slave is handed to Foundation's
/// Process as stdin/stdout/stderr — no manual fork. Read callbacks use an
/// explicit lock (never an actor) per the project's process-callback rule.
public final class PTYSession: @unchecked Sendable {
    public let id: UUID
    public let shell: String
    public let workingDirectory: String
    public private(set) var isRunning: Bool

    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?
    private var dataSink: (@Sendable (Data) -> Void)?
    private var terminationSink: (@Sendable (Int32) -> Void)?
    private var buffer: [UInt8] = []
    private static let bufferLimit = 1 << 20

    public init(shell: String, workingDirectory: String) {
        self.id = UUID()
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.isRunning = false
    }

    public func start(environment: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard masterFD == -1 else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalError.workspaceRootInvalid(workingDirectory)
        }
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw TerminalError.shellNotFound(shell)
        }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw TerminalError.ptyAllocationFailed }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            Darwin.close(master)
            throw TerminalError.ptyAllocationFailed
        }
        var slaveName = [CChar](repeating: 0, count: 256)
        guard ptsname_r(master, &slaveName, slaveName.count) == 0 else {
            Darwin.close(master)
            throw TerminalError.ptyAllocationFailed
        }
        let slavePath = String(decoding: slaveName.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let slaveFD = open(slavePath, O_RDWR)
        guard slaveFD >= 0 else {
            Darwin.close(master)
            throw TerminalError.ptyAllocationFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isRunning = false
            let sink = self.terminationSink
            self.lock.unlock()
            sink?(self.process?.terminationStatus ?? 0)
        }

        do {
            try process.run()
        } catch {
            Darwin.close(master)
            Darwin.close(slaveFD)
            throw TerminalError.shellNotFound("\(shell): \(error.localizedDescription)")
        }

        self.process = process
        self.masterFD = master
        self.isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "com.kiln.pty.\(id.uuidString)"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(self.masterFD, &chunk, chunk.count)
            guard bytesRead > 0 else {
                if bytesRead == 0 { self.handleEOF() }
                return
            }
            let data = Data(chunk.prefix(bytesRead))
            self.lock.lock()
            self.buffer.append(contentsOf: data)
            if self.buffer.count > Self.bufferLimit {
                self.buffer.removeFirst(self.buffer.count - Self.bufferLimit)
            }
            let sink = self.dataSink
            self.lock.unlock()
            sink?(data)
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.masterFD
            self.masterFD = -1
            self.lock.unlock()
            if fd >= 0 { Darwin.close(fd) }
        }
        source.resume()
        self.readSource = source
    }

    private func handleEOF() {
        lock.lock()
        isRunning = false
        let sink = terminationSink
        lock.unlock()
        sink?(process?.terminationStatus ?? 0)
    }

    public func write(_ data: Data) {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    public func resize(rows: UInt16, columns: UInt16) throws {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { throw TerminalError.sessionClosed }
        var win = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(fd, UInt(TIOCSWINSZ), &win) == 0 else {
            throw TerminalError.resizeFailed
        }
    }

    public func onData(_ sink: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        dataSink = sink
        let buffered = buffer
        lock.unlock()
        if !buffered.isEmpty {
            sink(Data(buffered))
        }
    }

    public func onTermination(_ sink: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        terminationSink = sink
        lock.unlock()
    }

    public func close() {
        lock.lock()
        let process = self.process
        let source = readSource
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
        source?.cancel()
    }

    public func exitStatus() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, !process.isRunning else { return nil }
        return process.terminationStatus
    }
}

/// Shell detection: first executable of zsh/bash/fish on PATH, zsh default on macOS.
public enum ShellDetection {
    public static func detectShell() -> String {
        let candidates = ["/bin/zsh", "/bin/bash", "/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("fish").path }
        for candidate in candidates + extra where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/bin/zsh"
    }

    public static func availableShells() -> [String] {
        var shells: [String] = []
        for candidate in ["/bin/zsh", "/bin/bash", "/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            shells.append(candidate)
        }
        return shells
    }
}
