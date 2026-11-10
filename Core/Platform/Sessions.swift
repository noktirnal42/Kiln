import Foundation
import AppKit
import UserNotifications

/// What a conversation is doing right now.
public enum SessionState: String, Codable, Sendable {
    case idle, running, waitingForApproval
    public var label: String {
        switch self { case .idle: return "Idle"; case .running: return "Running"; case .waitingForApproval: return "Waiting for approval" }
    }
}

public struct SessionRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var state: SessionState
    public var updatedAt: Date
    public var messageCount: Int
    public var modelID: String?
    public var isOpen: Bool
}

public enum SessionList {
    /// Conversations as sessions: running and waiting first, then newest.
    public static func rows(_ conversations: [ConversationSummary], states: [UUID: SessionState], open: UUID?) -> [SessionRow] {
        conversations.map {
            SessionRow(id: $0.id, title: $0.title, state: states[$0.id] ?? .idle, updatedAt: $0.updatedAt,
                       messageCount: $0.messageCount, modelID: $0.modelID, isOpen: $0.id == open)
        }.sorted {
            let a = $0.state == .idle ? 1 : 0, b = $1.state == .idle ? 1 : 0
            return a != b ? a < b : $0.updatedAt > $1.updatedAt
        }
    }
}

/// Tells the person that an agent needs them: a system notification and a Dock badge. A protocol so tests don't post real ones.
@MainActor
public protocol AttentionSink: AnyObject {
    func needsApproval(tool: String, conversation: String, pending: Int)
    func cleared(pending: Int)
    func scheduledTaskFinished(name: String)
}

extension AttentionSink { public func scheduledTaskFinished(name: String) {} }

@MainActor
public final class SystemAttentionSink: AttentionSink {
    private var asked = false
    public init() {}

    public func needsApproval(tool: String, conversation: String, pending: Int) {
        NSApp?.dockTile.badgeLabel = "\(pending)"
        // Only interrupt when Kiln isn't in front; a visible approval sheet is enough otherwise.
        guard NSApp?.isActive != true else { return }
        let center = UNUserNotificationCenter.current()
        if !asked { asked = true; center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in } }
        let content = UNMutableNotificationContent()
        content.title = "Kiln needs your approval"
        content.body = "\(conversation): the agent wants to use \(tool)."
        center.add(UNNotificationRequest(identifier: "kiln.approval", content: content, trigger: nil))
    }

    public func scheduledTaskFinished(name: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Scheduled task finished"
        content.body = name
        center.add(UNNotificationRequest(identifier: "kiln.schedule.\(UUID().uuidString)", content: content, trigger: nil))
    }

    public func cleared(pending: Int) {
        NSApp?.dockTile.badgeLabel = pending > 0 ? "\(pending)" : nil
        if pending == 0 { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["kiln.approval"]) }
    }
}
