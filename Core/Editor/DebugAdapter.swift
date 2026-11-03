import Foundation
import Darwin

public struct DebugFrame: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var path: String?
    public var line: Int
    public var column: Int
}

public struct DebugVariable: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var value: String
    public var type: String?
}

/// Pure parsing of LLDB's command-line output, so the debugger's behaviour can be tested without a process.
public enum LLDBOutput {
    /// `frame #0: compute(n=20) at /path/main.swift:3:25` (also the `* frame #0` form `bt` prints for the selected frame).
    public static func frame(_ line: String) -> DebugFrame? {
        let pattern = #"^\s*\*?\s*frame #(\d+): (.+?)(?: at (.+?):(\d+)(?::(\d+))?)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let index = Range(match.range(at: 1), in: line), let name = Range(match.range(at: 2), in: line),
              let id = Int(line[index]) else { return nil }
        func group(_ n: Int) -> String? { Range(match.range(at: n), in: line).map { String(line[$0]) } }
        return DebugFrame(id: id, name: String(line[name]), path: group(3), line: group(4).flatMap(Int.init) ?? 0,
                          column: group(5).flatMap(Int.init) ?? 0)
    }

    /// `(Int) doubled = 40`
    public static func variable(_ line: String) -> DebugVariable? {
        let pattern = #"^\((.+?)\) (\S+) = (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let type = Range(match.range(at: 1), in: line), let name = Range(match.range(at: 2), in: line),
              let value = Range(match.range(at: 3), in: line) else { return nil }
        return DebugVariable(name: String(line[name]), value: String(line[value]), type: String(line[type]))
    }

