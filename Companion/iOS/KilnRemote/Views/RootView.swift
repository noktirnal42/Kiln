import KilnRemoteKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.mac == nil {
                PairingView()
            } else {
                ConversationsView()
            }
        }
        .onAppear { wireNotifications() }
    }

    private func wireNotifications() {
        let previous = session.onApprovalRequested
        session.onApprovalRequested = { approval in
            previous?(approval)
            if UIApplication.shared.applicationState != .active { Notifier.shared.notify(approval) }
        }
    }
}

/// Connection state as a compact line; tappable to retry when something is wrong.
struct StatusBanner: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        switch session.status {
        case .connected, .unpaired:
            EmptyView()
        case .connecting:
            banner(session.attemptStatus ?? "Connecting to \(session.hostName ?? "your Mac")…", systemImage: "antenna.radiowaves.left.and.right", tint: .secondary)
        case .reconnecting(let reason):
            banner(session.attemptStatus.map { "Reconnecting. \($0)" } ?? "Reconnecting… \(reason)", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
        case .needsRepairing:
            VStack(alignment: .leading, spacing: 6) {
                banner("Your Mac no longer accepts this phone. Scan its pairing code again.", systemImage: "exclamationmark.triangle.fill", tint: .red)
                Button("Pair again") { session.unpair() }.buttonStyle(.borderedProminent)
                    .accessibilityHint("Removes the saved pairing and opens the pairing screen")
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
