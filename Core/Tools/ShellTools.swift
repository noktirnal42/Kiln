import Foundation

/// Heuristics for flagging a shell command as destructive, so the approval
/// sheet can warn loudly instead of showing every command identically.
///
/// This is a safety *signal*, not a sandbox. It does not block anything by
/// itself — the execution policy's block patterns and the approval gate are
/// what actually stop execution.
public enum CommandSafety {
    public static func isDestructive(_ command: String) -> Bool {
        destructiveReason(command) != nil
    }

    /// A short human-readable consequence, or nil for an ordinary command.
    public static func destructiveReason(_ command: String) -> String? {
        let lower = command.lowercased()
        if lower.contains("rm ") && (lower.contains("-rf") || lower.contains("-fr")) {
            return "Recursively deletes files without confirmation."
        }
        if lower.contains("sudo") { return "Requests elevated privileges." }
        if lower.contains("git push") && (lower.contains("--force") || lower.contains(" -f")) {
            return "Force-pushes, which can overwrite remote history."
        }
        if lower.contains("git reset --hard") { return "Discards uncommitted local changes." }
        if lower.contains("git clean") { return "Deletes untracked files." }
        if lower.contains("curl") && (lower.contains("| sh") || lower.contains("| bash")) {
            return "Pipes a remote script directly into a shell."
        }
        if lower.contains("mkfs") || lower.contains("diskutil erase") { return "Reformats a disk." }
        if lower.contains("shutdown") || lower.contains("reboot") { return "Restarts or shuts down the Mac." }
        if lower.contains(":(){") { return "A fork bomb." }
        return nil
    }
}

// MARK: - Background job store

/// Output and lifecycle for a shell command started in the background.
/// Captured to a file so the run survives process reaps.
public final class BackgroundJob: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let command: String
    public let process: Process
    public let outputURL: URL
    private let lock = NSLock()
    private var _exitStatus: Int32?

    init(command: String, process: Process, outputURL: URL) {
        self.command = command
        self.process = process
        self.outputURL = outputURL
    }

    public var exitStatus: Int32? {
        lock.lock(); defer { lock.unlock() }
        if process.isRunning { return nil }
        return process.terminationStatus
    }

    public var isRunning: Bool { process.isRunning }

    public func output() -> String {
        guard let text = try? String(contentsOf: outputURL, encoding: .utf8) else { return "" }
        return String(text.suffix(8_000))
    }
}

public actor BackgroundJobStore {
    public static let shared = BackgroundJobStore()
    private var jobs: [UUID: BackgroundJob] = [:]

    public func add(_ job: BackgroundJob) {
        jobs[job.id] = job
    }

    public func find(_ id: UUID) -> BackgroundJob? {
        jobs[id]
    }

    public func all() -> [BackgroundJob] {
        jobs.values.sorted { $0.command < $1.command }
    }

    public func pruneFinished() {
        jobs = jobs.filter { $0.value.isRunning || $0.value.exitStatus == nil }
    }
}

// MARK: - Shell process runner

enum ShellRunner {
    struct Result: Sendable {
        var output: String
        var exitStatus: Int32
        var timedOut: Bool
    }

    static func makeProcess(command: String, cwd: URL?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = cwd }
        return process
    }

    /// Runs to completion, capturing combined stdout+stderr. `timeout`
    /// kills the process and returns what was captured so far.
    static func run(
        command: String,
        cwd: URL?,
        timeout: TimeInterval,
        trimOutput: Bool = true
    ) async throws -> Result {
        let process = makeProcess(command: command, cwd: cwd)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out

        let collector = OutputCollector(pipe: out)
        // Wait for exit with the termination handler rather than a blocking `waitUntilExit()` on a pool thread: when many
        // commands run at once (parallel tests on a loaded runner) blocked threads starved the pool and a trivial command
        // was reported as timed out.
        let startError = StartErrorBox()
        let finished: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let state = TimeoutRaceState(continuation)
            process.terminationHandler = { _ in state.finish(true) }
            do { try process.run() } catch { startError.error = error; state.finish(true); return }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                state.finish(false)
            }
        }
        if let error = startError.error {
            throw AgentRunError.permissionDenied("Could not start the command: \(error.localizedDescription)")
        }
        let timedOut = !finished
        if timedOut && process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 300_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // After a timeout or Stop a grandchild (pip, a dev server) can keep the pipe open, so reading to EOF
        // would block forever; take what is there instead.
        var output = timedOut ? collector.collectAvailable() : collector.collect()
        if trimOutput {
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if timedOut {
            output += "\n[command exceeded \(Int(timeout))s and was terminated]"
        }
        // terminationStatus raises an Objective-C exception (a crash) while the task is still running.
        return Result(output: output, exitStatus: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut)
    }

    /// Launches detached; output accumulates in a file the job owns.
    static func launchBackground(command: String, cwd: URL?) throws -> BackgroundJob {
        let process = makeProcess(command: command, cwd: cwd)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-job-\(UUID().uuidString).log")
        let handle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return BackgroundJob(command: command, process: process, outputURL: outputURL)
    }
}

