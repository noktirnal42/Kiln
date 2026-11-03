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
        session.onPairingChanged = { WatchHandoff.shared.publish($0); BackgroundKeeper.shared.wanted = ($0 != nil) }
        BackgroundKeeper.shared.wanted = session.mac != nil
        WatchBridge.shared.attach(session)
        WatchHandoff.shared.activate()
        WatchHandoff.shared.publish(session.mac)
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
                Task { await Notifier.shared.refreshAuthorization() }
                endBackgroundTask()
                session.resume()
                WatchHandoff.shared.resend()
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

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Self.session?.pushToken = token }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("KilnRemote: push registration failed: %@", error.localizedDescription)
        Task { @MainActor in Notifier.shared.registrationError = error.localizedDescription }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []   // in the foreground the approval card is already on screen
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["approvalID"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            guard let session = Self.session else { return }
            let decision: RemoteApprovalDecision? = action == Notifier.allowAction ? .allowOnce : action == Notifier.denyAction ? .deny : nil
            guard let decision else { return }
            // Keep the app running long enough to reconnect and answer when it was woken just for this tap.
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "kiln-approval-answer") { UIApplication.shared.endBackgroundTask(task) }
            session.decideFromNotification(id, decision)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
