import KilnRemoteKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct KilnRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: RemoteSession
    @State private var voice: VoiceController
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        let session = RemoteSession(store: KeychainPairingStore(), deviceName: UIDevice.current.name)
        _session = State(initialValue: session)
        _voice = State(initialValue: VoiceController(session: session))
        AppDelegate.session = session
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(voice)
                .task {
                    await Notifier.shared.prepare()
                    session.start()
                }
                .onOpenURL { url in
                    if let payload = PairingPayload(url: url) { session.pair(with: payload) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                endBackgroundTask()
                session.resume()
            case .background:
                // Keep the socket for a little while so an approval that arrives right after leaving can still notify.
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "kiln-remote-link") { [self] in endBackgroundTask() }
            default: break
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var session: RemoteSession?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []   // in the foreground the approval card is already on screen
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["approvalID"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            guard let session = Self.session, let approval = session.approvals.first(where: { $0.id == id }) else { return }
            if action == Notifier.allowAction { session.decide(approval, .allowOnce) }
            else if action == Notifier.denyAction { session.decide(approval, .deny) }
        }
    }
}
