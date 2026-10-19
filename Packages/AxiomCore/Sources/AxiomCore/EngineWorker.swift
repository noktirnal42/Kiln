import Foundation

/// Events a worker emits outside request/response pairs (see docs/ENGINE_WORKER.md).
public enum WorkerEvent: Sendable, Equatable {
    case ready
    case progress(phase: String, fraction: Double?)
    case log(String)
    /// An `AXIOM` event the client does not know yet; forwarded rather than dropped.
    case other(name: String)
    case exited(status: Int32)
}

public enum WorkerError: LocalizedError, Equatable {
    case notRunning, timedOut(String), cancelled, exited(Int32), remote(String), protocolViolation(String)
    public var errorDescription: String? {
        switch self {
        case .notRunning: "The engine worker is not running."
        case .timedOut(let method): "The engine worker did not answer \(method) in time and was stopped."
        case .cancelled: "The request was cancelled."
        case .exited(let status): "The engine worker exited (status \(status))."
        case .remote(let message): message
        case .protocolViolation(let detail): "Engine worker protocol error: \(detail)"
        }
    }
}

/// Owns one worker child process that speaks newline-delimited JSON. Worker lines starting `AXIOM ` are protocol
/// messages; every other line is engine log text. Requests are `{id, method, params}`; responses `{id, result|error}`.
public actor EngineWorker {
    public static let maxLineBytes = 16 * 1024 * 1024
    private let executable: String, arguments: [String]
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var methods: [Int: String] = [:]
    private var eventSink: AsyncStream<WorkerEvent>.Continuation?
    public nonisolated let events: AsyncStream<WorkerEvent>
    public private(set) var isRunning = false

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable; self.arguments = arguments
        var sink: AsyncStream<WorkerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        eventSink = sink
    }

    public func start() throws {
        guard !isRunning else { return }
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let input = Pipe(), output = Pipe()
        task.standardInput = input; task.standardOutput = output; task.standardError = output
        // Lines pass through an ordered stream so responses and events are handled in worker order.
        var lineSink: AsyncStream<String>.Continuation!
        let lines = AsyncStream<String>(bufferingPolicy: .unbounded) { lineSink = $0 }
        let sink = lineSink!
        let buffer = LineBuffer(limit: Self.maxLineBytes) { sink.yield($0) } overflow: { [weak task] in task?.terminate() }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; buffer.flush(); sink.finish() } else { buffer.append(data) }
        }
        task.terminationHandler = { [weak self] finished in
            Task { await self?.workerExited(status: finished.terminationStatus) }
        }
        try task.run()
        process = task; stdin = input.fileHandleForWriting; isRunning = true
        Task { [weak self] in for await line in lines { await self?.handle(line) } }
    }

    /// Sends a request and returns the JSON-encoded `result`. Task cancellation sends the worker a `cancel` notice.
    public func request(_ method: String, params: [String: any Sendable] = [:], timeout: TimeInterval = 60) async throws -> Data {
        guard isRunning else { throw WorkerError.notRunning }
        let id = nextID; nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pending[id] = continuation; methods[id] = method
                do { try send(["id": id, "method": method, "params": params]) } catch { fail(id, error); return }
                // Silent worker: its state is unknowable, so the watchdog stops it instead of waiting forever.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                    await self?.timeout(id, method)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    /// Asks the worker to stop, then terminates it if it has not exited within `grace` seconds.
    public func shutdown(grace: TimeInterval = 5) async {
        guard isRunning, let process else { return }
        _ = try? await request("shutdown", timeout: grace)
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if process.isRunning { process.terminate(); try? await Task.sleep(nanoseconds: 200_000_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }

    // MARK: Internals

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8)
        guard let stdin else { throw WorkerError.notRunning }
        try stdin.write(contentsOf: data)
    }

    private func fail(_ id: Int, _ error: Error) {
        methods[id] = nil
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func timeout(_ id: Int, _ method: String) {
        guard pending[id] != nil else { return }
        fail(id, WorkerError.timedOut(method))
        process?.terminate()
    }

    private func cancelRequest(_ id: Int) {
        guard pending[id] != nil else { return }
        try? send(["method": "cancel", "params": ["target": id]])
        fail(id, WorkerError.cancelled)
    }

    private func handle(_ line: String) {
        guard line.hasPrefix("AXIOM ") else { eventSink?.yield(.log(line)); return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else {
            eventSink?.yield(.log(line)); return
        }
        if let id = object["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }   // late reply to a cancelled or timed-out request
            methods[id] = nil
            if let error = object["error"] as? [String: Any] { continuation.resume(throwing: WorkerError.remote(error["message"] as? String ?? "Unknown engine error")) }
            else if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) { continuation.resume(returning: data) }
            else { continuation.resume(throwing: WorkerError.protocolViolation("response \(id) has neither result nor error")) }
            return
        }
        switch object["event"] as? String {
        case "ready": eventSink?.yield(.ready)
        case "progress": eventSink?.yield(.progress(phase: object["phase"] as? String ?? "", fraction: object["fraction"] as? Double))
        case let name?: eventSink?.yield(.other(name: name))
        case nil: eventSink?.yield(.log(line))
        }
    }

    private func workerExited(status: Int32) {
        isRunning = false
        stdin = nil
        for id in Array(pending.keys) { fail(id, WorkerError.exited(status)) }
        eventSink?.yield(.exited(status: status)); eventSink?.finish()
    }
}

/// Splits a byte stream into lines; reports (and stops reading) if a single line exceeds the limit.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data(); private let lock = NSLock()
    private let limit: Int, emit: (String) -> Void, overflow: () -> Void
    init(limit: Int, emit: @escaping (String) -> Void, overflow: @escaping () -> Void) { self.limit = limit; self.emit = emit; self.overflow = overflow }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        while let newline = data.firstIndex(of: 0x0a) {
            emit(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data.removeSubrange(data.startIndex...newline)
        }
        if data.count > limit { data.removeAll(); overflow() }
    }
    func flush() { lock.lock(); defer { lock.unlock() }; if !data.isEmpty { emit(String(decoding: data, as: UTF8.self)); data.removeAll() } }
}
