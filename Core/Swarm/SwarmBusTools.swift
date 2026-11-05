import Foundation

/// Remembers that a worker declared itself blocked, so its run can end as a blocker, not a success.
final class BlockerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _reason: String?
    var reason: String? { lock.lock(); defer { lock.unlock() }; return _reason }
    func set(_ reason: String) { lock.lock(); _reason = reason; lock.unlock() }
}

/// The tools a swarm worker gets for talking to its teammates. Each is bound to that worker's own
/// endpoint, so it can only speak as itself. Messages are redacted and audited by the bus.
enum SwarmBusTools {
    static func make(endpoint: BusEndpoint, task: SwarmTask, blocker: BlockerBox) -> [any ToolExecuting] {
        [
            Tool(spec: ToolSpec(name: "swarm_post", summary: "Post a progress note or question for the rest of the team.",
                                parameters: [ToolParam(name: "message", description: "What to tell the team"),
                                             ToolParam(name: "kind", description: "progress (default) or question", required: false)],
                                permission: .read)) { args in
                let kind: CoordinationMessageType = (args["kind"] as? String) == "question" ? .question : .progress
                try await endpoint.publish(topic: "task/\(task.id)", type: kind, body: (args["message"] as? String) ?? "")
                return "Posted."
            },
            Tool(spec: ToolSpec(name: "swarm_read", summary: "Read recent team messages, optionally for one topic.",
                                parameters: [ToolParam(name: "topic", description: "e.g. swarm or task/research", required: false)],
                                permission: .read)) { args in
                let rows = await endpoint.history(topic: args["topic"] as? String, limit: 30)
                return rows.isEmpty ? "No messages." : rows.map { "[\($0.from)/\($0.type.rawValue)] \($0.body)" }.joined(separator: "\n")
            },
            Tool(spec: ToolSpec(name: "swarm_memory_get", summary: "Read a value from the team's shared memory.",
                                parameters: [ToolParam(name: "key")], permission: .read)) { args in
                guard let key = args["key"] as? String, let value = await endpoint.readMemory(key) else { return "No value." }
                return "v\(value.version) by \(value.updatedBy): \(describe(value.value))"
            },
            Tool(spec: ToolSpec(name: "swarm_memory_set", summary: "Write a value to the team's shared memory for others to read.",
                                parameters: [ToolParam(name: "key"), ToolParam(name: "value")], permission: .read)) { args in
                guard let key = args["key"] as? String, let value = args["value"] as? String else { return "key and value are required." }
                let saved = try await endpoint.writeMemory(key, .string(value))
                return "Saved as version \(saved.version)."
            },
            Tool(spec: ToolSpec(name: "swarm_report_blocker", summary: "Say you cannot continue and why. Use this instead of guessing or looping; a human will see it.",
                                parameters: [ToolParam(name: "reason", description: "What is stopping you")], permission: .read)) { args in
                let reason = (args["reason"] as? String) ?? "unspecified"
                blocker.set(reason)
                try await endpoint.publish(topic: "swarm", type: .blocker, body: "\(task.id): \(reason)")
                return "Blocker reported. Stop work now and summarise where you got to."
            },
        ]
    }

