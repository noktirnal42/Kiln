import Foundation

/// Runs one agent tool call the same way for every transport (MCP, ACP): policy check, operation bookkeeping, cancellation
/// scope, provenance for any edits, and an audit entry. Blocking; transports call it from a worker queue.
public enum AgentRuntime {
    public struct Policy: Sendable {
        /// When true, tools that edit a project directly are refused and agents must use `propose_edit`.
        public var proposeOnly = false
        public init(proposeOnly: Bool = false) { self.proposeOnly = proposeOnly }
    }

    public struct Outcome: Sendable {
        public let operationId: String
        public let text: String
        public let isError: Bool
        public let cancelled: Bool
    }

    /// - Parameters:
    ///   - context: the operation (its id is what clients use to cancel); the caller creates it so it can register it before running.
    public static func execute(tool: String, arguments: [String: Any], context: OperationContext, client: String?, policy: Policy = Policy(),
                               audit: AuditLog? = AuditLog.shared, registry: OperationRegistry = .shared) -> Outcome {
        let started = Date()
        context.registry = registry
        registry.begin(context)
        func finish(_ state: OperationRecord.State, _ text: String, isError: Bool, detail: String? = nil, revision: Int? = nil) -> Outcome {
            registry.finish(context, state: state, detail: detail)
            let outcome = state == .completed ? "ok" : state == .cancelled ? "cancelled" : (detail == "refused" ? "refused" : "error")
            audit?.record(AuditEntry(operationId: context.id, transport: context.transport, client: client, tool: tool, readOnly: AgentTools.isReadOnly(tool),
                                     arguments: AuditLog.summarize(arguments: arguments), outcome: outcome, error: state == .completed ? nil : text,
                                     durationMs: Int(Date().timeIntervalSince(started) * 1000), project: arguments["project"] as? String, resultRevision: revision))
            return Outcome(operationId: context.id, text: text, isError: isError, cancelled: state == .cancelled)
        }
        if policy.proposeOnly && AgentTools.directEdits.contains(tool) {
            return finish(.failed, "This server runs in propose-only mode: use propose_edit so the analyst can review the change.", isError: true, detail: "refused")
        }
        do {
            let source = "agent:" + (client ?? context.transport)
            let text = try EditSource.$current.withValue(source) {
                try OperationContext.$current.withValue(context) { try AgentTools.call(tool, arguments) }
            }
            if context.isCancelled { return finish(.cancelled, "The operation was cancelled.", isError: true) }
            return finish(.completed, text, isError: false, revision: revision(in: text))
        } catch is OperationCancelled {
            return finish(.cancelled, "The operation was cancelled.", isError: true)
        } catch {
            if context.isCancelled { return finish(.cancelled, "The operation was cancelled.", isError: true) }
            return finish(.failed, error.localizedDescription, isError: true)
        }
    }

    /// The `revision` a mutating tool reports, when its JSON result carries one (used for the audit trail).
    static func revision(in text: String) -> Int? {
        guard text.hasPrefix("{"), let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return (object["revision"] as? NSNumber)?.intValue
    }
}
