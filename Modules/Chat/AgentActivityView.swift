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
            // A notice with no run behind it is an answer to a command (/model, /plan, /help), not a warning.
            Text(notice).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    /// After a run, the reply carries the collapsed line itself; show this view only for a run with no saved reply.
    private var showsActivity: Bool {
        session.isStreaming || (session.messages.last?.toolCalls.isEmpty ?? true)
    }

    /// Claude Code's way: finished steps fold into one grey sentence ("Ran 2 commands and read 3 files ›"), and a single live line says what is
    /// happening now with the elapsed time. Only an approval that needs you stays in view.
    private var live: some View {
        let records = session.agentActivity
        let done = records.filter { $0.status.isTerminal }
        let waiting = records.filter { $0.status == .awaitingApproval }
        return VStack(alignment: .leading, spacing: 4) {
            if !done.isEmpty {
                ToolRunSummaryView(line: ToolActivitySummary.line(for: done.map(Self.item)), records: done)
            }
            ForEach(waiting) { ToolCallRow(record: $0, compact: true) }
            LiveStatusLine(status: liveStatus(records), since: session.runStartedAt)
        }
    }

    private func liveStatus(_ records: [ToolCallRecord]) -> String {
        if let waiting = records.last(where: { $0.status == .awaitingApproval }) {
            return ToolPhrase.liveStatus(name: waiting.toolName, argumentsJSON: waiting.argumentsJSON, awaitingApproval: true)
        }
        if let running = records.last(where: { !$0.status.isTerminal }) {
            return ToolPhrase.liveStatus(name: running.toolName, argumentsJSON: running.argumentsJSON)
        }
        return session.streamingReasoning.isEmpty ? (session.streamingText.isEmpty ? "Working" : "Writing") : "Thinking"
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
    /// How long the run took, when it is known (the gap between the question and the saved reply).
    var seconds: TimeInterval?
    @AppStorage(ToolSummaryStyle.defaultsKey) private var styleRaw = ToolSummaryStyle.sentence.rawValue
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
                        let title = ToolPhrase.title(name: call.name, argumentsJSON: call.arguments)
                        HStack(spacing: SSSpacing.xs) {
                            Text(title.verb).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(title.object).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private var line: String {
        (ToolSummaryStyle(rawValue: styleRaw) ?? .sentence)
            .line(for: calls.map { ToolActivityItem(name: $0.name, argumentsJSON: $0.arguments) }, seconds: seconds)
    }
}

struct ToolCallRow: View {
    let record: ToolCallRecord
    var compact = false
    @State private var expanded = false

    var body: some View {
        let title = ToolPhrase.title(name: record.toolName, argumentsJSON: record.argumentsJSON)
        VStack(alignment: .leading, spacing: 2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: SSSpacing.xs) {
                    // Success is the normal case and says nothing; only waiting, failed and blocked steps carry an icon and a word.
                    if record.status != .succeeded { Image(systemName: symbol).font(.system(size: compact ? 10 : 12)).foregroundStyle(color).frame(width: 14) }
                    Text(title.verb).font(.system(size: compact ? 12 : 13)).foregroundStyle(.secondary)
                    Text(title.object).font(.system(size: compact ? 11.5 : 12.5, design: .monospaced)).foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if record.status == .awaitingApproval || record.status == .failed || record.status == .denied || (!compact && record.status != .succeeded) {
                        Text(label).font(SSTypography.caption()).foregroundStyle(color)
                    }
                }
                .padding(.vertical, record.status == .awaitingApproval ? 3 : 0)
                .padding(.horizontal, record.status == .awaitingApproval ? 6 : 0)
                .background(record.status == .awaitingApproval ? SSColor.warning.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title.verb) \(title.object), \(label)")
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
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
            .help(Self.tooltip(usage, summarised: session.hasContextSummary, memoryTokens: session.memory.totalTokens))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context \(usage.percent) percent used")
        }
    }

    private func tint(_ usage: ContextUsage) -> Color {
        usage.fraction >= 0.9 ? SSColor.danger : usage.fraction >= 0.7 ? SSColor.warning : Color.secondary
    }

    static func tooltip(_ usage: ContextUsage, summarised: Bool, memoryTokens: Int = 0) -> String {
        var text = "Context: about \(usage.used.formatted()) of \(usage.window.formatted()) tokens (\(usage.percent)%). An estimate: it counts the conversation, the system prompt and the tool list."
        text += "\nAt about 70% Kiln clears old tool output, then summarises the earlier conversation, on its own."
        if memoryTokens > 0 { text += "\nMemory files (KILN.md, AGENTS.md, CLAUDE.md): \(memoryTokens.formatted()) tokens of that." }
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
    @State private var showMemory = false
    @State private var showCommands = false
    @State private var showHooks = false
    @State private var showSessions = false
    @State private var showUsage = false
    @State private var showSchedules = false

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
                Toggle(isOn: $session.planMode) { Label("Plan", systemImage: "list.bullet.clipboard") }
                    .toggleStyle(.button).controlSize(.small)
                    .help("Plan mode: the agent explores read-only, then proposes a plan you approve before anything changes (/plan)")
                Picker("", selection: $session.agentProfileIndex) {
                    ForEach(Array(session.agentProfiles.enumerated()), id: \.offset) { index, profile in
                        Text(profile.name).tag(index)
                    }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: 150)
                if let profile = session.agentProfile {
                    Menu {
                        ForEach(AgentRoundLimits.presets, id: \.self) { limit in
                            Button {
                                session.setRoundLimit(limit, for: profile)
                            } label: {
                                if session.roundLimit(for: profile) == limit { Label("\(limit) steps", systemImage: "checkmark") }
                                else { Text("\(limit) steps") }
                            }
                        }
                    } label: {
                        Text("\(session.roundLimit(for: profile)) steps").font(SSTypography.caption())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Maximum model rounds for \(profile.name); changes apply to the next run")
                    .accessibilityLabel("Step limit: \(session.roundLimit(for: profile))")
                }
                PermissionModeMenu(center: ApprovalCenter.shared)
                if session.workspaceRoot == nil {
                    Label("No project", systemImage: "folder.badge.questionmark")
                        .font(SSTypography.caption()).foregroundStyle(SSColor.warning)
                        .lineLimit(1).fixedSize()
                        .help("Without a project folder the agent can't read or change files.")
                }
            }
            Spacer()
            ReasoningMenu(session: session)
            ContextMeterView(session: session)
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.top, SSSpacing.xs)
        .sheet(isPresented: $showModelPicker) { ModelPickerView(session: session) }
        .sheet(isPresented: $showMemory) { MemoryPaneView(session: session) }
        .sheet(isPresented: $showCommands) { CommandsPaneView(session: session) }
        .sheet(isPresented: $showHooks) { HooksPaneView(session: session) }
        .sheet(isPresented: $showSessions) { SessionsPaneView(session: session) }
        .sheet(isPresented: $showUsage) { UsagePaneView(session: session) }
        .sheet(isPresented: $showSchedules) { SchedulesPaneView(session: session) }
        .onChange(of: session.requestedPane, initial: true) { _, pane in
            switch pane { case .memory: showMemory = true; case .commands: showCommands = true; case .hooks: showHooks = true; case .sessions: showSessions = true; case .usage: showUsage = true; case .schedules: showSchedules = true; case nil: break }
            session.requestedPane = nil
        }
    }

    private var modelLabel: String {
        let id = session.selectedModelID
        if id.isEmpty { return "Select model" }
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        return bare.count > 26 ? String(bare.prefix(25)) + "…" : bare
    }
}


