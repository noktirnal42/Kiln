import Foundation

/// Thrown when work stops because its operation was cancelled (by the client, by `cancel_operation`, or by the transport closing).
public struct OperationCancelled: Error, LocalizedError {
    public var errorDescription: String? { "The operation was cancelled." }
    public init() {}
}

/// One in-flight agent operation: an id, cancellation that long-running code can poll, handlers that release external
/// resources (a child process) the moment cancellation is requested, and a progress sink. Code finds the current
/// operation through `OperationContext.current` (a task-local), so deep call chains need no extra parameters.
public final class OperationContext: @unchecked Sendable {
    public let id: String
    public let tool: String
    public let transport: String
    public let startedAt = Date()
    /// The registry this operation belongs to (tools like `cancel_operation` act on the session's own registry).
    public var registry: OperationRegistry = .shared
    private let lock = NSLock()
    private var cancelledReason: String?
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    private var progressSink: (@Sendable (Double, String?) -> Void)?

    public init(id: String = UUID().uuidString, tool: String, transport: String = "mcp", progress: (@Sendable (Double, String?) -> Void)? = nil) {
        self.id = id; self.tool = tool; self.transport = transport; self.progressSink = progress
    }

    @TaskLocal public static var current: OperationContext?

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledReason != nil }
    public var cancelReason: String? { lock.lock(); defer { lock.unlock() }; return cancelledReason }

    /// Requests cancellation: marks the operation and runs release handlers once. Safe to call repeatedly and from any thread.
    public func cancel(reason: String = "cancelled") {
        lock.lock()
        guard cancelledReason == nil else { lock.unlock(); return }
        cancelledReason = reason
        let pending = Array(handlers.values); handlers.removeAll()
        lock.unlock()
        for handler in pending { handler() }
    }

    /// Registers a handler to run if the operation is cancelled (runs immediately if it already was). Returns a token for `removeHandler`.
    @discardableResult public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        if cancelledReason != nil { lock.unlock(); handler(); return token }
        handlers[token] = handler
        lock.unlock()
        return token
    }
    public func removeHandler(_ token: UUID) { lock.lock(); handlers[token] = nil; lock.unlock() }

    public func checkCancelled() throws { if isCancelled { throw OperationCancelled() } }
    public func reportProgress(_ fraction: Double, _ message: String? = nil) { progressSink?(min(1, max(0, fraction)), message) }

    // Conveniences for code that may run with or without an operation (CLI commands, tests).
    public static func check() throws { try current?.checkCancelled() }
    public static func progress(_ fraction: Double, _ message: String? = nil) { current?.reportProgress(fraction, message) }
}

/// Snapshot of an operation for listing; kept for a while after completion so a client can still ask what happened.
public struct OperationRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, completed, failed, cancelled }
    public let operationId: String
    public let tool: String
    public let transport: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: State
    public var detail: String?
}

/// Process-wide registry of agent operations (running and recently finished), shared by every transport in this process.
public final class OperationRegistry: @unchecked Sendable {
    public static let shared = OperationRegistry()
    private let lock = NSLock()
    private var contexts: [String: OperationContext] = [:]
    private var records: [OperationRecord] = []
    static let keepFinished = 100

    public init() {}

    public func begin(_ context: OperationContext) {
        lock.lock(); defer { lock.unlock() }
        contexts[context.id] = context
        records.append(OperationRecord(operationId: context.id, tool: context.tool, transport: context.transport, startedAt: context.startedAt, finishedAt: nil, state: .running, detail: nil))
    }
    public func finish(_ context: OperationContext, state: OperationRecord.State, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        contexts[context.id] = nil
        if let index = records.lastIndex(where: { $0.operationId == context.id }) { records[index].state = state; records[index].finishedAt = Date(); records[index].detail = detail }
        let finished = records.filter { $0.state != .running }
        if finished.count > Self.keepFinished, let drop = finished.first { records.removeAll { $0.operationId == drop.operationId } }
    }
    /// Cancels a running operation by id; false when it is unknown or already finished.
    @discardableResult public func cancel(_ operationId: String, reason: String = "cancelled by request") -> Bool {
        lock.lock(); let context = contexts[operationId]; lock.unlock()
        guard let context else { return false }
        context.cancel(reason: reason); return true
    }
    public func cancelAll(reason: String) { lock.lock(); let all = Array(contexts.values); lock.unlock(); for context in all { context.cancel(reason: reason) } }
    public func list() -> [OperationRecord] { lock.lock(); defer { lock.unlock() }; return records }
    public func isRunning(_ operationId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return contexts[operationId] != nil }
}
