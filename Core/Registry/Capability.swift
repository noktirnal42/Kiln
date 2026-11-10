import Foundation

/// One thing a module can do, for the GUI and for agents alike.
///
/// The integration rule: every capability is either an agent tool (and therefore an MCP tool, since MCP lists the same
/// registry) or carries a written reason it has none. Exemptions are tracked gaps, listed in
/// `docs/13-AGENT-CAPABILITY-MATRIX.md`; a test fails when a capability has neither.
struct Capability: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    /// The activity that owns it. Filled in by `ActivityRegistry`, so a module never repeats its own id.
    var module: String = ""
    let permission: ToolPermissionLevel
    /// The agent tool name (`browser_open`), or nil with an `exemption`.
    let agentTool: String?
    /// Why there is no agent tool: a specific, written reason (not "n/a"). Nil when there is a tool.
    let exemption: String?
    /// True for a tool that exists only inside one run (a swarm worker's coordination tools). It is an agent tool but is
    /// not in the shared registry, so MCP does not list it; `exemption` then says why that is right.
    var workerScoped = false

    /// A capability served by an agent tool. The id is the tool name.
    static func tool(_ name: String, _ title: String, _ permission: ToolPermissionLevel) -> Capability {
        Capability(id: name, title: title, permission: permission, agentTool: name, exemption: nil)
    }

    /// A tool bound to one worker's run, so not served over MCP (outside agents have no worker identity to speak as).
    static func workerTool(_ name: String, _ title: String, _ permission: ToolPermissionLevel, because reason: String) -> Capability {
        Capability(id: name, title: title, permission: permission, agentTool: name, exemption: reason, workerScoped: true)
    }

    /// A GUI action or service entry point with no agent tool, and the reason.
    static func exempt(_ id: String, _ title: String, _ permission: ToolPermissionLevel, because reason: String) -> Capability {
        Capability(id: id, title: title, permission: permission, agentTool: nil, exemption: reason)
    }
}
