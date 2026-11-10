import SwiftUI

/// The memory files in use: which exist, what each costs in tokens, and an editor for each. Missing files can be created.
struct MemoryPaneView: View {
    @Bindable var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?
    @State private var draft = ""
    @State private var message: String?

    private var selected: MemoryFile? { session.memory.files.first { $0.path == selectedPath } ?? session.memory.files.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memory").font(SSTypography.headline())
                SSBadge(text: "\(session.memory.totalTokens.formatted()) tokens in every request", tint: .secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(SSSpacing.m)
            Divider()
            HSplitView {
                List(selection: Binding(get: { selected?.path }, set: { selectedPath = $0; loadDraft() })) {
                    ForEach(MemoryScope.allCases, id: \.self) { scope in
                        let files = session.memory.files.filter { $0.scope == scope }
                        if !files.isEmpty {
                            Section(scope.title) {
                                ForEach(files) { file in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name).font(SSTypography.body())
                                        Text(status(file)).font(SSTypography.caption()).foregroundStyle(.secondary)
                                    }
                                    .tag(file.path)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                editor
            }
        }
        .frame(width: 720, height: 480)
        .onAppear { session.reloadMemory(); loadDraft() }
    }

    private func status(_ file: MemoryFile) -> String {
        if !file.exists { return "Not created" }
        if file.duplicateOf != nil { return "Same text as another file" }
        if !file.isInjected { return "Empty" }
        return "\(file.tokens.formatted()) tokens" + (file.truncated ? " · truncated" : "")
    }

    @ViewBuilder private var editor: some View {
        if let file = selected {
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                Text(file.path).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if file.scope == .project && session.workspaceRoot == nil {
                    Text("Pick a project first.").foregroundStyle(SSColor.warning)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Text("Read at the start of each run and sent with it. Guidance only: it never widens what the agent may do.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    Spacer()
                    if let message { Text(message).font(SSTypography.caption()).foregroundStyle(.secondary) }
                    Button(file.exists ? "Save" : "Create \(file.name)") { save(file) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!file.exists && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(SSSpacing.m)
            .id(file.path)
        }
    }

    private func loadDraft() {
        draft = selected?.content ?? ""
        message = nil
    }

    private func save(_ file: MemoryFile) {
        Task {
            do { try await session.saveMemory(path: file.path, text: draft); message = "Saved" }
            catch { message = String(describing: error) }
        }
    }
}
