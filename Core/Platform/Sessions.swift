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
    func runFinished(conversation: String, outcome: NotificationEvent.RunOutcome, seconds: Double)
}

extension AttentionSink {
    public func scheduledTaskFinished(name: String) {}
    public func runFinished(conversation: String, outcome: NotificationEvent.RunOutcome, seconds: Double) {}
}

/// Sends the notices through `NotificationCoordinator`, which applies the person's preferences, Focus and whether Kiln is in front.
@MainActor
public final class SystemAttentionSink: AttentionSink {
    private let coordinator: NotificationCoordinator
    public init(coordinator: NotificationCoordinator = .shared) { self.coordinator = coordinator }

    public func needsApproval(tool: String, conversation: String, pending: Int) {
        NSApp?.dockTile.badgeLabel = "\(pending)"
        let coordinator = coordinator
        Task { await coordinator.deliver(.approval, title: "Kiln needs your approval", body: "\(conversation): the agent wants to use \(tool).", id: "kiln.approval") }
    }

    public func scheduledTaskFinished(name: String) {
        let coordinator = coordinator
        Task { await coordinator.deliver(.scheduledTaskFinished, title: "Scheduled task finished", body: name, id: "kiln.schedule.\(UUID().uuidString)") }
    }

    public func runFinished(conversation: String, outcome: NotificationEvent.RunOutcome, seconds: Double) {
        let title: String
        switch outcome {
        case .completed: title = "Kiln finished"
        case .failed: title = "Kiln stopped with an error"
        case .paused: title = "Kiln paused and is waiting for you"
        }
        let coordinator = coordinator
        Task { await coordinator.deliver(.runFinished(outcome, seconds: seconds), title: title, body: conversation, id: "kiln.run.\(UUID().uuidString)") }
    }

    public func cleared(pending: Int) {
        NSApp?.dockTile.badgeLabel = pending > 0 ? "\(pending)" : nil
        if pending == 0 { coordinator.clearApprovalNotice() }
    }
}
