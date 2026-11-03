import Foundation

// MARK: - Events

/// Everything a run reports to the UI as it happens.
public enum AgentEvent: Sendable {
    case textDelta(String)
    /// Thinking text from reasoning models, streamed before the answer.
    case reasoningDelta(String)
    /// Clears partial output before a retry or when text is reclassified as a tool call.
    case textReset
    case roundStarted(Int)
    case toolCallStarted(ToolCallRecord)
    case toolCallFinished(ToolCallRecord)
    case awaitingApproval(ApprovalRequest)
    case approvalResolved(id: UUID, approved: Bool)
    /// A transient provider failure is being retried after `delaySeconds`.
    case retryScheduled(attempt: Int, delaySeconds: Double, reason: String)
    case policyDenied(tool: String, rule: String, reason: String)
    case finished(AgentRunSummary)
}

public struct AgentRunSummary: Codable, Equatable, Sendable {
    public var rounds: Int
    public var toolCallsExecuted: Int
    public var toolCallsDenied: Int
    public var redactionCount: Int
    public var totalTokens: Int
    public var finalText: String

    public init(
        rounds: Int = 0,
        toolCallsExecuted: Int = 0,
        toolCallsDenied: Int = 0,
        redactionCount: Int = 0,
        totalTokens: Int = 0,
        finalText: String = ""
    ) {
        self.rounds = rounds
        self.toolCallsExecuted = toolCallsExecuted
        self.toolCallsDenied = toolCallsDenied
        self.redactionCount = redactionCount
        self.totalTokens = totalTokens
        self.finalText = finalText
    }
}

/// The operator's Stop button. Checked between rounds, before every retry
/// attempt, and once a second while a backoff sleeps — so pressing Stop
/// takes effect within a second, never after the whole schedule.
public final class AgentStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false

    public init() {}

    public func stop() {
        lock.lock(); _stopped = true; lock.unlock()
    }

    public var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }
}

// MARK: - Retry classification (System5 orchestrator, ported)

/// Errors that a second attempt might survive: 429, 5xx, and transport
/// failures. Anything not listed fails the same way every time, and
/// retrying it only burns the clock — a bad key, a missing model, no
/// credit.
public enum AgentRetry {
    public static let attempts = 5

    static let retryableMessage = try! NSRegularExpression(
        pattern: #"\b(429|500|502|503|504)\b|rate.?limit|too many requests|overloaded|timeout|timed out|temporarily|connection (reset|refused|error|aborted)|read error|nodename nor servname|name or service not known|temporary failure in name resolution|getaddrinfo|network is unreachable|no route to host|host is down|server disconnected|eof occurred"#,
        options: [.caseInsensitive]
    )

    public static func worthRetrying(_ error: Error) -> Bool {
        if let e = error as? ProviderError {
            switch e {
            case .rateLimited, .serviceUnavailable, .network:
                return true
            case .notFound, .missingConfiguration, .authenticationFailed, .paymentRequired, .invalidResponse, .engineUnavailable:
                return false
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed, .serverCertificateUntrusted:
                return true
            default:
                return false
            }
        }
        let text = String(describing: error)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return retryableMessage.firstMatch(in: text, range: range) != nil
    }

    /// A sentence a human can act on, instead of an errno.
    public static func explain(_ error: Error) -> String {
        let text = String(describing: error)
            .split(separator: " ")
            .joined(separator: " ")
        return String(text.prefix(160))
    }
}

// MARK: - Tool calls written as text

enum TextToolCall {
    /// Recognises a reply that is nothing but `{"name": "<offered tool>", "arguments": {...}}`,
    /// optionally inside a code fence. Anything else (prose, an unknown name, extra text) is left
    /// alone, so a model that merely mentions a tool never triggers one.
    static func parse(_ text: String, offered: Set<String>) -> ToolCall? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.drop { $0 != "\n" }.dropFirst().description
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{"), body.hasSuffix("}"),
              let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, offered.contains(name),
              Set(object.keys).isSubset(of: ["name", "arguments", "parameters"]) else { return nil }
        let arguments = (object["arguments"] ?? object["parameters"]) as? [String: Any] ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ToolCall(id: "call_\(UUID().uuidString)", name: name, arguments: json, index: 0)
    }
}

// MARK: - Orchestrator

