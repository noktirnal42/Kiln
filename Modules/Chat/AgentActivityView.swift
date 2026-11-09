import SwiftUI
import AppKit

/// What the agent is doing, in the style of Claude Code and Codex: while it works, the newest few calls as compact
/// one-line rows; once it is done, one line ("Ran 4 commands · edited 2 files") that expands to the rows.
struct AgentActivityView: View {
    let session: ChatSession
    /// Live rows kept visible while running; older ones fold into the summary line.
    static let liveRowLimit = 5

    var body: some View {
        if session.agentEnabled && !session.agentActivity.isEmpty && showsActivity {
            VStack(alignment: .leading, spacing: 3) {
                if session.isStreaming { live } else { finished }
                if let notice = session.agentNotice {
                    Text(notice).font(SSTypography.caption()).foregroundStyle(SSColor.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let notice = session.agentNotice, session.agentEnabled {
            Text(notice).font(SSTypography.caption()).foregroundStyle(SSColor.warning)
        }
    }

    /// After a run, the reply carries the collapsed line itself; show this view only for a run with no saved reply.
    private var showsActivity: Bool {
        session.isStreaming || (session.messages.last?.toolCalls.isEmpty ?? true)
    }

    private var live: some View {
        let records = session.agentActivity
        let hidden = max(0, records.count - Self.liveRowLimit)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: SSSpacing.xs) {
                ProgressView().controlSize(.mini)
                Text("Working · step \(max(1, session.agentRound))").font(SSTypography.caption()).foregroundStyle(.secondary)
                if hidden > 0 {
                    Text("· " + ToolActivitySummary.line(for: records.map(Self.item)))
                        .font(SSTypography.caption()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            ForEach(records.suffix(Self.liveRowLimit)) { record in
                ToolCallRow(record: record, compact: true)
            }
        }
    }

    private var finished: some View {
        ToolRunSummaryView(
            line: ToolActivitySummary.line(for: session.agentActivity.map(Self.item)),
            records: session.agentActivity
        )
    }

    static func item(_ record: ToolCallRecord) -> ToolActivityItem {
        ToolActivityItem(name: record.toolName, argumentsJSON: record.argumentsJSON, failed: record.status == .failed)
    }
}

/// A finished run folded into one line, expandable to a row per call.
struct ToolRunSummaryView: View {
    let line: String
    let records: [ToolCallRecord]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(line).font(SSTypography.caption())
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line)
            .accessibilityHint(expanded ? "Hide the tool calls" : "Show the tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(records) { ToolCallRow(record: $0, compact: true) }
                }
                .padding(.leading, 14)
            }
        }
    }
}

/// Persisted tool calls (name and arguments only: results are not kept) under a reply, collapsed the same way.
struct StoredToolRunView: View {
    let calls: [ToolCall]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(line).font(SSTypography.caption())
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line)
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        HStack(spacing: SSSpacing.xs) {
                            Text(call.name.isEmpty ? "tool call" : call.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text(ToolCallRow.summary(call.arguments))
                                .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private var line: String {
        ToolActivitySummary.line(for: calls.map { ToolActivityItem(name: $0.name, argumentsJSON: $0.arguments) })
    }
}

struct ToolCallRow: View {
    let record: ToolCallRecord
    var compact = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: SSSpacing.xs) {
                    Image(systemName: symbol).font(.system(size: compact ? 10 : 12)).foregroundStyle(color).frame(width: 14)
                    Text(record.toolName).font(.system(size: compact ? 11 : 12, weight: .medium, design: .monospaced))
                    Text(Self.summary(record.argumentsJSON))
                        .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if !compact || record.status == .awaitingApproval || record.status == .failed || record.status == .denied {
                        Text(label).font(SSTypography.caption()).foregroundStyle(color)
                    }
                }
                .padding(.vertical, record.status == .awaitingApproval ? 3 : 0)
                .padding(.horizontal, record.status == .awaitingApproval ? 6 : 0)
                .background(record.status == .awaitingApproval ? SSColor.warning.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            if expanded {
                let detail = record.errorText ?? record.resultText ?? record.argumentsJSON
                Text(String(detail.prefix(1500)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.leading, 18)
            }
        }
    }

    private var label: String {
        switch record.status {
        case .pending: "queued"
        case .awaitingApproval: "needs approval"
        case .running: "running"
        case .succeeded: "done"
        case .failed: "failed"
        case .denied: "blocked"
        case .cancelled: "cancelled"
        }
    }
    private var symbol: String {
        switch record.status {
        case .pending, .running: "circle.dotted"
        case .awaitingApproval: "hand.raised.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed, .denied: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        }
    }
    private var color: Color {
        switch record.status {
        case .succeeded: SSColor.success
        case .failed, .denied: SSColor.danger
        case .awaitingApproval: SSColor.warning
        default: .secondary
        }
    }

    /// First string argument, which is almost always the path or command: enough to recognise the call.
    static func summary(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["path", "command", "url", "query", "pattern", "message"] {
            if let value = object[key] as? String { return value.replacingOccurrences(of: "\n", with: " ") }
        }
        return ""
    }
}

/// Used of the model's window, as a ring and a percentage, with a button that compacts now.
struct ContextMeterView: View {
    let session: ChatSession

    var body: some View {
        if let usage = session.contextUsage {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.02, usage.fraction))
                        .stroke(tint(usage), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                Text(session.isCompacting ? "Compacting…" : "\(usage.percent)%")
                    .font(SSTypography.caption()).monospacedDigit().foregroundStyle(tint(usage))
                    .lineLimit(1).fixedSize()
                Button { Task { await session.compactNow() } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(session.isStreaming || session.isCompacting || session.messages.isEmpty)
                .help("Compact now: summarise the earlier conversation to free context (same as /compact)")
                .accessibilityLabel("Compact conversation")
            }
            .help(Self.tooltip(usage, summarised: session.hasContextSummary))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context \(usage.percent) percent used")
        }
    }

    private func tint(_ usage: ContextUsage) -> Color {
        usage.fraction >= 0.9 ? SSColor.danger : usage.fraction >= 0.7 ? SSColor.warning : Color.secondary
    }

    static func tooltip(_ usage: ContextUsage, summarised: Bool) -> String {
        var text = "Context: about \(usage.used.formatted()) of \(usage.window.formatted()) tokens (\(usage.percent)%). An estimate: it counts the conversation, the system prompt and the tool list."
        text += "\nAt about 70% Kiln clears old tool output, then summarises the earlier conversation, on its own."
        if summarised { text += "\nEarlier messages are already replaced by a summary." }
        text += "\n/compact does it now."
        return text
    }
}

/// The controls that sit with the message box, as in the apps this is modelled on: which model, plain chat or
/// agent, and which agent. The project is the sidebar's job; this only says when there isn't one.
/// Ask / Auto / Bypass: who answers the agent's approval questions. Bypass is red and asks to be confirmed.
struct PermissionModeMenu: View {
    @ObservedObject var center: ApprovalCenter
    @State private var confirmBypass = false

