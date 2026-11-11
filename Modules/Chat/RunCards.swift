import SwiftUI

/// The agent's task list, above the message box: collapsed to one line ("2 of 5 done · now: …"), expandable.
struct TodoCardView: View {
    let session: ChatSession
    @State private var expanded = true

    var body: some View {
        let items = session.todoItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: SSSpacing.s) {
                        Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(SSColor.accent)
                        Text("Tasks").font(.system(size: 11, weight: .semibold))
                        Text(TodoBoard.summary(items)).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tasks, \(TodoBoard.summary(items))")
                .accessibilityHint(expanded ? "Collapses the list" : "Expands the list")
                if expanded {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: symbol(item.status)).font(.system(size: 10)).foregroundStyle(tint(item.status))
                                Text(item.content).font(.system(size: 12))
                                    .strikethrough(item.status == .completed)
                                    .foregroundStyle(item.status == .completed ? Color.secondary : Color.primary)
                                    .fontWeight(item.status == .in_progress ? .medium : .regular)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(item.content), \(label(item.status))")
                        }
                        if items.allSatisfy({ $0.status == .completed }) {
                            Button("Clear") { session.clearTodos() }.controlSize(.mini).buttonStyle(.borderless).padding(.top, 2)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, SSSpacing.s).padding(.vertical, 6)
            .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, SSSpacing.m).padding(.top, SSSpacing.xs)
        }
    }

    private func symbol(_ status: TodoItem.Status) -> String {
        switch status { case .pending: "circle"; case .in_progress: "circle.dotted.circle"; case .completed: "checkmark.circle.fill" }
    }
    private func tint(_ status: TodoItem.Status) -> Color {
        switch status { case .pending: .secondary; case .in_progress: SSColor.accent; case .completed: SSColor.success }
    }
    private func label(_ status: TodoItem.Status) -> String {
        switch status { case .pending: "to do"; case .in_progress: "in progress"; case .completed: "done" }
    }
}

/// "Changed 3 files +24 −5" under the reply of a run that edited files; each file expands to its diff and can be reverted.
struct RunDiffCardView: View {
    let session: ChatSession
    let messageID: UUID
    @State private var files: [RunFileDiff] = []
    @State private var expanded: Set<String> = []
    @State private var confirming: RunFileDiff?
    @State private var loaded = false

    var body: some View {
        // A VStack, not a Group: a .task on a Group whose only child is absent never runs, so the card would never load.
        VStack(spacing: 0) {
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: SSSpacing.s) {
                        Image(systemName: "plus.forwardslash.minus").font(.system(size: 11)).foregroundStyle(SSColor.accent)
                        Text("Changed \(files.count) \(files.count == 1 ? "file" : "files")").font(.system(size: 12, weight: .semibold))
                        Text("+\(files.reduce(0) { $0 + $1.additions })").font(.system(size: 11, design: .monospaced)).foregroundStyle(SSColor.success)
                        Text("−\(files.reduce(0) { $0 + $1.deletions })").font(.system(size: 11, design: .monospaced)).foregroundStyle(SSColor.danger)
                        Spacer()
                    }
                    .padding(.horizontal, SSSpacing.s).padding(.vertical, 7)
                    ForEach(files) { file in
                        Divider()
                        row(file)
                    }
                }
                .background(SSColor.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SSColor.hairline))
                .confirmationDialog("Revert \(confirming?.path ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { file in
                    Button(file.change == .added ? "Move to Trash" : "Revert File", role: .destructive) {
                        Task { await session.revertFile(file.path, in: messageID) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { file in
                    Text(file.change == .added ? "The file the agent created is moved to the Trash." : "The file goes back to how it was before this run. Later edits by the agent in this run are lost.")
                }
            }
        }
        .task(id: "\(messageID)-\(session.diffRevision)-\(session.isStreaming)") {
            guard !session.isStreaming else { return }
            files = await session.runDiff(for: messageID)
            loaded = true
        }
    }

    private func row(_ file: RunFileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SSSpacing.s) {
                Button {
                    if expanded.contains(file.path) { expanded.remove(file.path) } else { expanded.insert(file.path) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded.contains(file.path) ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 10)
                        Image(systemName: symbol(file.change)).font(.system(size: 10)).foregroundStyle(tint(file.change))
                        Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        if file.summaryOnly { Text("binary or large").font(SSTypography.caption()).foregroundStyle(.tertiary) }
                        Spacer(minLength: 4)
                        Text("+\(file.additions)").font(.system(size: 11, design: .monospaced)).foregroundStyle(SSColor.success)
                        Text("−\(file.deletions)").font(.system(size: 11, design: .monospaced)).foregroundStyle(SSColor.danger)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(file.path), \(file.change.rawValue), \(file.additions) added, \(file.deletions) removed")
                Button("Revert") { confirming = file }
                    .controlSize(.mini).buttonStyle(.bordered)
                    .disabled(!file.canRevert)
                    .help(file.canRevert ? "Put this file back as it was before the run" : "This file changed after the run, so it is left alone")
            }
            .padding(.horizontal, SSSpacing.s).padding(.vertical, 5)
            if expanded.contains(file.path), !file.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in diffLine(line) }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func diffLine(_ line: RunFileDiff.Line) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 30, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 30, alignment: .trailing).foregroundStyle(.tertiary)
            Text(prefix(line.kind) + line.text).foregroundStyle(line.kind == .gap ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, SSSpacing.s)
        .background(background(line.kind))
        .textSelection(.enabled)
    }

    private func prefix(_ kind: RunFileDiff.Line.Kind) -> String {
        switch kind { case .added: "+ "; case .removed: "− "; case .context: "  "; case .gap: "" }
    }
    private func background(_ kind: RunFileDiff.Line.Kind) -> Color {
        switch kind { case .added: SSColor.success.opacity(0.14); case .removed: SSColor.danger.opacity(0.14); default: .clear }
    }
    private func symbol(_ change: RunFileDiff.Change) -> String {
        switch change { case .added: "plus.circle.fill"; case .modified: "pencil.circle.fill"; case .deleted: "minus.circle.fill" }
    }
    private func tint(_ change: RunFileDiff.Change) -> Color {
        switch change { case .added: SSColor.success; case .modified: SSColor.accent; case .deleted: SSColor.danger }
    }
}