/// The single-agent tool-call loop: stream the model → parse tool calls →
/// policy check → approval gate → execute → feed results back → repeat
/// until the model stops calling tools.
///
/// The two gates are independent and both are always on:
///  - Gate A (`offeredTools`) filters the tool list before the model sees
///    it. A read-only policy strips write/execute tools outright.
///  - Gate B (the dispatch path below) re-checks every arriving tool call
///    against the policy and the approval center — even one the model
///    hallucinated that was never on the offered list. Filtering never
///    makes dispatch trust the tool list.
///
/// This is the only place a provider is let loose with tools — providers
/// never see the filesystem or a shell directly.
public final class AgentOrchestrator: Sendable {
    public let toolRegistry: ToolRegistry
    /// The approval center Gate B routes through. Nil means "the shared
    /// center", resolved on the main actor at run time — referencing it
    /// eagerly would force every caller onto the main actor.
    public let approvalCenter: ApprovalCenter?

    /// Enforces each profile's `maxConcurrentTasks`: more runs of the same
    /// profile than it allows wait for a free slot rather than overlapping.
    private let limiter = AgentRunLimiter()

    /// The app's shared services handed to every tool execution: the git
    /// service, the workspace file index, and the web-search key provider.
    /// Empty by default so tests and previews run without booting the app.
    public let services: ToolServices

    /// When set, every run is recorded into this tamper-evident chain: what the agent did and was
    /// allowed to do, never prompts, file contents or tool results. Nil records nothing.
    public let auditChain: AuditChain?

    /// Tripwires run on every tool call before it executes. A finding at or above the policy's
    /// severity pauses only the originating run and asks a human.
    public let monitor: MonitorPolicy

    /// Resolves the model-based rubric monitor for a run, or nil for none. Resolved per run so a
    /// setting changed between runs takes effect. Nil (the default) makes no extra model calls.
    public let rubric: (@Sendable () async -> RubricMonitor?)?

    /// Where recorders report audit entries the chain refused, so the loss is visible app-wide.
    public let auditHealth: AuditHealth?

    public init(
        toolRegistry: ToolRegistry = .shared,
        approvalCenter: ApprovalCenter? = nil,
        services: ToolServices = ToolServices(),
        auditChain: AuditChain? = nil,
        monitor: MonitorPolicy = .standard,
        rubric: (@Sendable () async -> RubricMonitor?)? = nil,
        auditHealth: AuditHealth? = nil
    ) {
        self.toolRegistry = toolRegistry
        self.approvalCenter = approvalCenter
        self.services = services
        self.auditChain = auditChain
        self.monitor = monitor
        self.rubric = rubric
        self.auditHealth = auditHealth
    }

    /// The same orchestrator (approvals, audit, monitor, services) with extra tools registered.
    /// Used for per-worker tools bound to one agent, such as its bus endpoint.
    public func withTools(_ extra: [any ToolExecuting]) -> AgentOrchestrator {
        AgentOrchestrator(
            toolRegistry: toolRegistry.extended(with: extra), approvalCenter: approvalCenter, services: services,
            auditChain: auditChain, monitor: monitor, rubric: rubric, auditHealth: auditHealth
        )
    }

    func resolveCenter() async -> ApprovalCenter {
        if let center = approvalCenter { return center }
        return await MainActor.run { ApprovalCenter.shared }
    }

