import AppKit
import SwiftUI

/// Develop → Editor: a file navigator, tabs, and a native code editor over the open project, with build output and
/// clickable problems. It is a text editor with a build button, not Xcode: there is no language server, debugger or
/// previews yet (see docs/KNOWN-ISSUES.md).
struct EditorView: View {
    @Environment(AppModel.self) private var app
    @State private var caret = (line: 1, column: 1)
    @State private var showProblems = true
    @State private var showQuickOpen = false
    @State private var showGoToLine = false
    @State private var goToLineText = ""
    @State private var closing: EditorDocument?
    @State private var treeVersion = 0
    @State private var navigatorMode = NavigatorMode.files
    @State private var searchQuery = ""
    @State private var searchHits: [ProjectHit] = []
    @State private var searching = false
    @State private var fileAction: FileAction?
    @State private var fileActionName = ""
    @State private var fileError: String?

    enum NavigatorMode: String, CaseIterable { case files = "Files", search = "Find" }

    /// A pending create/rename/delete the user has to confirm with a name or a click.
    struct FileAction: Identifiable {
        enum Kind { case newFile, newFolder, rename, trash }
        var kind: Kind
        var url: URL
        var id: String { "\(kind)-\(url.path)" }
    }

    private var editor: EditorWorkspace { app.editor }
    private var builder: BuildRunner { app.builder }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                navigator
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 380)
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    banners
                    editorArea
                    Divider()
                    statusBar
                    if showProblems { problemsPanel }
                }
                .frame(minWidth: 320)
            }
        }
        .background(shortcuts)
        .sheet(isPresented: $showQuickOpen) { QuickOpenView(editor: editor, isPresented: $showQuickOpen) }
        .alert(fileActionTitle, isPresented: Binding(get: { fileAction != nil }, set: { if !$0 { fileAction = nil } })) {
            if fileAction?.kind != .trash { TextField("Name", text: $fileActionName) }
            Button(fileAction?.kind == .trash ? "Move to Trash" : "OK", role: fileAction?.kind == .trash ? .destructive : nil) { performFileAction() }
            Button("Cancel", role: .cancel) { fileAction = nil }
        } message: { Text(fileAction?.kind == .trash ? "You can restore it from the Trash." : "") }
        .alert("Couldn't do that", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK") { fileError = nil }
        } message: { Text(fileError ?? "") }
        .confirmationDialog("Save changes to \(closing?.name ?? "this file")?", isPresented: Binding(
            get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Save") { if let doc = closing { editor.save(doc); if !doc.isDirty { editor.close(doc) } }; closing = nil }
            Button("Don't Save", role: .destructive) { if let doc = closing { editor.close(doc) }; closing = nil }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: { Text("Your changes will be lost if you don't save them.") }
        .onAppear {
            editor.setRoot(app.chatSession?.workspaceRoot)
            editor.startWatching()
        }
        .onChange(of: app.chatSession?.workspaceRoot) { _, root in editor.setRoot(root) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in editor.writeRecovery() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in editor.tick() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: SSSpacing.s) {
            Button { showQuickOpen = true } label: { Label("Open Quickly", systemImage: "magnifyingglass") }
                .disabled(editor.root == nil)
            Button { editor.active.map { editor.save($0) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(!(editor.active?.isDirty ?? false))
            Button { editor.saveAll() } label: { Label("Save All", systemImage: "square.and.arrow.down.on.square") }
                .disabled(!editor.hasUnsavedChanges)
            Divider().frame(height: 16)
            Button { runBuild() } label: {
                Label(builder.isRunning ? "Building…" : buildTitle, systemImage: "hammer")
            }
            .disabled(builder.isRunning || editor.root == nil || buildCommand == nil)
            if builder.isRunning {
                Button { builder.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            TextField("Custom command (optional)", text: Bindable(builder).customCommand)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220).font(SSTypography.caption())
                .help("Runs instead of the detected build command, from the project folder, through a login shell")
            Spacer()
            if builder.isRunning {
                ProgressView().controlSize(.small)
            } else if let status = builder.lastExitStatus {
                Label(status == 0 ? "Build succeeded" : "Build failed",
                      systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status == 0 ? SSColor.success : SSColor.danger)
                    .font(SSTypography.caption())
            }
            Toggle("Hidden files", isOn: Binding(get: { editor.showHidden }, set: { editor.showHidden = $0; treeVersion += 1 }))
                .toggleStyle(.checkbox).font(SSTypography.caption())
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.xs)
    }

    private var buildCommand: String? {
        if !builder.customCommand.trimmingCharacters(in: .whitespaces).isEmpty { return builder.customCommand }
        return editor.root.flatMap { BuildRunner.detectPlan(in: $0)?.command }
    }

    private var buildTitle: String {
        if !builder.customCommand.trimmingCharacters(in: .whitespaces).isEmpty { return "Run" }
        return editor.root.flatMap { BuildRunner.detectPlan(in: $0)?.title }.map { "Build (\($0))" } ?? "Build"
    }

    private func runBuild() {
        guard let root = editor.root, let command = buildCommand else { return }
        editor.saveAll()
        builder.run(command: command, in: root)
        showProblems = true
    }

    /// Invisible buttons that carry the keyboard shortcuts while the editor is on screen.
    private var shortcuts: some View {
        HStack {
            Button("") { editor.active.map { editor.save($0) } }.keyboardShortcut("s", modifiers: .command)
            Button("") { editor.saveAll() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { showQuickOpen = true }.keyboardShortcut("p", modifiers: .command)
            Button("") { runBuild() }.keyboardShortcut("b", modifiers: .command)
            Button("") { requestClose(editor.active) }.keyboardShortcut("w", modifiers: .command)
            Button("") { showGoToLine = true }.keyboardShortcut("l", modifiers: .command)
        }
        .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        .popover(isPresented: $showGoToLine) { goToLine }
    }

    private var goToLine: some View {
        HStack {
            TextField("Line number", text: $goToLineText)
                .frame(width: 120)
                .onSubmit {
                    if let doc = editor.active, let line = Int(goToLineText.trimmingCharacters(in: .whitespaces)) {
                        editor.pendingLine = (doc.id, line, 1)
                    }
                    showGoToLine = false
                    goToLineText = ""
                }
            Text("⏎ to go").font(SSTypography.caption()).foregroundStyle(.secondary)
        }
        .padding(SSSpacing.m)
    }

    private func requestFileAction(_ kind: FileAction.Kind, _ url: URL) {
        fileActionName = kind == .rename ? url.lastPathComponent : ""
        fileAction = FileAction(kind: kind, url: url)
    }

    private var projectSearch: some View {
        VStack(spacing: 0) {
            TextField("Find in project", text: $searchQuery)
                .textFieldStyle(.roundedBorder).padding(.horizontal, SSSpacing.xs)
                .onSubmit { runProjectSearch() }
            if searching { ProgressView().controlSize(.small).padding(SSSpacing.xs) }
            List(searchHits) { hit in
                Button { editor.open(URL(fileURLWithPath: hit.path), line: hit.line, column: hit.column) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.text).font(SSTypography.mono(10)).lineLimit(1)
                        Text("\(editor.displayPath(URL(fileURLWithPath: hit.path))):\(hit.line)")
                            .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .buttonStyle(.plain)
            }
            if !searching && searchHits.isEmpty && !searchQuery.isEmpty {
                Text("No matches. Press ⏎ to search.").font(SSTypography.caption()).foregroundStyle(.secondary).padding(SSSpacing.s)
            }
        }
    }

    private func requestClose(_ document: EditorDocument?) {
        guard let document else { return }
        if document.isDirty { closing = document } else { editor.close(document) }
    }

    // MARK: Navigator

    private var fileActionTitle: String {
        switch fileAction?.kind {
        case .newFile: "New File"
        case .newFolder: "New Folder"
        case .rename: "Rename"
        case .trash: "Move \(fileAction?.url.lastPathComponent ?? "item") to the Trash?"
        case nil: ""
        }
    }

    private func performFileAction() {
        guard let action = fileAction else { return }
        defer { fileAction = nil }
        do {
            switch action.kind {
            case .newFile: try editor.createFile(named: fileActionName, in: action.url)
            case .newFolder: try editor.createFolder(named: fileActionName, in: action.url)
            case .rename: try editor.rename(action.url, to: fileActionName)
            case .trash: try editor.trash(action.url)
            }
            treeVersion += 1
        } catch {
            fileError = error.localizedDescription
        }
    }

    private func runProjectSearch() {
        guard let root = editor.root, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { searchHits = []; return }
        let query = searchQuery
        let hidden = editor.showHidden
        searching = true
        Task {
            let hits = await Task.detached(priority: .userInitiated) {
                ProjectSearch.search(root: root, query: query, showHidden: hidden)
            }.value
            searchHits = hits
            searching = false
        }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            Picker("", selection: $navigatorMode) {
                ForEach(NavigatorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(SSSpacing.xs)
            if navigatorMode == .search {
                projectSearch
            } else if let root = editor.root {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(root.lastPathComponent).font(SSTypography.headline()).lineLimit(1)
                    Spacer()
                    Button { fileActionName = ""; fileAction = FileAction(kind: .newFile, url: root) } label: { Image(systemName: "doc.badge.plus") }
                        .buttonStyle(.borderless).help("New file in the project root")
                    Button { fileActionName = ""; fileAction = FileAction(kind: .newFolder, url: root) } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless).help("New folder in the project root")
                    Button { treeVersion += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh the file list")
                }
                .padding(SSSpacing.s)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(editor.children(of: root)) { node in
                            FileTreeRow(editor: editor, node: node, depth: 0, onAction: requestFileAction)
                        }
                    }
                    .padding(.vertical, 4)
                    .id(treeVersion)
                }
            } else {
                SSEmptyState(symbol: "folder.badge.questionmark", title: "No project folder",
                             message: "Choose a project from the sidebar to browse and edit its files.")
            }
        }
        .background(SSColor.surface)
    }

    // MARK: Tabs, banners, editor

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(editor.documents) { document in
                    HStack(spacing: 4) {
                        Image(systemName: document.isDirty ? "circle.fill" : "doc.text")
                            .font(.system(size: document.isDirty ? 7 : 11))
                            .foregroundStyle(document.isDirty ? SSColor.accent : .secondary)
                        Text(document.name).font(SSTypography.caption()).lineLimit(1)
                        Button { requestClose(document) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (⌘W)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(document.id == editor.activeID ? Color.primary.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { editor.activeID = document.id }
                    .help(editor.displayPath(document.url))
                }
            }
            .padding(.horizontal, SSSpacing.s).padding(.vertical, 3)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var banners: some View {
        if let message = editor.message {
            Banner(text: message, tint: SSColor.danger) {
                Button("Dismiss") { editor.message = nil }
            }
        }
        if let document = editor.active {
            if document.conflict {
                Banner(text: "\(document.name) changed on disk while you have unsaved edits.", tint: SSColor.warning) {
                    Button("Reload from disk") { document.reload() }
                    Button("Keep mine") { document.keepMineAfterConflict() }
                    Button("Overwrite disk") { editor.save(document, overwrite: true) }
                }
            } else if document.deletedOnDisk {
                Banner(text: "\(document.name) was deleted on disk.", tint: SSColor.warning) {
                    Button("Save to restore") { editor.save(document, overwrite: true) }
                    Button("Close") { editor.close(document) }
                }
            } else if document.restoredFromRecovery {
                Banner(text: "Restored unsaved changes from your last session.", tint: SSColor.accent) {
                    Button("Discard them") { document.reload(); document.restoredFromRecovery = false }
                    Button("OK") { document.restoredFromRecovery = false }
                }
            }
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if let document = editor.active {
            switch document.status {
            case .editable:
                CodeTextView(
                    document: document,
                    language: SyntaxHighlighter.language(for: document.url),
                    jump: editor.pendingLine.flatMap { $0.id == document.id ? ($0.line, $0.column) : nil },
                    onJumpDone: { editor.pendingLine = nil },
                    onCaretMove: { caret = ($0, $1) }
                )
                .id(document.id)
            case .binary:
                unavailable(document, "Binary file", "This file is not text, so it cannot be edited here.")
            case .tooLarge(let bytes):
                unavailable(document, "File is too large",
                            "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) is over the \(ByteCountFormatter.string(fromByteCount: Int64(EditorDocument.maxBytes), countStyle: .file)) editor limit.")
            case .unreadable(let reason):
                unavailable(document, "Cannot open this file", reason)
            }
        } else {
            SSEmptyState(symbol: "doc.text", title: "No file open",
                         message: "Pick a file in the navigator, or press ⌘P to open one by name.")
        }
    }

    private func unavailable(_ document: EditorDocument, _ title: String, _ message: String) -> some View {
        VStack(spacing: SSSpacing.m) {
            SSEmptyState(symbol: "doc.badge.ellipsis", title: title, message: message)
            HStack {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                Button("Open with Default App") { NSWorkspace.shared.open(document.url) }
                Button("Try Again") { document.reload() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: SSSpacing.m) {
            if let document = editor.active {
                Text(editor.displayPath(document.url)).lineLimit(1).truncationMode(.head)
                Spacer()
                if document.isEditable {
                    Text("Ln \(caret.line), Col \(caret.column)")
                    Text(SyntaxHighlighter.language(for: document.url).rawValue.capitalized)
                    Text(document.isDirty ? "Edited" : "Saved").foregroundStyle(document.isDirty ? SSColor.accent : .secondary)
                }
            } else {
                Spacer()
            }
            Button { showProblems.toggle() } label: {
                Label("\(builder.errorCount) errors, \(builder.warningCount) warnings", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.plain)
        }
        .font(SSTypography.caption())
        .foregroundStyle(.secondary)
        .padding(.horizontal, SSSpacing.m).padding(.vertical, 3)
    }

    private var problemsPanel: some View {
        VStack(spacing: 0) {
            Divider()
            if builder.diagnostics.isEmpty && builder.output.isEmpty {
                Text(editor.root == nil ? "" : "Build output and problems appear here. ⌘B builds the project.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary).padding(SSSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                    if builder.errorCount > 0 {
                        Button { askAgentToFix() } label: { Label("Ask the agent to fix the errors", systemImage: "sparkles") }
                            .buttonStyle(.borderless).font(SSTypography.caption()).padding(SSSpacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    List(builder.diagnostics) { diagnostic in
                        Button { open(diagnostic) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(diagnostic.severity == .error ? SSColor.danger : SSColor.warning)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(diagnostic.message).font(SSTypography.caption()).lineLimit(2)
                                    Text("\(editor.displayPath(URL(fileURLWithPath: diagnostic.path))):\(diagnostic.line)")
                                        .font(SSTypography.mono(10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    }
                    .frame(minWidth: 200)
                    ScrollView {
                        Text(builder.output).font(SSTypography.mono(10)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(SSSpacing.xs)
                    }
                    .frame(minWidth: 200)
                }
            }
        }
        .frame(height: 170)
        .clipped()
    }

    /// Puts the build errors in the agent's message box; the user reads and sends it.
    private func askAgentToFix() {
        let errors = builder.diagnostics.filter { $0.severity == .error }.prefix(15)
            .map { "\(editor.displayPath(URL(fileURLWithPath: $0.path))):\($0.line): \($0.message)" }
            .joined(separator: "\n")
        app.chatSession?.draft = "The build failed. Fix these errors in \(editor.root?.path ?? "the project"), then rebuild to confirm:\n\n\(errors)"
    }

    private func open(_ diagnostic: Diagnostic) {
        editor.open(URL(fileURLWithPath: diagnostic.path), line: diagnostic.line, column: diagnostic.column)
    }
}

// MARK: - Pieces

private struct Banner<Actions: View>: View {
    let text: String
    let tint: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(tint)
            Text(text).font(SSTypography.caption())
            Spacer()
            actions.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, SSSpacing.m).padding(.vertical, 5)
        .background(tint.opacity(0.12))
    }
}

private struct FileTreeRow: View {
    let editor: EditorWorkspace
    let node: FileNode
    let depth: Int
    let onAction: (EditorView.FileAction.Kind, URL) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: node.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "doc")
                    .font(.system(size: 9)).frame(width: 10)
                    .foregroundStyle(.secondary)
                Text(node.name).font(SSTypography.caption()).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12 + 8).padding(.vertical, 3).padding(.trailing, 6)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isDirectory { expanded.toggle() } else { editor.open(node.url) }
            }
            .contextMenu {
                if node.isDirectory {
                    Button("New File…") { onAction(.newFile, node.url) }
                    Button("New Folder…") { onAction(.newFolder, node.url) }
                    Divider()
                }
                Button("Rename…") { onAction(.rename, node.url) }
                Button("Move to Trash…") { onAction(.trash, node.url) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
                }
            }
            if node.isDirectory && expanded {
                ForEach(editor.children(of: node.url)) { child in
                    FileTreeRow(editor: editor, node: child, depth: depth + 1, onAction: onAction)
                }
            }
        }
    }

    private var isActive: Bool { editor.active?.url == node.url }
}

private struct QuickOpenView: View {
    let editor: EditorWorkspace
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var files: [URL] = []
    @State private var selection = 0

    private var matches: [URL] { QuickOpenMatcher.rank(files, query: query, root: editor.root).prefix(40).map { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open file by name…", text: $query)
                .textFieldStyle(.roundedBorder).padding(SSSpacing.m)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, matches.count - 1)); return .handled }
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onKeyPress(.escape) { isPresented = false; return .handled }
            Divider()
            List(Array(matches.enumerated()), id: \.offset) { index, url in
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                    Text(editor.displayPath(url.deletingLastPathComponent())).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .font(SSTypography.caption())
                .padding(.vertical, 2)
                .background(index == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { editor.open(url); isPresented = false }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { files = editor.allFiles() }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func openSelected() {
        guard matches.indices.contains(selection) else { return }
        editor.open(matches[selection])
        isPresented = false
    }
}

/// Fuzzy file-name ranking for Open Quickly: exact name, prefix, substring, then in-order characters.
enum QuickOpenMatcher {
    static func rank(_ files: [URL], query: String, root: URL?) -> [URL] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return files.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        var scored: [(URL, Int)] = []
        for url in files {
            let name = url.lastPathComponent.lowercased()
            let path = url.path.lowercased()
            var score = 0
            if name == q { score = 1000 }
            else if name.hasPrefix(q) { score = 800 - name.count }
            else if name.contains(q) { score = 600 - name.count }
            else if path.contains(q) { score = 300 - path.count / 4 }
            else if isSubsequence(q, of: name) { score = 100 - name.count }
            if score > 0 { scored.append((url, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }.map(\.0)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        for character in haystack where index < needle.endIndex && character == needle[index] { index = needle.index(after: index) }
        return index == needle.endIndex
    }
}
