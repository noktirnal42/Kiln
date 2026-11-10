import SwiftUI

/// Custom slash commands: list, edit and create. Built-ins are listed read-only.
struct CommandsPaneView: View {
    @Bindable var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [SlashCommand] = []
    @State private var selectedID: String?
    @State private var draft = ""
    @State private var newName = ""
    @State private var newScopeUser = false
    @State private var message: String?

    private var selected: SlashCommand? { commands.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Commands").font(SSTypography.headline())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(SSSpacing.m)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: Binding(get: { selectedID }, set: { selectedID = $0; draft = selected?.body ?? ""; message = nil })) {
                        ForEach(commands) { command in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("/\(command.name)").font(SSTypography.body())
                                Text("\(command.source == .builtIn ? "Built in" : command.source == .project ? "Project" : "User") · \(command.summary)")
                                    .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                            }.tag(command.id)
                        }
                    }
                    Divider()
                    HStack {
                        TextField("new-command", text: $newName).textFieldStyle(.roundedBorder)
                        Toggle("User", isOn: $newScopeUser).toggleStyle(.checkbox).help("Off: this project (.kiln/commands). On: all projects (~/.kiln/commands).")
                        Button("Add") { create() }.disabled(newName.isEmpty)
                    }.padding(SSSpacing.s)
                }
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
                editor
            }
        }
        .frame(width: 760, height: 480)
        .onAppear { reload() }
    }

    @ViewBuilder private var editor: some View {
        if let command = selected {
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                Text(command.path ?? "Built-in: \(command.summary)").font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if command.source == .builtIn {
                    Text("Built-in commands act on Kiln and can't be edited.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    TextEditor(text: $draft).font(.system(size: 12, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
                    HStack {
                        Text("$ARGUMENTS is what is typed after the command. Commands never widen permissions.").font(SSTypography.caption()).foregroundStyle(.secondary)
                        Spacer()
                        if let message { Text(message).font(SSTypography.caption()).foregroundStyle(.secondary) }
                        Button("Save") { save(command.path, command.name, draft) }.keyboardShortcut("s", modifiers: .command)
                    }
                }
            }.padding(SSSpacing.m).id(command.id)
        } else {
            Text("Select a command, or add one.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() { commands = session.availableCommands() }

    private func create() {
        let root = session.workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let url = SlashCommands.fileURL(name: newName, scope: newScopeUser ? .user : .project, workspaceRoot: root, home: session.memoryHome) else {
            message = "Invalid or built-in name, or no project open."; return
        }
        if !FileManager.default.fileExists(atPath: url.path) { save(url.path, newName, SlashCommands.template(description: "Describe \(newName)")) }
        newName = ""
        reload()
        selectedID = commands.first { $0.path == url.path }?.id
        draft = selected?.body ?? ""
    }

    private func save(_ path: String?, _ name: String, _ text: String) {
        guard let path else { return }
        Task {
            do { try await session.saveCommandFile(path: path, name: name, text: text); message = "Saved"; reload() }
            catch { message = String(describing: error) }
        }
    }
}

/// Matching commands above the message box while a `/name` is being typed. Tab (or a click) completes.
struct CommandCompletionList: View {
    let matches: [SlashCommand]
    let onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { command in
                Button { onPick(command) } label: {
                    HStack {
                        Text("/\(command.name)").font(.system(size: 12, weight: .medium, design: .monospaced))
                        if let hint = command.argumentHint { Text(hint).font(SSTypography.caption()).foregroundStyle(.tertiary) }
                        Text(command.summary).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, SSSpacing.s).padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, SSSpacing.m)
    }
}
