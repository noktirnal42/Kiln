import SwiftUI

/// What Kiln may tell you outside its window, and whether it may look at your Focus. Nothing is requested until you press a button.
struct NotificationSettingsCard: View {
    @State private var preferences = NotificationCoordinator.shared.preferences
    @State private var status: NotificationCoordinator.Status?
    @State private var message: String?

    private var coordinator: NotificationCoordinator { .shared }

    private func binding<T>(_ path: WritableKeyPath<NotificationPreferences, T>) -> Binding<T> {
        Binding(get: { preferences[keyPath: path] }, set: { preferences[keyPath: path] = $0; coordinator.preferences = preferences })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("Notifications").font(SSTypography.headline())
            HStack(spacing: 6) {
                Image(systemName: allowed ? "checkmark.circle.fill" : "bell.slash").foregroundStyle(allowed ? SSColor.success : .secondary)
                Text(permissionText).font(SSTypography.caption())
            }
            Toggle("An agent needs your approval", isOn: binding(\.approvals))
            Toggle("A run finishes, fails or pauses", isOn: binding(\.runFinished))
            Toggle("A scheduled task finishes", isOn: binding(\.scheduledTasks))
            Toggle("The agent sends you a message", isOn: binding(\.agentMessages))
            Toggle("Hold finished-run, scheduled and agent notices while Focus is on", isOn: binding(\.quietDuringFocus))
            Stepper(value: binding(\.minimumRunSeconds), in: 0...600, step: 15) {
                Text("Tell me about runs longer than \(Int(preferences.minimumRunSeconds)) s")
            }
            Text("Kiln only sends these when it is not the front app. Approvals are still sent in Focus, and the system's own Focus settings then decide what shows. Notifications from other apps are not visible to Kiln.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            HStack {
                Button("Allow notifications") { Task { _ = await coordinator.requestNotificationPermission(); await refresh() } }.disabled(allowed)
                Button("Open Notification settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
                Button("Send a test") { Task { await sendTest() } }
            }
            if let message { Text(message).font(SSTypography.caption()).foregroundStyle(.secondary) }
            Divider()
            Text("Focus").font(SSTypography.headline())
            Text(focusText).font(SSTypography.caption())
            Text("Optional and experimental: macOS asks you before Kiln can read whether a Focus is on. Developers report it may read \"off\" while a Focus is on unless the app has the Communication Notifications capability, which Kiln does not have, so treat it as a hint.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            Button("Let Kiln read Focus status") { Task { _ = await coordinator.requestFocusPermission(); await refresh() } }
                .disabled(status?.focus != .notAuthorized)
        }
        .padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading).ssPanel()
        .task { await refresh() }
    }

    private var allowed: Bool { status?.authorization == .allowed }

    private var permissionText: String {
        switch status?.authorization {
        case .allowed: "macOS allows Kiln to send notifications."
        case .denied: "Notifications for Kiln are turned off in System Settings."
        case .notDetermined: "Kiln has not asked macOS yet. It asks the first time it needs to, or when you press Allow."
        case nil: "Checking…"
        }
    }

    private var focusText: String {
        guard let focus = status?.focus else { return "Checking…" }
        return NotificationTool.describe(focus) + "."
    }

    private func refresh() async { status = await coordinator.status() }

    private func sendTest() async {
        let result = await coordinator.deliver(.agentMessage, title: "Kiln test", body: "This is what a notice from Kiln looks like.", urgency: .active)
        await refresh()
        message = switch result {
        case .sent: "Sent. If you do not see it, Kiln may be in front, or Focus or System Settings is hiding it."
        case .held(let reason): "Held back: \(reason) (a real test needs Kiln to be in the background: switch to another app first, or turn off the hold)."
        case .notAllowed: "macOS has not allowed notifications for Kiln."
        case .rateLimited: "Too many notices recently."
        }
    }
}
