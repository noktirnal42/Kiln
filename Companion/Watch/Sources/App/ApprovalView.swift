import KilnRemoteKit
import SwiftUI

/// The other core flow: what the agent wants to do, and two big answers. "Always allow" is not offered here.
struct ApprovalView: View {
    let approval: RemoteApproval
    let decide: (RemoteApprovalDecision) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Label(approval.tool, systemImage: "exclamationmark.shield.fill")
                    .font(.headline).foregroundStyle(.orange).lineLimit(1)
                    .accessibilityLabel("Kiln wants to use \(approval.tool), permission \(approval.permission)")
                Text(approval.preview)
                    .font(.system(.footnote, design: .monospaced)).lineLimit(5)
                    .accessibilityLabel("Preview: \(approval.preview)")
                Button { decide(.allowOnce); dismiss() } label: {
                    Text("Allow once").frame(maxWidth: .infinity)
                }
                .tint(.green).buttonStyle(.borderedProminent)
                .accessibilityLabel("Allow once")
                .accessibilityHint("Lets Kiln run this one call")
                Button(role: .destructive) { decide(.deny); dismiss() } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Deny")
                .accessibilityHint("Refuses this call")
            }
        }
        .navigationTitle("Approve?")
    }
}
