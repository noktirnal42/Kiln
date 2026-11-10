import Foundation

/// Plan mode: the agent explores with read-only tools, then proposes a plan. Nothing is written or run until the person
/// approves (optionally after editing) the plan; approval starts a normal run that carries it out.
/// Read-only is structural: the run uses `AgentMode.plan`, so write, execute and admin tools are neither offered nor
/// accepted, whatever the model asks for.
public struct PlanProposal: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var text: String
    /// What the person asked for, kept so the card can say what the plan is for.
    public var request: String
    public var createdAt = Date()
}

public enum PlanMode {
    public static let instructions = """


    # Plan mode
    You are in plan mode. Explore with read-only tools (read files, search, git status/log/diff) and do not try to change anything: write, command and network tools are not available. \
    When you understand the task, reply with a concise plan: a short goal line, then a numbered list of concrete steps naming the files and commands involved, then any risks or open questions. \
    The user will approve or edit the plan before anything is changed. Do not claim to have made changes.
    """

    /// The message that starts the real run once a plan is approved.
    public static func approvedPrompt(plan: String) -> String {
        "The plan below is approved. Carry it out now, step by step, and report what you did and what you could not verify.\n\n\(plan)"
    }

    /// `/plan`, `/plan on`, `/plan off` → the new state (nil = toggle).
    public static func parse(_ arguments: String) -> Bool? {
        switch arguments.lowercased() {
        case "on", "start", "enter": return true
        case "off", "exit", "stop": return false
        default: return nil
        }
    }
}
