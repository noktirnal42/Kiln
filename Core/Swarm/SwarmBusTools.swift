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
                    + " You work in a team. Use swarm_post to share progress, swarm_report_blocker if you cannot continue, and finish with a short plain summary of your result.",
                mode: task.role == .implementer ? .act : .review,
                modelID: modelID,
                toolPermissions: ToolPermissionSet(
                    enabledTools: task.role.tools.union(["swarm_*"]),
                    policyByLevel: ToolPermissionSet.conservativeDefaults
                ),
                runTimeoutSeconds: 900
            )
            var finalText = ""
            for try await event in orchestrator.run(profile: profile, prompt: prompt, workspaceRoot: workspaceRoot, chat: chat) {
                if case .finished(let summary) = event { finalText = summary.finalText }
            }
            if let reason = blocker.reason { throw SwarmBlocked(reason) }
            return finalText
        }
    }
}