    static func describe(_ value: AuditValue) -> String {
        switch value {
        case .string(let text): text
        default: (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    struct Tool: ToolExecuting {
        let spec: ToolSpec
        let body: @Sendable ([String: Any]) async throws -> String
        init(spec: ToolSpec, body: @escaping @Sendable ([String: Any]) async throws -> String) {
            self.spec = spec; self.body = body
        }
        func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
            try await body(ToolArgs.object(from: argumentsJSON) ?? [:])
        }
    }
}

public enum SwarmWorkers {
    /// A worker that runs a real agent for each task, under a profile that fits the task's role.
    /// Tool calls go through the same gates as any other agent run: policy, approvals, monitor, audit.
    public static func agent(
        base: AgentOrchestrator,
        modelID: String,
        workspaceRoot: URL?,
        chat: @escaping @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error>
    ) -> SwarmOrchestrator.Worker {
        { task, prompt, endpoint in
            let blocker = BlockerBox()
            let orchestrator = base.withTools(SwarmBusTools.make(endpoint: endpoint, task: task, blocker: blocker))
            let profile = AgentProfile(
                name: "Swarm \(task.role.rawValue)", iconSymbol: "person.3",
                systemPrompt: task.role.instructions
                    + " You work in a team. Use only the tools actually provided through the tool-call protocol. Never invent functions or simulate a tool call in your answer. Use swarm_post to share progress, swarm_report_blocker if you cannot continue, and finish with a short plain summary containing the result and evidence. Reviewers must independently check earlier results and explicitly report discrepancies.",
                mode: task.role == .implementer ? .act : .review,
                modelID: modelID,
                toolPermissions: ToolPermissionSet(
                    enabledTools: task.role.tools.union(["swarm_*"]),
                    policyByLevel: ToolPermissionSet.conservativeDefaults
                ),
                runTimeoutSeconds: 900
            )
            var finalText = ""
            var collector = RunEvidenceCollector(toolsOffered: Array(profile.toolPermissions.enabledTools))
            for try await event in orchestrator.run(profile: profile, prompt: prompt, workspaceRoot: workspaceRoot, chat: chat) {
                collector.record(event)
                if case .finished(let summary) = event { finalText = summary.finalText }
            }
            if let reason = blocker.reason { throw SwarmBlocked(reason) }
            let evidence = collector.evidence
            let simulated = (try? validateSummary(finalText)) == nil && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let failure = RunVerifier.verdict(evidence: evidence, summary: finalText, role: task.role,
                                                 expectations: task.expects.compactMap(TaskExpectation.init),
                                                 workspace: workspaceRoot, simulatedToolCall: simulated) {
                throw SwarmBlocked(failure.description + " (\(evidence.summaryLine))")
            }
            try validateSummary(finalText)
            // The evidence line travels with the result, so a reviewer sees what the earlier worker really did.
            return finalText + "\n[\(evidence.summaryLine)]"
        }
    }

    static func validateSummary(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwarmBlocked("The worker returned no result.") }
        if SimulatedToolCall.isSimulated(trimmed) {
            throw SwarmBlocked("The worker returned a simulated tool call instead of a verified result. Try a model with stronger tool support.")
        }
    }
}

/// Recognises a whole answer that is only a tool call written out as text, in the shapes small models produce:
/// `{"name":…,"arguments":…}`, `parameters`/`args`/`input` instead of `arguments`, OpenAI `{"function":{…}}` and
/// `{"tool_calls":[…]}`, arrays of calls, Hermes/Qwen `<tool_call>` tags and Mistral `[TOOL_CALLS]`. Ordinary JSON
/// results (no call shape) and prose that merely mentions a tool are not flagged.
enum SimulatedToolCall {
    static func isSimulated(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<tool_call>") || lower.hasPrefix("[tool_calls]") || lower.hasPrefix("<|python_tag|>") { return true }
        let payload = unfence(trimmed)
        guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return looksLikeCall(object)
    }

    private static func unfence(_ text: String) -> String {
        var t = text
        if t.hasPrefix("```") {
            t = String(t.drop(while: { $0 == "`" }))
            if let newline = t.firstIndex(of: "\n"), !t[..<newline].contains("{"), !t[..<newline].contains("[") { t = String(t[t.index(after: newline)...]) }
            while t.hasSuffix("`") { t.removeLast() }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeCall(_ value: Any) -> Bool {
        if let array = value as? [Any] { return !array.isEmpty && array.allSatisfy(looksLikeCall) }
        guard let object = value as? [String: Any] else { return false }
        if object["tool_calls"] != nil { return true }
        if let function = object["function"] as? [String: Any] { return looksLikeCall(function) }
        let named = object["name"] is String || object["tool"] is String || object["tool_name"] is String || object["function_name"] is String
        let carriesArguments = ["arguments", "parameters", "args", "input"].contains { object[$0] != nil }
        return named && carriesArguments
    }
}
