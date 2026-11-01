import SwiftUI
import AppKit

/// Live record of what the agent is doing: one row per tool call, newest last.
struct AgentActivityView: View {
    let session: ChatSession

    var body: some View {
        if session.agentEnabled && (!session.agentActivity.isEmpty || session.isStreaming) {
            VStack(alignment: .leading, spacing: SSSpacing.xs) {
                HStack(spacing: SSSpacing.xs) {
                    SSSectionLabel(session.isStreaming ? "Agent working · round \(max(1, session.agentRound))" : "Last agent run")
                    Spacer()
                }
                ForEach(session.agentActivity) { record in
                    ToolCallRow(record: record)
                }
                if let notice = session.agentNotice {
                    Text(notice).font(SSTypography.caption()).foregroundStyle(SSColor.warning)
                }
            }
            .padding(SSSpacing.s)
            .ssPanel()
        }
    }
}

private struct ToolCallRow: View {
    let record: ToolCallRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: SSSpacing.xs) {
                    Image(systemName: symbol).foregroundStyle(color).frame(width: 14)
                    Text(record.toolName).font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(Self.summary(record.argumentsJSON))
                        .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(label).font(SSTypography.caption()).foregroundStyle(color)
                }
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

/// Switch between plain chat and agent mode, pick the agent, and scope it to a folder.
struct AgentModeBar: View {
    @Bindable var session: ChatSession

    var body: some View {
        HStack(spacing: SSSpacing.s) {
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
                Button {
                    chooseFolder()
                } label: {
                    Label(folderName, systemImage: "folder")
                }
                .controlSize(.small)
                .help(session.workspaceRoot ?? "Choose the folder the agent may work in")
            }
            Spacer()
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.top, SSSpacing.xs)
    }

    private var folderName: String {
        session.workspaceRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose folder"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { session.workspaceRoot = url.path }
    }
}