    public func run(
        profile: AgentProfile,
        prompt: String,
        history: [ChatMessage] = [],
        workspaceRoot: URL? = nil,
        policy override: ExecutionPolicy? = nil,
        stop: AgentStopFlag = AgentStopFlag(),
        backoffUnitSeconds: Double = 1.0,
        chat: @escaping @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error>
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let recorder = self.auditChain.map { AgentAuditRecorder(chain: $0, health: self.auditHealth) }
            let task = Task {
                do {
                    recorder?.recordStarted(
                        profileID: profile.id, profileName: profile.name, modelID: profile.modelID,
                        mode: profile.mode.rawValue, promptCharacters: prompt.count, workspaceRoot: workspaceRoot
                    )
                    let rubricMonitor = self.monitor.enabled ? await self.rubric?() : nil
                    try await self.limiter.withSlot(profileID: profile.id, maxConcurrent: profile.maxConcurrentTasks) {
                        try await self.loop(
                            profile: profile,
                            prompt: prompt,
                            history: history,
                            workspaceRoot: workspaceRoot,
                            policy: override,
                            stop: stop,
                            backoffUnitSeconds: backoffUnitSeconds,
                            chat: chat,
                            audit: recorder,
                            rubric: rubricMonitor,
                            yield: {
                                recorder?.record(event: $0)
                                continuation.yield($0)
                            }
                        )
                    }
                    // Everything queued must be in the chain before the caller sees the run end.
                    await recorder?.finish()
                    continuation.finish()
                } catch {
                    recorder?.recordFailure(error)
                    await recorder?.finish()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Single tool call (external agents)

    /// Runs ONE tool call on behalf of an outside agent (for example over MCP) through exactly the
    /// gates a built-in run uses: the profile's tool set and level policy, write/shell/egress checks,
    /// the approval center, the behavior monitor, and the audit chain. Nothing here widens access;
    /// a write or command still waits for a human in the app.
    public func callTool(
        _ call: ToolCall,
        profile: AgentProfile,
        workspaceRoot: URL? = nil,
        timeout: TimeInterval = 120
    ) async -> ToolCallRecord {
        let recorder = auditChain.map { AgentAuditRecorder(chain: $0, health: auditHealth) }
        recorder?.recordStarted(
            profileID: profile.id, profileName: profile.name, modelID: nil,
            mode: profile.mode.rawValue, promptCharacters: 0, workspaceRoot: workspaceRoot
        )
        let center = await resolveCenter()
        // The profile decides what an external caller may use; the policy allowlist is widened to the
        // same set so the two gates agree. Mode cap, write/shell/egress checks and approvals still apply.
        var policy = ExecutionPolicy(mode: profile.mode)
        policy.toolsAllowed = toolRegistry.allSpecs().map(\.name).filter { profile.toolPermissions.isEnabled($0) }
        let record: ToolCallRecord
        do {
            record = try await dispatch(
                call: call,
                policy: policy,
                profile: profile,
                workspaceRoot: workspaceRoot,
                stop: AgentStopFlag(),
                approvalCenter: center,
                toolTimeout: timeout,
                audit: recorder,
                findings: nil,
                yield: { recorder?.record(event: $0) }
            )
        } catch {
            var failed = ToolCallRecord(callID: call.id, toolName: call.name, argumentsJSON: call.arguments)
            failed.status = .failed
            failed.errorText = AgentRetry.explain(error)
            failed.finishedAt = Date()
            record = failed
        }
        await recorder?.finish()
        return record
    }

    // MARK: The loop

    private func loop(
        profile: AgentProfile,
        prompt: String,
        history initialHistory: [ChatMessage],
        workspaceRoot: URL?,
        policy override: ExecutionPolicy?,
        stop: AgentStopFlag,
        backoffUnitSeconds: Double,
        chat: @escaping @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error>,
        audit: AgentAuditRecorder?,
        rubric: RubricMonitor?,
        yield: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> Void {
        let approvalCenter = await resolveCenter()
        if stop.stopped { throw AgentRunError.stopped }
        let startedAt = Date()

        // The profile's mode is the ceiling; its tool set narrows further.
        // A caller-supplied policy replaces the standard one wholesale
        // (mode still capped to the profile's). The effective
        // `toolsAllowed` is the same intersection Gate A offered, so Gate
        // B's `checkTool` judges exactly what the model was shown — never
        // more.
        var policy = override ?? ExecutionPolicy(mode: profile.mode)
        if policy.mode != profile.mode {
            policy.mode = profile.mode
        }
        policy.toolsAllowed = policy.toolsAllowed.filter { profile.toolPermissions.isEnabled($0) }
        if profile.toolPermissions.enabledTools.isEmpty {
            policy.toolsAllowed = []
        }

        // Gate A: the tool list the model may even see.
        let offered = policy.offeredTools(
            from: toolRegistry,
            permissions: profile.toolPermissions,
            workspaceRoot: workspaceRoot
        )
        let providerTools = offered.map(\.providerTool)

        // Secret redaction, before anything reaches a provider.
        var finalPrompt = prompt
        var redactions = 0
        if profile.redactSecrets {
            let (redacted, count) = SecretRedactor.redact(prompt)
            redactions += count
            finalPrompt = redacted
        }

        var history = initialHistory
        if !profile.systemPrompt.isEmpty {
            history.insert(ChatMessage(role: .system, content: profile.systemPrompt), at: 0)
        }
        history.append(ChatMessage(role: .user, content: finalPrompt))

        var summary = AgentRunSummary(redactionCount: redactions)
        var assistantText = ""

        // Rubric passes run beside the loop. They are advisory: a slow or failing monitor never
        // delays or stops the agent, and passes still in flight when the run ends are cancelled.
        let findings: RubricFindings? = rubric == nil ? nil : RubricFindings()
        var passes: [Task<Void, Never>] = []
        defer { passes.forEach { $0.cancel() } }

        while true {
            if stop.stopped { throw AgentRunError.stopped }
            if profile.runTimeoutSeconds > 0,
               Date().timeIntervalSince(startedAt) > Double(profile.runTimeoutSeconds) {
                throw AgentRunError.runTimedOut
            }
            summary.rounds += 1
            yield(.roundStarted(summary.rounds))

            let budgetDecision = policy.checkBudget(
                costUSD: 0,
                tokens: summary.totalTokens,
                minutes: Date().timeIntervalSince(startedAt) / 60
            )
            if budgetDecision.verdict == .deny {
                throw AgentRunError.budgetExhausted(budgetDecision.reason)
            }

            var request = ChatRequest(
                messages: history,
                model: profile.modelID ?? "",
                temperature: profile.temperature ?? 0.7,
                maxTokens: profile.maxTokens ?? 4096
            )
            request.tools = providerTools

            // One model turn, with System5's retry/backoff around it.
            var turn = try await turnWithRetry(
                request: request,
                chat: chat,
                stop: stop,
                backoffUnitSeconds: backoffUnitSeconds,
                redactSecrets: profile.redactSecrets,
                yield: yield
            )
            // Small local models often write a tool call as JSON text instead of a structured call.
            // Accept that only when the whole reply is one call to a tool this run actually offered.
            if turn.toolCalls.isEmpty,
               let call = TextToolCall.parse(turn.text, offered: Set(offered.map(\.name))) {
                turn.toolCalls = [call]
                turn.text = ""
                yield(.textReset)
            }

            summary.totalTokens += turn.usageTotalTokens
            if profile.redactSecrets {
                let (redacted, count) = SecretRedactor.redact(turn.text)
                redactions += count
                summary.redactionCount = redactions
                history.append(ChatMessage(role: .assistant, content: redacted, toolCalls: turn.toolCalls))
                assistantText = redacted
            } else {
                history.append(ChatMessage(role: .assistant, content: turn.text, toolCalls: turn.toolCalls))
                assistantText = turn.text
            }

            if turn.text.isEmpty && turn.toolCalls.isEmpty { break }
            if turn.toolCalls.isEmpty { break }
            if summary.rounds >= 40 { throw AgentRunError.roundLimitReached(40) }

            for call in turn.toolCalls {
                if stop.stopped { throw AgentRunError.stopped }
                let elapsed = Date().timeIntervalSince(startedAt)
                let toolBudget: TimeInterval
                if profile.runTimeoutSeconds > 0 {
                    toolBudget = max(1, Double(profile.runTimeoutSeconds) - elapsed)
                } else {
                    toolBudget = 300
                }
                let record = try await dispatch(
                    call: call,
                    policy: policy,
                    profile: profile,
                    workspaceRoot: workspaceRoot,
                    stop: stop,
                    approvalCenter: approvalCenter,
                    toolTimeout: toolBudget,
                    audit: audit,
                    findings: findings,
                    yield: yield
                )
                switch record.status {
                case .succeeded, .failed:
                    summary.toolCallsExecuted += 1
                case .denied:
                    summary.toolCallsDenied += 1
                default:
                    break
                }
                var content = record.resultText ?? record.errorText ?? ""
                if profile.redactSecrets {
                    let (redacted, count) = SecretRedactor.redact(content)
                    redactions += count
                    summary.redactionCount = redactions
                    content = redacted
                }
                var metadata = ["tool_call_id": call.id, "tool_name": call.name]
                if record.status == .denied { metadata["is_error"] = "true" }
                history.append(ChatMessage(
                    role: .tool,
                    content: content,
                    metadata: metadata
                ))
            }

            if let rubric, let findings {
                let round = summary.rounds
                let activity = RubricMonitor.activityText(round: round, assistantText: turn.text, calls: turn.toolCalls)
                passes.append(Task {
                    let found = await rubric.assess(activity: activity)
                    findings.add(found)
                    audit?.record("monitor.assessed", [
                        "round": .int(round),
                        "flags": .int(found.count),
                        "worst": .int(Tripwires.worstSeverity(found)),
                    ])
                    for flag in found {
                        audit?.record("monitor.flag", [
                            "round": .int(round),
                            "category": .string(flag.category),
                            "severity": .int(flag.severity),
                            "rationale": .string(AgentAuditRecorder.clip(SecretRedactor.redact(flag.rationale).text)),
                            "source": .string(flag.source),
                        ])
                    }
                })
            }
        }

        summary.finalText = assistantText
        yield(.finished(summary))
    }

    // MARK: One model turn with retry/backoff

    private struct TurnResult: Sendable {
        var text: String
        var toolCalls: [ToolCall]
        var usageTotalTokens: Int
    }

    private func turnWithRetry(
        request: ChatRequest,
        chat: @escaping @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error>,
        stop: AgentStopFlag,
        backoffUnitSeconds: Double,
        redactSecrets: Bool,
        yield: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> TurnResult {
        for attempt in 0..<AgentRetry.attempts {
            // An operator Stop used to sit unnoticed through the rest of the
            // backoff schedule, up to 7s of pure sleep, because nothing here
            // ever looked. That reads as the button not working.
            if stop.stopped { throw AgentRunError.stopped }
            do {
                var text = ""
                var visibleText = ""
                var toolCalls: [ToolCall] = []
                var tokens = 0
                let stream = try await chat(request)
                for try await chunk in stream {
                    if stop.stopped { throw AgentRunError.stopped }
                    if let thinking = chunk.reasoning, !thinking.isEmpty { yield(.reasoningDelta(thinking)) }
                    if let delta = chunk.delta, !delta.content.isEmpty {
                        text += delta.content
                        let visible = redactSecrets ? SecretRedactor.redact(text).text : text
                        // Redaction can change a prefix once a split key becomes recognizable.
                        // Replace that prefix rather than appending a stale partial value.
                        if visible.hasPrefix(visibleText) {
                            let delta = String(visible.dropFirst(visibleText.count))
                            if !delta.isEmpty { yield(.textDelta(delta)) }
                        } else {
                            yield(.textReset)
                            if !visible.isEmpty { yield(.textDelta(visible)) }
                        }
                        visibleText = visible
                    }
                    for call in chunk.toolCalls {
                        merge(call, into: &toolCalls)
                    }
                    if let usage = chunk.usage {
                        tokens = max(tokens, usage.totalTokens)
                    }
                }
                return TurnResult(text: text, toolCalls: toolCalls, usageTotalTokens: tokens)
            } catch {
                if stop.stopped { throw AgentRunError.stopped }
                if attempt == AgentRetry.attempts - 1 || !AgentRetry.worthRetrying(error) {
                    throw error
                }
                yield(.textReset)
                let delay = pow(2.0, Double(attempt)) * backoffUnitSeconds // 1s, 2s, 4s, 8s at full scale
                yield(.retryScheduled(
                    attempt: attempt + 1,
                    delaySeconds: delay,
                    reason: AgentRetry.explain(error)
                ))
                // Sleep in short slices so a Stop takes effect within a
                // second rather than after the whole remaining schedule.
                var remaining = delay
                while remaining > 0 {
                    if stop.stopped { throw AgentRunError.stopped }
                    let step = min(1.0, remaining)
                    try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                    remaining -= step
                }
            }
        }
        throw AgentRunError.noProvider("unreachable")
    }

    /// Streaming providers may split one tool call across chunks; merge by
    /// index/id, concatenating argument fragments.
    private func merge(_ incoming: ToolCall, into calls: inout [ToolCall]) {
        if incoming.id.isEmpty && incoming.name.isEmpty && incoming.arguments.isEmpty { return }
        if let i = calls.firstIndex(where: { !$0.id.isEmpty && $0.id == incoming.id })
            ?? calls.firstIndex(where: { $0.index != nil && $0.index == incoming.index && incoming.id.isEmpty }) {
            if !incoming.name.isEmpty { calls[i].name = incoming.name }
            calls[i].arguments += incoming.arguments
        } else {
            calls.append(incoming)
        }
    }

    // MARK: Dispatch (GATE B)

    /// Handles one tool call: policy re-check → approval → execution.
    /// Denials and failures become tool-result messages the model can read
    /// and react to; nothing here ever crashes the run.
    @discardableResult
    private func dispatch(
        call: ToolCall,
        policy: ExecutionPolicy,
        profile: AgentProfile,
        workspaceRoot: URL?,
        stop: AgentStopFlag,
        approvalCenter: ApprovalCenter,
        toolTimeout: TimeInterval,
        audit: AgentAuditRecorder?,
        findings: RubricFindings?,
        yield: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> ToolCallRecord {
        var record = ToolCallRecord(
            callID: call.id,
            toolName: call.name,
            argumentsJSON: call.arguments,
            permission: .read
        )
        yield(.toolCallStarted(record))

        func finish(_ status: ToolCallStatus, result: String? = nil, error: String? = nil) -> ToolCallRecord {
            record.status = status
            record.resultText = result
            record.errorText = error
            record.finishedAt = Date()
            yield(.toolCallFinished(record))
            return record
        }

        guard let tool = toolRegistry.tool(named: call.name) else {
            return finish(.failed, error: "Unknown tool '\(call.name)'. Available tools are the ones you were given.")
        }
        let spec = tool.spec
        record.permission = spec.permission

        // Deterministic tripwires, before anything else can refuse or run the call. Every finding is
        // audited even when the policy also refuses the call: a denied attempt is still evidence.
        let flags = monitor.enabled
            ? Tripwires.check(tool: call.name, argumentsJSON: call.arguments,
                              workspaceRoot: workspaceRoot, protectedPaths: monitor.protectedPaths)
            : []
        for flag in flags {
            audit?.record("monitor.flag", [
                "call_id": .string(call.id),
                "tool": .string(call.name),
                "category": .string(flag.category),
                "severity": .int(flag.severity),
                "rationale": .string(AgentAuditRecorder.clip(SecretRedactor.redact(flag.rationale).text)),
                "source": .string(flag.source),
            ])
        }

        // The policy refuses this tool outright — the same tool list the
        // model was offered came from Gate A; this re-check catches a tool
        // call that was never on it.
        let toolDecision = policy.checkTool(call.name)
        if toolDecision.verdict == .deny {
            yield(.policyDenied(tool: call.name, rule: toolDecision.rule, reason: toolDecision.reason))
            return finish(.denied, error: "policy denied: \(toolDecision.reason)")
        }

        // The agent's permission set gates it too.
        guard profile.toolPermissions.isEnabled(call.name) else {
            yield(.policyDenied(tool: call.name, rule: "tool_permissions", reason: "tool not enabled for this agent"))
            return finish(.denied, error: "The '\(call.name)' tool is not enabled for this agent.")
        }
        guard spec.permission <= policy.mode.maxPermittedLevel || (["mcp_call_tool", "computer_use"].contains(spec.name) && policy.mode.allowsDirectWrites) else {
            yield(.policyDenied(tool: call.name, rule: "mode_cap", reason: "mode '\(policy.mode.rawValue)' allows at most \(policy.mode.maxPermittedLevel.displayName) access"))
            return finish(.denied, error: "The current mode (\(policy.mode.displayName)) does not allow '\(call.name)', which requires \(spec.permission.displayName) access.")
        }

        // Argument-level checks by tool family.
        var approvalKindFromPolicy: ApprovalKind?
        let args = ToolArgs.object(from: call.arguments) ?? [:]

        if WritePathChecker.isWriteTool(call.name), let path = args["path"] as? String {
            let decision = policy.checkWritePath(path)
            switch decision.verdict {
            case .deny:
                yield(.policyDenied(tool: call.name, rule: decision.rule, reason: decision.reason))
                return finish(.denied, error: "policy denied: \(decision.reason)")
            case .requireApproval:
                approvalKindFromPolicy = .writeOutsideScope
            case .allow:
                break
            }
        }

        if ShellCommandChecker.isShellTool(call.name), let command = args["command"] as? String {
            let decision = policy.checkShell(command)
            switch decision.verdict {
            case .deny:
                yield(.policyDenied(tool: call.name, rule: decision.rule, reason: decision.reason))
                return finish(.denied, error: "policy denied: \(decision.reason) (command: \(command))")
            case .requireApproval:
                approvalKindFromPolicy = .riskyShell
            case .allow:
                break
            }
        }

        if call.name == "web_fetch", let url = args["url"] as? String,
           let host = URL(string: url)?.host() {
            let grants = await MainActor.run { Set(approvalCenter.grants.values(kind: .egressHost)) }
            let decision = policy.checkEgress(host, grants: grants)
            switch decision.verdict {
            case .deny:
                yield(.policyDenied(tool: call.name, rule: decision.rule, reason: decision.reason))
                return finish(.denied, error: "policy denied: \(decision.reason)")
            case .requireApproval:
                approvalKindFromPolicy = .networkNewDomain
            case .allow:
                break
            }
        }

        // The approval gate. `denied` at the permission-set level never
        // runs at all; `automatic` runs without asking; everything else
        // asks, with consequences spelled out.
        let configuredPolicy = profile.toolPermissions.policy(for: spec.permission)
        let levelPolicy: ApprovalPolicy = ["mcp_call_tool", "computer_use"].contains(spec.name) && configuredPolicy != .denied ? .always : configuredPolicy
        if levelPolicy == .denied {
            yield(.policyDenied(tool: call.name, rule: "permission_set", reason: "level \(spec.permission.rawValue) denied for this agent"))
            return finish(.denied, error: "The '\(call.name)' tool is denied for this agent.")
        }

        let needsHumanApproval: Bool
        switch levelPolicy {
        case .automatic:
            needsHumanApproval = approvalKindFromPolicy != nil
        case .once, .always:
            needsHumanApproval = true
        case .denied:
            needsHumanApproval = false // already refused above
        }

        if needsHumanApproval {
            record.status = .awaitingApproval
            let preview = ApprovalPreview.preview(for: spec, argumentsJSON: call.arguments)
            let destructive = spec.isDestructive
                || (ShellCommandChecker.isShellTool(call.name)
                    && CommandSafety.isDestructive((args["command"] as? String) ?? ""))
            let consequences: String
            if let reason = CommandSafety.destructiveReason((args["command"] as? String) ?? "") {
                consequences = reason
            } else {
                consequences = Self.consequences(for: spec, args: args, kind: approvalKindFromPolicy)
            }
            let grantValue = Self.grantValue(for: call.name, args: args)
            // Computer use and MCP calls are asked about one by one in Ask and Auto; only an explicitly confirmed Bypass skips them.
            let currentMode = await MainActor.run { approvalCenter.mode }
            let alwaysAsk = ["mcp_call_tool", "computer_use"].contains(spec.name) && currentMode != .bypass
            let request = ApprovalRequest(
                toolName: spec.name,
                toolSummary: spec.summary,
                argumentsJSON: call.arguments,
                permission: spec.permission,
                isDestructive: destructive,
                preview: preview,
                consequences: consequences,
                grantValue: grantValue.value,
                grantKind: grantValue.kind,
                isMonitorReview: alwaysAsk,
                policyFlag: approvalKindFromPolicy
            )
            yield(.awaitingApproval(request))
            let decision = alwaysAsk
                ? await approvalCenter.requestReview(request, conversationID: profile.id)
                : await approvalCenter.requestApproval(request, conversationID: profile.id)
            // The event below only says yes/no; the audit also needs HOW (once, session, standing grant).
            audit?.record("approval.decision", [
                "request_id": .string(request.id.uuidString),
                "decision": .string(decision.auditName),
                "mode": .string(await MainActor.run { approvalCenter.mode.rawValue }),
            ])
            yield(.approvalResolved(id: request.id, approved: decision.isApproval))
            guard decision.isApproval else {
                return finish(.denied, error: "You declined to run '\(call.name)'.")
            }
        }

        // Behavior-monitor hold. Placed after every policy and approval decision: a call that was
        // refused never needs a hold, and one that survived them all still gets a second look if it
        // tripped a wire. This pauses THIS run only; no other run is touched.
        // Severe findings from the model-based monitor's recent passes join the hold here: this is
        // the next call about to run, so it is where an advisory finding can ask a human.
        let modelFindings = monitor.enabled ? (findings?.takeAtOrAbove(monitor.pauseAtSeverity) ?? []) : []
        let allFlags = flags + modelFindings
        let worst = Tripwires.worstSeverity(allFlags)
        if monitor.enabled, worst >= monitor.pauseAtSeverity {
            let held = allFlags.filter { $0.severity >= monitor.pauseAtSeverity }
                .map { flag in
                    let origin = flag.source == "model" ? " (monitor model, recent activity)" : ""
                    return "• [\(flag.category), severity \(flag.severity)]\(origin) \(flag.rationale)"
                }
                .joined(separator: "\n")
            let review = ApprovalRequest(
                toolName: spec.name,
                toolSummary: spec.summary,
                argumentsJSON: call.arguments,
                permission: spec.permission,
                isDestructive: spec.isDestructive,
                preview: ApprovalPreview.preview(for: spec, argumentsJSON: call.arguments),
                consequences: "The behavior monitor held this call before it ran:\n" + held,
                isMonitorReview: true
            )
            record.status = .awaitingApproval
            audit?.record("monitor.paused", [
                "request_id": .string(review.id.uuidString),
                "call_id": .string(call.id),
                "tool": .string(call.name),
                "severity": .int(worst),
            ])
            yield(.awaitingApproval(review))
            let decision = await approvalCenter.requestReview(review, conversationID: profile.id)
            audit?.record("monitor.review", [
                "request_id": .string(review.id.uuidString),
                "decision": .string(decision.auditName),
            ])
            yield(.approvalResolved(id: review.id, approved: decision.isApproval))
            guard decision.isApproval else {
                return finish(.denied, error: "The behavior monitor held '\(call.name)' for review and it was declined.")
            }
        }

        if stop.stopped { throw AgentRunError.stopped }

        let context = ToolExecutionContext(
            workspaceRoot: workspaceRoot,
            conversationID: profile.id,
            redactSecrets: profile.redactSecrets,
            services: services
        )

        do {
            let raw = try await withThrowingTimeout(
                seconds: min(300, toolTimeout),
                toolName: spec.name
            ) {
                try await tool.execute(argumentsJSON: call.arguments, context: context)
            }
            let fitted = ToolOutputCap.fit(raw, from: spec.name)
            return finish(.succeeded, result: fitted)
        } catch let error as AgentRunError {
            return finish(.failed, error: error.description)
        } catch {
            return finish(.failed, error: "Tool failed: \(String(describing: error).prefix(500))")
        }
    }

    static func consequences(
        for spec: ToolSpec,
        args: [String: Any],
        kind: ApprovalKind?
    ) -> String {
        if let kind {
            switch kind {
            case .writeOutsideScope:
                return "Writes to '\(args["path"] as? String ?? "?")', which is outside the configured write scope."
            case .riskyShell:
                return "Runs a command that matches a risk pattern the policy gates."
            case .networkNewDomain:
                return "Fetches from '\((args["url"] as? String).flatMap { URL(string: $0)?.host() } ?? "?")', a host that is not on the egress allowlist."
            case .spendOverHalfBudget:
                return "Past half the run budget."
            }
        }
        switch spec.permission {
        case .read: return "Reads from the workspace."
        case .write: return "Writes or modifies files in the workspace."
        case .execute: return "Runs a command or reaches the network."
        case .admin: return "Acts beyond the workspace — anything the user can act on."
        }
    }

    static func grantValue(for toolName: String, args: [String: Any]) -> (value: String?, kind: AgentGrant.Kind?) {
        switch toolName {
        case "web_fetch":
            guard let urlString = args["url"] as? String,
                  let host = URL(string: urlString)?.host()?.lowercased() else { return (nil, nil) }
            return (host, .egressHost)
        case "run_command", "stream_command", "background_command":
            guard let command = args["command"] as? String, !command.isEmpty else { return (nil, nil) }
            return (command, .shellCommand)
        default:
            return (toolName, .tool)
        }
    }
}

// MARK: - Tool-family detectors

enum WritePathChecker {
    static let writeTools: Set<String> = ["write_file", "edit_file", "delete_file", "git_commit", "git_branch"]
    static func isWriteTool(_ name: String) -> Bool { writeTools.contains(name) }
}

enum ShellCommandChecker {
    static let shellTools: Set<String> = ["run_command", "stream_command", "background_command"]
    static func isShellTool(_ name: String) -> Bool { shellTools.contains(name) }
}

// MARK: - Approval preview

/// Renders a tool call's arguments as a short, human-readable preview — a
/// command line, a file path, a diff summary.
enum ApprovalPreview {
    static func preview(for spec: ToolSpec, argumentsJSON: String) -> String {
        guard let obj = ToolArgs.object(from: argumentsJSON) else { return argumentsJSON }
        switch spec.name {
        case "run_command", "stream_command", "background_command":
            return (obj["command"] as? String) ?? argumentsJSON
        case "write_file":
            let path = (obj["path"] as? String) ?? "?"
            let content = (obj["content"] as? String) ?? ""
            return "Write \(path) (\(content.utf8.count) bytes)\n\n" + String(content.prefix(2_000))
        case "edit_file":
            let path = (obj["path"] as? String) ?? "?"
            let find = (obj["find"] as? String) ?? ""
            let replace = (obj["replace"] as? String) ?? ""
            return "Edit \(path)\n\n--- find ---\n\(find)\n\n--- replace ---\n\(replace)"
        case "delete_file":
            return "Delete \((obj["path"] as? String) ?? "?")"
        case "git_commit":
            return "Commit staged changes: \((obj["message"] as? String) ?? "")"
        case "web_fetch", "web_search":
            return (obj["url"] as? String) ?? (obj["query"] as? String) ?? argumentsJSON
        default:
            return argumentsJSON
        }
    }
}
