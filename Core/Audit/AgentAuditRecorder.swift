import Foundation

/// Records one agent run into an `AuditChain`, in order.
///
/// What goes in: what the agent did and what it was allowed to do. Tool name, permission level,
/// policy rule, approval decision, status, size of the result.
///
/// What never goes in: the prompt, file contents, or tool results. Arguments are limited to a few
/// identifying ones (path, command, URL, ...), run through `SecretRedactor` and clipped; every
/// other argument is recorded by name only. The log has to be safe to hand to an auditor.
///
/// `record` is synchronous because the orchestrator emits events from a synchronous callback. A
/// single consumer task appends them, so chain order always matches emission order; spawning a
/// task per event would reorder them.
///
/// If the chain refuses an append (for example an unreadable tail), the run continues and the loss
/// is counted in `droppedEntries` rather than hidden. Failing closed would change what an agent
/// may do whenever the disk misbehaves, which is a policy decision, not a logging one.
public final class AgentAuditRecorder: @unchecked Sendable {
    public let runID: String

    private struct Entry: Sendable {
        let type: String
        let payload: [String: AuditValue]
    }

    /// Shared between the consumer task and the recorder; the only mutable state.
    private final class FailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var last: String?

        func note(_ error: Error) {
            lock.withLock {
                count += 1
                last = error.localizedDescription
            }
        }

        var snapshot: (count: Int, last: String?) { lock.withLock { (count, last) } }
    }

    private let continuation: AsyncStream<Entry>.Continuation
    private let consumer: Task<Void, Never>
    private let failures = FailureLog()

    /// - Parameter health: app-wide drop counter; nil in tests that only inspect this recorder.
    public init(chain: AuditChain, runID: String = UUID().uuidString, health: AuditHealth? = nil) {
        self.runID = runID
        let (stream, continuation) = AsyncStream.makeStream(of: Entry.self)
        self.continuation = continuation
        let failures = self.failures
        self.consumer = Task {
            for await entry in stream {
                do {
                    try await chain.append(type: entry.type, payload: entry.payload, runID: runID)
                } catch {
                    failures.note(error)
                    health?.note(error)
                }
            }
        }
    }

    /// Entries the chain refused. Non-zero means the audit trail has a hole.
    public var droppedEntries: Int { failures.snapshot.count }
    public var lastFailureDescription: String? { failures.snapshot.last }

    // MARK: Recording

    public func record(_ type: String, _ payload: [String: AuditValue] = [:]) {
        continuation.yield(Entry(type: type, payload: payload))
    }

    public func recordStarted(profileID: UUID, profileName: String, modelID: String?, mode: String,
                              promptCharacters: Int, workspaceRoot: URL?) {
        record("agent.run.started", [
            "profile_id": .string(profileID.uuidString),
            "profile": .string(profileName),
            "model": modelID.map(AuditValue.string) ?? .null,
            "mode": .string(mode),
            "prompt_characters": .int(promptCharacters),
            "workspace": workspaceRoot.map { .string($0.path) } ?? .null,
        ])
    }

    public func recordFailure(_ error: Error) {
        record("agent.run.failed", ["reason": .string(Self.clip(SecretRedactor.redact(String(describing: error)).text))])
    }

    /// Maps an orchestrator event to a chain entry. Text deltas are deliberately not recorded.
    public func record(event: AgentEvent) {
        if let entry = Self.entry(for: event) { record(entry.type, entry.payload) }
    }

    /// Stops accepting entries and waits until everything queued has been appended.
    public func finish() async {
        continuation.finish()
        await consumer.value
    }

    // MARK: Mapping (pure)

    static func entry(for event: AgentEvent) -> (type: String, payload: [String: AuditValue])? {
        switch event {
        case .textDelta, .textReset, .reasoningDelta, .contextMeasured, .pausedContext:
            return nil
        case .roundStarted(let round):
            return ("agent.round", ["round": .int(round)])
        case .toolCallStarted(let record):
            return ("tool.call", [
                "call_id": .string(record.callID),
                "tool": .string(record.toolName),
                "permission": .string(record.permission.rawValue),
                "arguments": summarizeArguments(record.argumentsJSON),
            ])
        case .toolCallFinished(let record):
            var payload: [String: AuditValue] = [
                "call_id": .string(record.callID),
                "tool": .string(record.toolName),
                "status": .string(record.status.rawValue),
                "result_characters": .int(record.resultText?.count ?? 0),
            ]
            if let error = record.errorText {
                payload["error"] = .string(clip(SecretRedactor.redact(error).text))
            }
            return ("tool.result", payload)
        case .policyDenied(let tool, let rule, let reason):
            return ("policy.denied", [
                "tool": .string(tool),
                "rule": .string(rule),
                "reason": .string(clip(SecretRedactor.redact(reason).text)),
            ])
        case .awaitingApproval(let request):
            return ("approval.requested", [
                "request_id": .string(request.id.uuidString),
                "tool": .string(request.toolName),
                "permission": .string(request.permission.rawValue),
                "destructive": .bool(request.isDestructive),
                "grant_kind": request.grantKind.map { .string($0.rawValue) } ?? .null,
            ])
        case .approvalResolved(let id, let approved):
            return ("approval.resolved", ["request_id": .string(id.uuidString), "approved": .bool(approved)])
        case .retryScheduled(let attempt, let delay, let reason):
            return ("provider.retry", [
                "attempt": .int(attempt),
                "delay_seconds": .double(delay),
                "reason": .string(clip(SecretRedactor.redact(reason).text)),
            ])
        case .contextCompacted(let compaction):
            // Counts only; the summary is conversation content and stays out of the chain.
            return ("context.compacted", [
                "stage": .string(compaction.stage.rawValue),
                "tokens_before": .int(compaction.tokensBefore),
                "tokens_after": .int(compaction.tokensAfter),
                "results_cleared": .int(compaction.clearedResults),
            ])
        case .finished(let summary):
            // The final text is the model's answer and may hold anything; only counts are kept.
            return ("agent.run.finished", [
                "rounds": .int(summary.rounds),
                "tool_calls_executed": .int(summary.toolCallsExecuted),
                "tool_calls_denied": .int(summary.toolCallsDenied),
                "redactions": .int(summary.redactionCount),
                "total_tokens": .int(summary.totalTokens),
            ])
        }
    }

    /// Arguments that identify what a call touched. Everything else is recorded by key name only.
    static let identifyingArguments: Set<String> = ["path", "command", "url", "pattern", "query", "glob", "branch"]

    static func summarizeArguments(_ json: String) -> AuditValue {
        guard let object = ToolArgs.object(from: json) else { return ["unparseable": true] }
        var shown: [String: AuditValue] = [:]
        for (key, value) in object where identifyingArguments.contains(key) {
            if let text = value as? String { shown[key] = .string(clip(SecretRedactor.redact(text).text)) }
        }
        let others = object.keys.filter { !identifyingArguments.contains($0) }.sorted()
        return ["values": .object(shown), "other_keys": .array(others.map(AuditValue.string))]
    }

    static func clip(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
