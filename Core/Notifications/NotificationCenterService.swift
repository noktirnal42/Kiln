import Foundation
import AppKit
import UserNotifications
import Intents

public enum NotificationAuthorization: Equatable, Sendable { case notDetermined, denied, allowed }

public struct OutgoingNotification: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var level: NotificationLevel
    public init(id: String = UUID().uuidString, title: String, body: String, level: NotificationLevel = .active) {
        self.id = id; self.title = title; self.body = body; self.level = level
    }
}

/// Posts to the system's Notification Center. A protocol, so tests never post a real notification.
@MainActor
public protocol NotificationPosting: AnyObject {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> Bool
    func post(_ notification: OutgoingNotification) async -> Bool
    func deliveredCount() async -> Int
    func remove(ids: [String])
}

@MainActor
public final class SystemNotificationPoster: NotificationPosting {
    public init() {}
    private var center: UNUserNotificationCenter { .current() }

    public func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    public func post(_ notification: OutgoingNotification) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.interruptionLevel = notification.level == .passive ? .passive : .active
        if notification.level == .active { content.sound = nil }
        do { try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)); return true }
        catch { return false }
    }

    /// Only Kiln's own notifications can be counted: macOS gives an app no view of anyone else's.
    public func deliveredCount() async -> Int { await center.deliveredNotifications().count }
    public func remove(ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}

/// Reads Focus status. Apple asks for explicit permission, and developers report that macOS may need the Communication Notifications
/// capability before `isFocused` is accurate, which Kiln does not have: so a "not focused" answer is not proof. Treat it as a hint.
@MainActor
public protocol FocusStatusProviding: AnyObject {
    func state() async -> UserFocusState
    func requestAuthorization() async -> UserFocusState
}

@MainActor
public final class SystemFocusStatus: FocusStatusProviding {
    public init() {}

    public func state() async -> UserFocusState {
        let center = INFocusStatusCenter.default
        switch center.authorizationStatus {
        case .authorized:
            guard let focused = center.focusStatus.isFocused else { return .unknown }
            return focused ? .focused : .notFocused
        case .notDetermined, .denied, .restricted: return .notAuthorized
        @unknown default: return .unknown
        }
    }

    public func requestAuthorization() async -> UserFocusState {
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { _ in continuation.resume() }
        }
        return await state()
    }
}

/// Decides, posts and remembers. One instance serves the whole app (`shared`); tests make their own with fakes.
@MainActor
public final class NotificationCoordinator {
    public static let shared = NotificationCoordinator()

    public let preferenceStore: NotificationPreferenceStore
    private let poster: any NotificationPosting
    private let focus: any FocusStatusProviding
    private let isAppActive: () -> Bool
    private let now: () -> Date
    private var agentSends: [Date] = []
    /// The agent may send this many notices in a window, so a loop cannot flood Notification Center.
    public nonisolated static let agentLimit = 5
    public nonisolated static let agentWindow: TimeInterval = 600

    public init(preferenceStore: NotificationPreferenceStore = NotificationPreferenceStore(), poster: any NotificationPosting = SystemNotificationPoster(),
                focus: any FocusStatusProviding = SystemFocusStatus(), isAppActive: @escaping () -> Bool = { NSApp?.isActive == true }, now: @escaping () -> Date = Date.init) {
        self.preferenceStore = preferenceStore; self.poster = poster; self.focus = focus; self.isAppActive = isAppActive; self.now = now
    }

    public var preferences: NotificationPreferences {
        get { preferenceStore.preferences }
        set { preferenceStore.preferences = newValue }
    }

    public struct Status: Equatable, Sendable {
        public var authorization: NotificationAuthorization
        public var focus: UserFocusState
        public var preferences: NotificationPreferences
        public var deliveredByKiln: Int
    }

    public func status() async -> Status {
        Status(authorization: await poster.authorization(), focus: await focus.state(), preferences: preferences, deliveredByKiln: await poster.deliveredCount())
    }

    public func requestNotificationPermission() async -> Bool { await poster.requestAuthorization() }
    public func requestFocusPermission() async -> UserFocusState { await focus.requestAuthorization() }

    public enum Delivery: Equatable, Sendable {
        case sent
        case held(String)
        case notAllowed
        case rateLimited
    }

    /// Applies the rules and, when they say so, posts. Asks macOS for permission the first time a notice would go out.
    @discardableResult
    public func deliver(_ event: NotificationEvent, title: String, body: String, id: String = UUID().uuidString, urgency: NotificationLevel = .active) async -> Delivery {
        let state = await focus.state()
        switch NotificationPolicy.decide(event, appIsActive: isAppActive(), focus: state, preferences: preferences, urgency: urgency) {
        case .hold(let reason): return .held(reason)
        case .post(let level):
            if event == .agentMessage {
                let cutoff = now().addingTimeInterval(-Self.agentWindow)
                agentSends.removeAll { $0 < cutoff }
                guard agentSends.count < Self.agentLimit else { return .rateLimited }
            }
            if await poster.authorization() == .notDetermined { _ = await poster.requestAuthorization() }
            guard await poster.authorization() == .allowed else { return .notAllowed }
            guard await poster.post(OutgoingNotification(id: id, title: title, body: body, level: level)) else { return .notAllowed }
            if event == .agentMessage { agentSends.append(now()) }
            return .sent
        }
    }

    public func clearApprovalNotice() { poster.remove(ids: ["kiln.approval"]) }
}
