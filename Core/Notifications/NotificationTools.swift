import Foundation

/// Tools for telling the person something outside Kiln's window, and for checking whether that is welcome right now.
/// `notify_user` is a write: it interrupts a person, so it asks in Ask mode, is rate limited, and is prefixed so an agent cannot pass
/// itself off as a system alert.
public struct NotificationTool: ToolExecuting {
    public enum Kind: String, CaseIterable, Sendable { case notify = "notify_user", status = "notifications_status" }
    public let kind: Kind
    let coordinator: @Sendable @MainActor () -> NotificationCoordinator

    public init(kind: Kind, coordinator: @escaping @Sendable @MainActor () -> NotificationCoordinator = { .shared }) { self.kind = kind; self.coordinator = coordinator }

    public static func register(into registry: ToolRegistry, coordinator: @escaping @Sendable @MainActor () -> NotificationCoordinator = { .shared }) {
        for kind in Kind.allCases { registry.register(NotificationTool(kind: kind, coordinator: coordinator)) }
    }

    public var spec: ToolSpec {
        switch kind {
        case .notify: ToolSpec(name: "notify_user", summary: "Send the person a system notification, for example when a long job you started is done or you need them. It is held back when Kiln is in front, when the person turned agent notices off, or when Focus is on; at most 5 are sent in 10 minutes. Plain text only.",
                               parameters: [ToolParam(name: "title", description: "Short title (up to 80 characters)"), ToolParam(name: "body", description: "What the person should know (up to 300 characters)"),
                                            ToolParam(name: "urgency", description: "normal (banner) or quiet (delivered without a banner); default normal", required: false)], permission: .write)
        case .status: ToolSpec(name: "notifications_status", summary: "Say whether Kiln may send system notifications, whether the person's Focus is on (when they allowed Kiln to read it), and which notices are turned on. Check this before deciding to notify.", permission: .read)
        }
    }

    /// A single line of plain text: control characters and runs of whitespace become single spaces, clipped to a length.
    static func plain(_ text: String, limit: Int) -> String {
        let cleaned = text.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    static func describe(_ focus: UserFocusState) -> String {
        switch focus {
        case .focused: "Focus is on"
        case .notFocused: "Focus is off (macOS may report this even when Focus is on, unless Kiln has the Communication Notifications capability)"
        case .notAuthorized: "Kiln has not been allowed to read Focus status"
        case .unavailable: "Focus status is not available on this macOS"
        case .unknown: "Focus status is unknown"
        }
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        switch kind {
        case .status:
            let s = await coordinator().status()
            let permission = switch s.authorization { case .allowed: "allowed"; case .denied: "denied in System Settings"; case .notDetermined: "not asked yet" }
            let p = s.preferences
            return """
            System notifications: \(permission).
            \(Self.describe(s.focus)).
            Kiln's own notices in Notification Center: \(s.deliveredByKiln).
            Turned on: approvals \(p.approvals ? "yes" : "no"), finished runs \(p.runFinished ? "yes" : "no"), scheduled tasks \(p.scheduledTasks ? "yes" : "no"), messages from the agent \(p.agentMessages ? "yes" : "no"); quiet during Focus \(p.quietDuringFocus ? "yes" : "no").
            """
        case .notify:
            let title = Self.plain(args["title"] as? String ?? "", limit: 80)
            let body = Self.plain(args["body"] as? String ?? "", limit: 300)
            guard !title.isEmpty else { throw AgentRunError.permissionDenied("A title is required.") }
            let urgency: NotificationLevel = (args["urgency"] as? String)?.lowercased() == "quiet" ? .passive : .active
            let result = await coordinator().deliver(.agentMessage, title: "Kiln agent: \(title)", body: body, urgency: urgency)
            switch result {
            case .sent: return "Sent."
            case .held(let reason): return "Not sent as a system notification: \(reason)"
            case .notAllowed: return "Not sent: macOS has not allowed Kiln to send notifications. The person can allow them in Settings, Notifications."
            case .rateLimited: return "Not sent: too many notices in the last 10 minutes (the limit is \(NotificationCoordinator.agentLimit))."
            }
        }
    }
}