    /// `Process 28010 exited with status = 0 (0x00000000)` → 0
    public static func exitStatus(_ line: String) -> Int? {
        guard line.hasPrefix("Process "), let range = line.range(of: "exited with status = ") else { return nil }
        return Int(line[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    /// `Breakpoint 1: where = …` → 1
    public static func breakpointID(_ line: String) -> Int? {
        guard line.hasPrefix("Breakpoint "), let colon = line.firstIndex(of: ":") else { return nil }
        return Int(line["Breakpoint ".endIndex..<colon])
    }

    /// `* thread #1, queue = '…', stop reason = breakpoint 1.1` → "breakpoint 1.1"
    public static func stopReason(_ line: String) -> String? {
        guard line.contains("thread #"), let range = line.range(of: "stop reason = ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

/// A debugger over the `lldb` command line from the Xcode toolchain: launch a built executable, set breakpoints, run to
/// them, step, and read the call stack, locals and program output. (The Debug Adapter Protocol server, `lldb-dap`, was
/// tried first; with this toolchain it neither resolved breakpoints after launching nor reliably reported stops.)
/// Breakpoint lines are 1-based.
@MainActor @Observable
public final class DebugSession {
    public enum State: Equatable, Sendable { case idle, starting, running, paused(reason: String), finished(exitCode: Int?), failed(String) }

    public private(set) var state: State = .idle
    public private(set) var frames: [DebugFrame] = []
    public private(set) var variables: [DebugVariable] = []
    public private(set) var console = ""
    public private(set) var selectedFrameID: Int?
    public var breakpoints: [String: Set<Int>] = [:] {
        didSet { reconcileSoon() }
    }

    /// Where execution is stopped (the selected frame, or the first with source), for highlighting in the editor.
    public var currentLocation: (path: String, line: Int)? {
        guard let frame = frames.first(where: { $0.id == selectedFrameID }) ?? frames.first(where: { $0.path != nil }),
              let path = frame.path else { return nil }
        return (path, frame.line)
    }

    public var isActive: Bool {
        switch state { case .starting, .running, .paused: true; default: false }
    }
    public var isPaused: Bool { if case .paused = state { true } else { false } }

    private let command: String
    private var process: Process?
    private var input: FileHandle?
    private var pendingText = ""
    private enum Section { case none, backtrace, variables }
    private var section: Section = .none
    private var lastEchoed = ""
    private var expectStopReasonLine = false
    private var stopReason = "paused"
    private var applied: [String: [Int: Int]] = [:]       // path → line → lldb breakpoint id
    private var awaitingBreakpoints: [(path: String, line: Int)] = []
    private var generation = UUID()
    private var program = ""
    private var launched = false

    public init(command: String = "xcrun lldb --no-lldbinit") {
        self.command = command
    }

    public nonisolated static let isAvailable: Bool = {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["--find", "lldb"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run(); probe.waitUntilExit() } catch { return false }
        return probe.terminationStatus == 0
    }()

    // MARK: Lifecycle

    /// Starts the program under the debugger. It runs until a breakpoint (or `stopOnEntry`) pauses it.
    public func start(program: String, arguments: [String] = [], workingDirectory: URL, stopOnEntry: Bool = false) async {
        guard !isActive else { return }
        disposeDebugger()
        let generation = UUID()
        self.generation = generation
        signal(SIGPIPE, SIG_IGN)      // writing a command to a debugger that just exited must not kill Kiln
        frames = []; variables = []; console = ""; selectedFrameID = nil
        section = .none; pendingText = ""; applied = [:]; awaitingBreakpoints = []; launched = false
        self.program = program
        state = .starting
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \(command) \(Self.quote(program))"]
        process.currentDirectoryURL = workingDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.receive(text)
            }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.generation == generation else { return }
            self.ended()
        } }
        do { try process.run() } catch {
            state = .failed("Could not start lldb: \(error.localizedDescription)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        // Show full source paths and no source listing in stop messages, so locations can be parsed and opened.
        send(#"settings set frame-format "frame #${frame.index}: ${function.name-with-args}{ at ${line.file.fullpath}:${line.number}:${line.column}}\n""#)
        send("settings set stop-line-count-before 0")
        send("settings set stop-line-count-after 0")
        send("settings set auto-confirm true")
        reconcile()
        let argumentText = arguments.map(Self.quote).joined(separator: " ")
        if stopOnEntry { send("process launch --stop-at-entry" + (arguments.isEmpty ? "" : " -- " + argumentText)) }
        else { send("process launch" + (arguments.isEmpty ? "" : " -- " + argumentText)) }
        // Return once the program is running (or has stopped, or the debugger failed to start).
        for _ in 0..<600 where state == .starting && self.generation == generation {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if self.generation == generation, state == .starting {
            failLaunch("lldb did not start the program within 30 seconds.")
        }
    }

    public func stop() async {
        // Invalidate callbacks before another session can start. Cleanup always targets this process.
        let stopped = process
        reset()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if stopped?.isRunning == true { stopped?.terminate() }
    }

    /// Ends the old project session immediately before loading another project's breakpoints.
    public func reset() {
        send("process kill")
        send("quit")
        disposeDebugger()
        state = .finished(exitCode: nil)
        frames = []; variables = []; selectedFrameID = nil
    }

    private func disposeDebugger() {
        generation = UUID()
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        input = nil
        process = nil
    }

    private func failLaunch(_ message: String) {
        console += message + "\n"
        disposeDebugger()
        state = .failed(message)
    }

    private func ended() {
        disposeDebugger()
        if isActive { state = launched ? .finished(exitCode: nil) : .failed("lldb exited before the program started.") }
    }

    /// Foundation deliberately shortens /private/tmp aliases; debug info retains the POSIX real path.
    public nonisolated static func canonicalSourcePath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Controls

    public func resume() async { go("process continue") }
    public func stepOver() async { go("thread step-over") }
    public func stepInto() async { go("thread step-in") }
    public func stepOut() async { go("thread step-out") }
    /// Stops a running program (SIGINT to lldb, which interrupts the process).
    public func pause() async { if case .running = state { process?.interrupt() } }

    private func go(_ command: String) {
        guard isPaused else { return }
        state = .running
        frames = []; variables = []
        send(command)
    }

    public func selectFrame(_ id: Int) async {
        selectedFrameID = id
        variables = []
        send("frame select \(id)")
        send("frame variable")
    }

    public func toggleBreakpoint(path: String, line: Int) {
        var lines = breakpoints[path] ?? []
        if lines.contains(line) { lines.remove(line) } else { lines.insert(line) }
        breakpoints[path] = lines.isEmpty ? nil : lines
    }

    // MARK: Breakpoint sync

    private func reconcileSoon() {
        guard process != nil else { return }
        // lldb reads commands only while the process is stopped; changes made while it runs apply at the next stop.
        if state == .starting || isPaused { reconcile() }
    }

    private func reconcile() {
        for path in breakpoints.keys.sorted() {
            let lines = breakpoints[path] ?? []
            // Match the complete source path: basenames can refer to several targets' main.swift files.
            let name = Self.canonicalSourcePath(path)
            for line in lines.sorted() where applied[path]?[line] == nil
                && !awaitingBreakpoints.contains(where: { $0.path == path && $0.line == line }) {
                applied[path, default: [:]][line] = -1
                awaitingBreakpoints.append((path, line))
                send("breakpoint set -f \(Self.quote(name)) -l \(line)")
            }
        }
        for (path, byLine) in applied {
            for (line, id) in byLine where !(breakpoints[path]?.contains(line) ?? false) {
                if id > 0 { send("breakpoint delete \(id)") }
                applied[path]?[line] = nil
            }
        }
    }

    private func send(_ text: String) {
        try? input?.write(contentsOf: Data((text + "\n").utf8))
    }

    // MARK: Output

    private func receive(_ text: String) {
        pendingText += text
        var lines = pendingText.components(separatedBy: "\n")
        pendingText = lines.removeLast()          // a partial last line (usually the "(lldb) " prompt)
        for line in lines { handle(line.replacingOccurrences(of: "\r", with: "")) }
    }

    private func handle(_ line: String) {
        // The prompt echoes each command we send; it tells us which output section follows.
        if line.hasPrefix("(lldb) ") {
            let echoed = String(line.dropFirst(7))
            lastEchoed = echoed
            if echoed == "bt" || echoed.hasPrefix("thread backtrace") { section = .backtrace }
            else if echoed.hasPrefix("frame variable") { section = .variables }
            else { section = .none }
            return
        }
        if line.hasPrefix("Process "), line.contains(" launched:") {
            launched = true
            if case .starting = state { state = .running }
            return
        }
        if line.hasPrefix("Process "), line.hasSuffix(" stopped") {
            expectStopReasonLine = true
            return
        }
        if let status = LLDBOutput.exitStatus(line) {
            state = .finished(exitCode: status)
            frames = []; variables = []
            send("quit")
            return
        }
        if line.hasPrefix("Process "), line.contains(" resuming") { return }
        if let id = LLDBOutput.breakpointID(line), !awaitingBreakpoints.isEmpty {
            let waiting = awaitingBreakpoints.removeFirst()
            if breakpoints[waiting.path]?.contains(waiting.line) == true {
                applied[waiting.path, default: [:]][waiting.line] = id
            } else {
                // The user can remove a breakpoint before LLDB acknowledges its creation.
                send("breakpoint delete \(id)")
                applied[waiting.path]?[waiting.line] = nil
            }
            return
        }
        if line.hasPrefix("error:") {
            if lastEchoed.hasPrefix("breakpoint set"), !awaitingBreakpoints.isEmpty {
                let waiting = awaitingBreakpoints.removeFirst()
                applied[waiting.path]?[waiting.line] = nil
            } else if state == .starting {
                failLaunch(line)
                return
            }
        }
        if expectStopReasonLine, let reason = LLDBOutput.stopReason(line) {
            stopReason = reason
            return
        }
        if expectStopReasonLine, LLDBOutput.frame(line) != nil {
            // The stop block's own frame line: we are paused. Fetch the stack and locals (and apply queued breakpoint edits).
            expectStopReasonLine = false
            state = .paused(reason: stopReason)
            frames = []; variables = []; selectedFrameID = nil
            reconcile()
            send("bt")
            send("frame variable")
            return
        }
        if line.hasPrefix("Target 0:") && line.hasSuffix("stopped.") { return }
        switch section {
        case .backtrace:
            if let frame = LLDBOutput.frame(line) {
                frames.append(frame)
                if line.contains("* frame") || selectedFrameID == nil, frame.path != nil, selectedFrameID == nil || line.contains("* frame") {
                    selectedFrameID = line.contains("* frame") ? frame.id : (selectedFrameID ?? frame.id)
                }
            }
        case .variables:
            if let variable = LLDBOutput.variable(line) {
                variables.append(variable)
            } else if line.hasPrefix(" "), !variables.isEmpty {
                // Nested members of a struct/collection continue the previous value.
                variables[variables.count - 1].value += "\n" + line.trimmingCharacters(in: .whitespaces)
            }
        case .none:
            if !line.isEmpty, !line.hasPrefix("Current executable set to"), !line.hasPrefix("Breakpoint "), !line.hasPrefix("* thread #"),
               !line.hasPrefix("Executable module set to"), !line.hasPrefix("Target 0:"), !line.hasPrefix("  Locations") {
                console += line + "\n"
                if console.count > 200_000 { console = String(console.suffix(150_000)) }
            }
        }
    }
}