/// Carries a launch failure out of the continuation closure.
final class StartErrorBox: @unchecked Sendable { var error: Error? }

/// Collects pipe output off the reading thread without blocking the caller.
/// `Pipe` buffers internally, so draining lazily on collect is enough for
/// the volumes a tool produces.
final class OutputCollector: @unchecked Sendable {
    private let pipe: Pipe

    init(pipe: Pipe) { self.pipe = pipe }

    /// Non-blocking drain: returns what is already in the pipe without waiting for EOF.
    func collectAvailable() -> String {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? "(non-UTF-8 output)"
    }

    func collect() -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "(non-UTF-8 output)"
    }
}

// MARK: - Shell tools

public struct RunCommandTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var command: String
        public var timeout: Double?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "run_command",
            summary: "Run a shell command and return its output",
            detail: "Runs in the workspace with zsh. Use for quick commands (builds, git, file inspection). Default timeout 120s.",
            parameters: [
                ToolParam(name: "command", type: "string", description: "The command line to run", required: true),
                ToolParam(name: "timeout", type: "number", description: "Seconds before the command is killed (default 120)", required: false),
            ],
            permission: .execute,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let result = try await ShellRunner.run(
            command: args.command,
            cwd: root,
            timeout: min(args.timeout ?? 120, 600)
        )
        var text = result.output.isEmpty ? "(no output)" : result.output
        text += "\n[exit \(result.exitStatus)]"
        return ToolOutputCap.fit(text, from: "run_command")
    }
}

public struct StreamCommandTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var command: String
        public var timeout: Double?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "stream_command",
            summary: "Run a long-running command to completion",
            detail: "Like run_command but waits up to 10 minutes for commands that produce output over time (watchers, dev servers run once, long builds).",
            parameters: [
                ToolParam(name: "command", type: "string", description: "The command line to run", required: true),
                ToolParam(name: "timeout", type: "number", description: "Seconds before the command is killed (default 600, max 600)", required: false),
            ],
            permission: .execute,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let result = try await ShellRunner.run(
            command: args.command,
            cwd: root,
            timeout: min(args.timeout ?? 600, 600)
        )
        var text = result.output.isEmpty ? "(no output)" : result.output
        text += "\n[exit \(result.exitStatus)]"
        return ToolOutputCap.fit(text, from: "stream_command")
    }
}

public struct BackgroundCommandTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var command: String
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "background_command",
            summary: "Start a command in the background and return immediately",
            detail: "Returns a job id; read its output later with read_command_output.",
            parameters: [
                ToolParam(name: "command", type: "string", description: "The command line to run detached", required: true),
            ],
            permission: .execute,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let job = try ShellRunner.launchBackground(command: args.command, cwd: root)
        await BackgroundJobStore.shared.add(job)
        return "Started job \(job.id.uuidString) in the background. Read its output with read_command_output."
    }
}

public struct ReadCommandOutputTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var jobID: String
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "read_command_output",
            summary: "Read the output of a background command",
            detail: "Returns what the job has printed so far and whether it is still running.",
            parameters: [
                ToolParam(name: "jobID", type: "string", description: "The job id background_command returned", required: true),
            ],
            permission: .read
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        guard let id = UUID(uuidString: args.jobID),
              let job = await BackgroundJobStore.shared.find(id) else {
            throw AgentRunError.permissionDenied("No background job with id '\(args.jobID)'.")
        }
        var text = job.output()
        if job.isRunning {
            text += "\n[still running]"
        } else {
            text += "\n[exit \(job.exitStatus ?? -1)]"
            await BackgroundJobStore.shared.pruneFinished()
        }
        return ToolOutputCap.fit(text, from: "read_command_output")
    }
}
