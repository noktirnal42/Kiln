import Foundation

/// What Kiln may tell the person outside its own window.
public enum NotificationEvent: Equatable, Sendable {
    /// An agent run needs an approval and Kiln is not the front app.
    case approval
    /// A run ended: finished, failed, or paused at its step limit.
    case runFinished(RunOutcome, seconds: Double)
    case scheduledTaskFinished
    /// A message the agent chose to send with `notify_user`.
    case agentMessage

    public enum RunOutcome: String, Equatable, Sendable { case completed, failed, paused }
}

public enum NotificationLevel: String, Equatable, Sendable {
    /// Banner and sound as the system's settings allow.
    case active
    /// Delivered quietly to the notification list: no banner, no sound.
    case passive
}

/// The person's Focus (Do Not Disturb and its siblings) as far as Kiln can tell. Reading it is optional and the system decides what
/// actually gets through; Kiln only uses it to hold back notices that can wait.
public enum UserFocusState: Equatable, Sendable {
    case focused, notFocused
    /// The person has not allowed Kiln to read Focus status (or macOS refused).
    case notAuthorized
    /// This macOS does not offer the status.
    case unavailable
    /// Authorized, but the system gave no answer.
    case unknown
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var approvals = true
    public var runFinished = true
    public var scheduledTasks = true
    public var agentMessages = true
    /// Hold finished-run, scheduled-task and agent notices while Focus is on (approvals are still sent; the system's own Focus filter then decides).
    public var quietDuringFocus = true
    /// A run shorter than this does not notify when it ends: the person was probably still watching.
    public var minimumRunSeconds = 30.0

    public init() {}
}

public enum NotificationDecision: Equatable, Sendable {
    case post(NotificationLevel)
    case hold(String)
}

/// The rules, as a pure function so they can be tested without a window or a notification center.
public enum NotificationPolicy {
    public static func decide(_ event: NotificationEvent, appIsActive: Bool, focus: UserFocusState,
                              preferences: NotificationPreferences, urgency: NotificationLevel = .active) -> NotificationDecision {
        switch event {
        case .approval:
            guard preferences.approvals else { return .hold("Approval notifications are turned off in Settings.") }
            // A visible approval sheet is enough while Kiln is in front. In Focus the system's own filter decides, so an approval is still sent.
            return appIsActive ? .hold("Kiln is in front.") : .post(.active)
        case .runFinished(_, let seconds):
            guard preferences.runFinished else { return .hold("Run notifications are turned off in Settings.") }
            if appIsActive { return .hold("Kiln is in front.") }
            if seconds < preferences.minimumRunSeconds { return .hold("The run was short.") }
            if preferences.quietDuringFocus, focus == .focused { return .hold("Focus is on.") }
            return .post(.active)
        case .scheduledTaskFinished:
            guard preferences.scheduledTasks else { return .hold("Scheduled-task notifications are turned off in Settings.") }
            if preferences.quietDuringFocus, focus == .focused { return .hold("Focus is on.") }
            return .post(.active)
        case .agentMessage:
            guard preferences.agentMessages else { return .hold("Messages from the agent are turned off in Settings.") }
            if appIsActive { return .hold("Kiln is in front, so the person can see the conversation.") }
            if preferences.quietDuringFocus, focus == .focused { return .hold("Focus is on.") }
            return .post(urgency)
        }
    }
}

/// Preferences kept in UserDefaults. With no defaults (tests) they live in memory.
public final class NotificationPreferenceStore: @unchecked Sendable {
    public static let key = "notifications.preferences.v1"
    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memory = NotificationPreferences()

    public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    public var preferences: NotificationPreferences {
        get {
            lock.lock(); defer { lock.unlock() }
            guard let defaults else { return memory }
            guard let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else { return NotificationPreferences() }
            return decoded
        }
        set {
            lock.lock(); defer { lock.unlock() }
            guard let defaults else { memory = newValue; return }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key)
        }
    }
}
