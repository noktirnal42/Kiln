import SwiftUI

/// Every conversation with what it is doing: running, waiting for your approval, or idle. Open resumes it; Fork branches
/// it from its latest message. Only the open conversation runs; switching away stops a run in progress.
struct SessionsPaneView: View {
    @Bindable var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SessionRow] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Sessions").font(SSTypography.headline()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                .padding(SSSpacing.m)
            Divider()
            List(rows) { row in
                HStack {
                    Circle().fill(color(row.state)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(SSTypography.body()).lineLimit(1)
                        Text("\(row.state.label) · \(row.messageCount) messages · \(row.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(SSTypography.caption()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.isOpen { SSBadge(text: "Open", tint: SSColor.accent) }
                    else { Button("Open") { Task { await session.loadConversation(row.id); dismiss() } }.disabled(session.isStreaming) }
                    Button("Fork") { Task { await session.forkLatest(of: row.id); dismiss() } }.disabled(session.isStreaming || row.messageCount == 0)
                }
            }
        }
        .frame(width: 640, height: 440)
        .task { await reload() }
        .onChange(of: session.sessionStates) { _, _ in Task { await reload() } }
    }

    private func reload() async { rows = await session.sessionRows() }

    private func color(_ state: SessionState) -> Color {
        switch state { case .idle: return .secondary; case .running: return SSColor.success; case .waitingForApproval: return SSColor.warning }
    }
}
