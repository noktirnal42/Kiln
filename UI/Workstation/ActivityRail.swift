import SwiftUI

/// The vertical rail of activities. Compact on purpose: the work is in the middle, not here.
struct ActivityRail: View {
    @Bindable var workstation: WorkstationModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            Image("KilnMark")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .padding(.top, SSSpacing.s)
                .padding(.bottom, SSSpacing.s)
                .accessibilityHidden(true)

            ForEach(Activity.allCases) { activity in
                railButton(activity)
            }

            Spacer(minLength: SSSpacing.m)

            approvalsButton
            utilityButton(symbol: "command", help: "Command palette (⌘K)") { workstation.showPalette = true }
            utilityButton(symbol: workstation.dockVisible ? "sidebar.right" : "sidebar.right",
                          help: workstation.dockVisible ? "Hide agent dock (⌘⌥A)" : "Show agent dock (⌘⌥A)",
                          selected: workstation.dockVisible) { workstation.toggleDock() }
                .padding(.bottom, SSSpacing.s)
        }
        .frame(width: 52)
        .background(SSColor.surface)
    }

    private func railButton(_ activity: Activity) -> some View {
        let selected = workstation.selected == activity
        return Button {
            workstation.select(activity, app: app)
        } label: {
            Image(systemName: activity.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 36)
        }
        .buttonStyle(SSIconButtonStyle(selected: selected))
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(SSColor.accent).frame(width: 3, height: 18).offset(x: -6)
            }
        }
        .help("\(activity.title) — \(activity.summary) (⌘\(activity.shortcutKey))")
        .keyboardShortcut(KeyEquivalent(activity.shortcutKey), modifiers: .command)
        .accessibilityLabel(activity.title)
    }

    private var approvalsButton: some View {
        let pending = app.approvalCenter.pending.count
        return Button {
            workstation.showApprovals = true
        } label: {
            Image(systemName: pending > 0 ? "exclamationmark.shield.fill" : "checkmark.shield")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 34)
                .overlay(alignment: .topTrailing) {
                    if pending > 0 {
                        Text("\(pending)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(SSColor.accent, in: Capsule())
                            .offset(x: -2, y: 2)
                    }
                }
        }
        .buttonStyle(SSIconButtonStyle(selected: pending > 0))
        .help(pending > 0 ? "\(pending) tool call(s) waiting for you" : "Approval queue and standing grants")
    }

    private func utilityButton(symbol: String, help: String, selected: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 40, height: 32)
        }
        .buttonStyle(SSIconButtonStyle(selected: selected))
        .help(help)
    }
}

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