/// The agent's proposed plan, with Approve (runs it), Edit and Reject. Nothing has been changed when this shows.
struct PlanCardView: View {
    let session: ChatSession
    let plan: PlanProposal
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Label("Plan — nothing has been changed yet", systemImage: "list.bullet.clipboard").font(SSTypography.headline())
            if editing {
                TextEditor(text: $draft).font(.system(size: 12)).frame(minHeight: 160, maxHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
            } else if session.messages.last?.content != plan.text {
                // The plan is normally the reply right above this card; it is repeated only when it is not.
                MarkdownBlockView(text: plan.text)
            } else {
                Text("The plan is the reply above. Approve it to let the agent make the changes, edit it first, or reject it.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Approve and run") { Task { await session.approvePlan(editedText: editing ? draft : nil) } }
                    .buttonStyle(.borderedProminent).disabled(session.isStreaming)
                Button(editing ? "Discard edits" : "Edit") { draft = plan.text; editing.toggle() }
                Button("Reject", role: .destructive) { Task { await session.rejectPlan() } }
                Spacer()
            }
        }
        .padding(SSSpacing.m)
        .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "Running swift test  1m 26s": what is happening now and for how long. One line, replacing a stack of progress rows.
struct LiveStatusLine: View {
    let status: String
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: SSSpacing.xs) {
                ProgressView().controlSize(.mini)
                Text(status).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let since { Text(Self.elapsed(context.date.timeIntervalSince(since))).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Working: \(status)")
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        ToolSummaryStyle.duration(seconds)
    }
}

/// The brain button: the reasoning levels the selected model actually offers. A model that offers none shows it greyed out, with the reason.
struct ReasoningMenu: View {
    let session: ChatSession

    private func title(_ selection: ReasoningSelection?, _ control: ReasoningControl) -> String? {
        switch (control, selection) {
        case (.toggle, .some(.off)): "Off"
        case (.toggle, _): "On"
        case (.levels(let levels), .some(.level(let id))): levels.first { $0.id == id }?.title
        default: nil
        }
    }

    var body: some View {
        let control = session.reasoningControl
        let selection = session.reasoningSelection
        Menu {
            switch control {
            case .unavailable(let why):
                Text(why)
            case .toggle:
                choice("Thinking on", selected: selection == .on) { session.setReasoning(.on) }
                choice("Thinking off", selected: selection == .off) { session.setReasoning(.off) }
            case .levels(let levels):
                ForEach(levels) { level in
                    choice(level.title, selected: selection == .level(level.id)) { session.setReasoning(.level(level.id)) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain").font(.system(size: 10))
                if let text = title(selection, control) { Text(text).font(SSTypography.caption()) }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(!control.isAvailable)
        .help(control.isAvailable ? "Reasoning: \(control.explanation)" : "Reasoning: \(control.explanation)")
        .accessibilityLabel("Reasoning")
        .accessibilityValue(title(selection, control) ?? "Not available for this model")
    }

    @ViewBuilder
    private func choice(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { if selected { Label(text, systemImage: "checkmark") } else { Text(text) } }
    }
}