    private var tint: Color {
        switch center.mode {
        case .ask: return .secondary
        case .auto: return SSColor.accent
        case .bypass: return SSColor.danger
        }
    }

    private var symbol: String {
        switch center.mode {
        case .ask: return "hand.raised"
        case .auto: return "bolt.shield"
        case .bypass: return "exclamationmark.shield.fill"
        }
    }

    var body: some View {
        Menu {
            ForEach(ApprovalMode.allCases) { mode in
                Button {
                    if mode == .bypass { confirmBypass = true } else { center.setMode(mode) }
                } label: {
                    if center.mode == mode { Label("\(mode.displayName): \(mode.summary)", systemImage: "checkmark") }
                    else { Text("\(mode.displayName): \(mode.summary)") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(center.mode.displayName).font(SSTypography.caption())
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permissions: \(center.mode.summary)")
        .accessibilityLabel("Permission mode: \(center.mode.displayName)")
        .accessibilityHint(center.mode.summary)
        .confirmationDialog("Bypass permissions?", isPresented: $confirmBypass, titleVisibility: .visible) {
            Button("Bypass permissions", role: .destructive) { center.setMode(.bypass) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will run commands, change files and use the network without asking, including destructive ones. Hard blocks and behavior-monitor holds still apply. This turns off when Kiln quits.")
        }
    }
}

struct AgentModeBar: View {
    @Bindable var session: ChatSession
    @State private var showModelPicker = false

    var body: some View {
        HStack(spacing: SSSpacing.s) {
            Button { showModelPicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.system(size: 10))
                    Text(modelLabel).lineLimit(1).font(SSTypography.caption())
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(SSColor.surfaceRaised, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(session.selectedModelID.isEmpty ? "Pick a model" : session.selectedModelID)

            Toggle(isOn: $session.agentEnabled) {
                Label("Agent", systemImage: "wand.and.stars")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(session.orchestrator == nil)
            .help("Let the model use tools. Writes and commands ask for your approval.")
            if session.agentEnabled {
                Picker("", selection: $session.agentProfileIndex) {
                    ForEach(Array(session.agentProfiles.enumerated()), id: \.offset) { index, profile in
                        Text(profile.name).tag(index)
                    }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: 150)
                PermissionModeMenu(center: ApprovalCenter.shared)
                if session.workspaceRoot == nil {
                    Label("No project — pick one in the sidebar", systemImage: "folder.badge.questionmark")
                        .font(SSTypography.caption()).foregroundStyle(SSColor.warning)
                        .help("Without a project folder the agent can't read or change files.")
                }
            }
            Spacer()
            ContextMeterView(session: session)
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.top, SSSpacing.xs)
        .sheet(isPresented: $showModelPicker) { ModelPickerView(session: session) }
    }

    private var modelLabel: String {
        let id = session.selectedModelID
        if id.isEmpty { return "Select model" }
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        return bare.count > 26 ? String(bare.prefix(25)) + "…" : bare
    }
}
