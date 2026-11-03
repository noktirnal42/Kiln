import Foundation
import KilnRemoteKit
import Observation
import UIKit
import UserNotifications

/// Local notifications for approvals that arrive while the app is not in front. Works as long as the app is still
/// connected (iOS keeps it alive for a short while after backgrounding, and during hands-free audio); a push
/// through Apple's servers would need a relay and is not part of this version.
@MainActor
@Observable
final class Notifier {
    static let shared = Notifier()
    /// What iOS currently allows for this app's notifications, in words.
    private(set) var authorization = "Checking…"
    private(set) var isAllowed = false
    /// Set when Apple could not issue a push token (for example the app is not provisioned for push).
    var registrationError: String?
    static let allowAction = "KILN_ALLOW", denyAction = "KILN_DENY", category = "KILN_APPROVAL"

    func prepare() async {
        let center = UNUserNotificationCenter.current()
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow once", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [allow, deny], intentIdentifiers: [])])
        _ = try? await center.requestAuthorization(options: [.alert, .sound])   // asks only the first time
        await refreshAuthorization()
        // The token is requested whatever the answer, so the Mac always has it; alerts only show if notifications are allowed.
        UIApplication.shared.registerForRemoteNotifications()
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorization = "Allowed"; isAllowed = true
        case .denied: authorization = "Turned off in Settings"; isAllowed = false
        case .notDetermined: authorization = "Not asked yet"; isAllowed = false
        @unknown default: authorization = "Unknown"; isAllowed = false
        }
    }

    /// Opens this app's page in iOS Settings, where Notifications can be turned on.
    func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }

    func notify(_ approval: RemoteApproval) {
        let content = UNMutableNotificationContent()
        content.title = "Kiln needs approval"
        content.body = "\(approval.tool) (\(approval.permission)): \(approval.preview)"
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["approvalID": approval.id]
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-\(approval.id)", content: content, trigger: nil))
    }

    func clear(_ approvalID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval-\(approvalID)"])
    }
}
