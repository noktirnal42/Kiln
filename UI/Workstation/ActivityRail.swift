import SwiftUI

/// The strip along the bottom. Answers three questions without opening anything: is the agent doing
/// something, is anything waiting on me, and is the audit record healthy.
struct StatusBar: View {
    @Bindable var workstation: WorkstationModel
    @Environment(AppModel.self) private var app

    var body: some View {
        // Audit health lives outside the observation system, so re-read it on a slow tick.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            bar
        }
        .frame(height: 24)
        .background(SSColor.surface)
        .overlay(alignment: .top) { Rectangle().fill(SSColor.hairline).frame(height: 1) }
    }

    private var bar: some View {
        let pending = app.approvalCenter.pending.count
        let state = WorkstationStatus.agentState(isStreaming: app.chatSession?.isStreaming ?? false,
                                                 pendingApprovals: pending)
        let audit = WorkstationStatus.audit(chainConfigured: app.auditChain != nil,
                                            droppedEntries: app.auditHealth.snapshot.dropped)
        return HStack(spacing: SSSpacing.m) {
            HStack(spacing: 6) {
                SSStatusDot(color: color(for: state), pulsing: state != .idle)
                Text(WorkstationStatus.agentLabel(state))
            }
            if let model = app.chatSession?.selectedModelID, !model.isEmpty {
                Label(model, systemImage: "cpu").labelStyle(.titleAndIcon).lineLimit(1)
            } else {
                Label("No model selected", systemImage: "cpu").foregroundStyle(.tertiary)
            }
            Spacer()
            if pending > 0 {
                statusButton("\(pending) waiting", symbol: "exclamationmark.shield", tint: SSColor.accent) {
                    workstation.showApprovals = true
                }
            }
            statusButton(audit.text, symbol: "checkmark.seal", tint: tint(for: audit.level)) {
                workstation.select(.audit, app: app)
            }
            Label("Tripwires on", systemImage: "shield.lefthalf.filled").foregroundStyle(.secondary)
            SSKeyCap("⌘K")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SSSpacing.m)
    }

    private func statusButton(_ text: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func color(for state: WorkstationStatus.AgentState) -> Color {
        switch state {
        case .idle: .secondary
        case .running: SSColor.accent
        case .awaitingApproval: SSColor.warning
        }
    }

    private func tint(for level: WorkstationStatus.Level) -> Color {
        switch level {
        case .ok: SSColor.success
        case .warning: SSColor.warning
        case .problem: SSColor.danger
        case .neutral: .secondary
        }
    }
}
