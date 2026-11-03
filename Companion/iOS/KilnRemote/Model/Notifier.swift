import Foundation
import KilnRemoteKit
import UIKit
import UserNotifications

/// Local notifications for approvals that arrive while the app is not in front. Works as long as the app is still
/// connected (iOS keeps it alive for a short while after backgrounding, and during hands-free audio); a push
/// through Apple's servers would need a relay and is not part of this version.
@MainActor
final class Notifier {
    static let shared = Notifier()
    static let allowAction = "KILN_ALLOW", denyAction = "KILN_DENY", category = "KILN_APPROVAL"

    func prepare() async {
        let center = UNUserNotificationCenter.current()
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow once", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [allow, deny], intentIdentifiers: [])])
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        // Registers for Apple push so an approval can alert this phone (and its watch) while the app is closed.
        if granted { UIApplication.shared.registerForRemoteNotifications() }
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
