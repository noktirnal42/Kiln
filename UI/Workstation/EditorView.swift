import AppKit
import SwiftUI

/// Develop → Editor: a file navigator, tabs, and a native code editor over the open project, with build output and
/// clickable problems, SourceKit language services and an LLDB debugger. See docs/KNOWN-ISSUES.md for limits.
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
    @State private var showSettings = false
    @State private var showBuildOptions = false
    @State private var debugPane = DebugPane.variables
    enum DebugPane: String, CaseIterable { case stack = "Stack", variables = "Variables", console = "Console" }
    @State private var preparingDebugger = false
    @State private var bottomMode = BottomMode.problems
    enum BottomMode: String, CaseIterable { case problems = "Problems", debug = "Debug" }
    private var debug: DebugSession { editor.debug }
    private var settings: EditorSettings { EditorSettings.shared }

    enum NavigatorMode: String, CaseIterable { case files = "Files", search = "Find", changes = "Changes" }
    @State private var changed: [GitFileStatus] = []
    @State private var discarding: GitFileStatus?

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
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
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
            editor.refreshRecoverable()
            if let root = editor.root { Task { await builder.loadProject(at: root) } }
        }
        .onChange(of: app.chatSession?.workspaceRoot) { _, root in
            editor.setRoot(root)
            if let url = editor.root { Task { await builder.loadProject(at: url) } }
        }
        .onChange(of: debug.isPaused) { _, paused in
            if paused { bottomMode = .debug; showProblems = true }
        }
        .onChange(of: debug.currentLocation.map { "\($0.path):\($0.line)" }) { _, _ in
            if debug.isPaused, let location = debug.currentLocation {
                editor.open(URL(fileURLWithPath: location.path), line: location.line)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in editor.writeRecovery() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in editor.tick() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: SSSpacing.s) {
            Button { showQuickOpen = true } label: { Label("Open Quickly", systemImage: "magnifyingglass") }
                .disabled(editor.root == nil)
                .help("Open Quickly (⌘P)")
            Button { editor.active.map { editor.save($0) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(!(editor.active?.isDirty ?? false))
                .help("Save (⌘S)")
            Button { editor.saveAll() } label: { Label("Save All", systemImage: "square.and.arrow.down.on.square") }
                .disabled(!editor.hasUnsavedChanges)
                .help("Save all open files (⇧⌘S)")
            Divider().frame(height: 16)
            Button { runBuild() } label: {
                Label(builder.isRunning ? "Building…" : buildTitle, systemImage: "hammer")
            }
            .disabled(builder.isRunning || debug.isActive || preparingDebugger || editor.root == nil || buildCommand == nil)
            .help("Build the current project (⌘B)")
            targetPickers
            Button { runTests() } label: { Label("Test", systemImage: "checkmark.diamond") }
                .disabled(builder.isRunning || debug.isActive || preparingDebugger || ProjectCommands.test(info: builder.info, selection: builder.selection) == nil)
                .help("Run the project's tests (⌘U)")
            Button { toggleBreakpointAtCaret() } label: { Label("Toggle Breakpoint", systemImage: "record.circle") }
                .disabled(editor.active == nil)
                .help("Toggle breakpoint at the caret (⌘\\)")
            if debug.isActive {
                debugControls
            } else {
                Button { startDebugging() } label: { Label(preparingDebugger ? "Preparing…" : "Debug", systemImage: "ant") }
                    .disabled(builder.isRunning || preparingDebugger || ProjectCommands.run(info: builder.info, selection: builder.selection) == nil || !DebugSession.isAvailable)
                    .help("Build, then run under the debugger. Click the gutter to set breakpoints (⌥⌘R)")
            }
            Button { runApp() } label: { Label("Run", systemImage: "play.fill") }
                .disabled(builder.isRunning || debug.isActive || preparingDebugger || ProjectCommands.run(info: builder.info, selection: builder.selection) == nil)
                .help("Build and run (⌘R)")
            if builder.isRunning {
                Button { builder.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            Button { showBuildOptions.toggle() } label: { Label("Build options", systemImage: "terminal") }
                .help("Custom build command")
                .popover(isPresented: $showBuildOptions) {
                    VStack(alignment: .leading, spacing: SSSpacing.s) {
                        Text("Custom build command").font(SSTypography.headline())
                        TextField("Use the detected build command", text: Bindable(builder).customCommand)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave empty to use the project's normal build. A custom command runs in the current project folder.")
                            .font(SSTypography.caption()).foregroundStyle(.secondary)
                    }
                    .padding(SSSpacing.m).frame(width: 300)
                }
            Spacer()
            if builder.isRunning {
                ProgressView().controlSize(.small)
            } else if let status = builder.lastExitStatus {
                Label(status == 0 ? "\(builder.currentKind == .build ? "Build" : builder.currentKind == .test ? "Tests" : "Run") succeeded"
                                  : "\(builder.currentKind == .build ? "Build" : builder.currentKind == .test ? "Tests" : "Run") failed",
                      systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status == 0 ? SSColor.success : SSColor.danger)
                    .font(SSTypography.caption())
            }
            if let document = editor.active, let hunk = LineDiff.hunk(at: caret.line - 1, in: document.gitHunks) {
                Button { document.text = LineDiff.revert(hunk, in: document.text) } label: { Label("Revert Change", systemImage: "arrow.uturn.backward") }
                    .help("Put the lines at the caret back to the committed version")
            }
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Editor settings")
                .popover(isPresented: $showSettings) { settingsPanel }
            if editor.secondary != nil {
                Button { editor.closeSplit() } label: { Label("Unsplit", systemImage: "rectangle") }
            }
            Toggle("Hidden files", isOn: Binding(get: { editor.showHidden }, set: { editor.showHidden = $0; treeVersion += 1 }))
                .toggleStyle(.checkbox).font(SSTypography.caption())
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.xs)
        }
        .frame(height: 38)
    }

    private var settingsPanel: some View {
        @Bindable var settings = EditorSettings.shared
        return Form {
            Stepper("Font size: \(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 9...32)
            Picker("Tab width", selection: $settings.tabWidth) { ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) } }
            Toggle("Insert spaces for Tab", isOn: $settings.insertSpaces)
            Toggle("Wrap long lines", isOn: $settings.softWrap)
            Toggle("Line numbers", isOn: $settings.showLineNumbers)
        }
        .padding(SSSpacing.m).frame(width: 280)
    }

    private var buildPlan: BuildRunner.Plan? {
        if !builder.customCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            return BuildRunner.Plan(title: "Custom", command: builder.customCommand)
        }
        if let plan = ProjectCommands.build(info: builder.info, selection: builder.selection) { return plan }
        return editor.root.flatMap { BuildRunner.detectPlan(in: $0) }
    }

    private var buildCommand: String? { buildPlan?.command }

    @ViewBuilder
    private var debugControls: some View {
        Group {
            if debug.isPaused {
                Button { Task { await debug.resume() } } label: { Label("Continue", systemImage: "play.fill") }.keyboardShortcut("y", modifiers: [.command, .control])
                Button { Task { await debug.stepOver() } } label: { Label("Over", systemImage: "arrow.right.to.line") }.keyboardShortcut("'", modifiers: .command)
                Button { Task { await debug.stepInto() } } label: { Label("Into", systemImage: "arrow.down.to.line") }.keyboardShortcut(";", modifiers: .command)
                Button { Task { await debug.stepOut() } } label: { Label("Out", systemImage: "arrow.up.to.line") }.keyboardShortcut(";", modifiers: [.command, .shift])
            } else {
                Button { Task { await debug.pause() } } label: { Label("Pause", systemImage: "pause.fill") }
            }
            Button { Task { await debug.stop() } } label: { Label("Stop", systemImage: "stop.fill") }.foregroundStyle(SSColor.danger)
        }
    }

    /// Builds with the selected scheme, resolves the executable, then runs it under lldb.
    private func startDebugging() {
        guard !preparingDebugger, !builder.isRunning, !debug.isActive,
              let root = editor.root, let plan = buildPlan else { return }
        guard editor.saveProjectDocuments() else {
            fileError = "Save all changes before starting the debugger."
            return
        }
        let info = builder.info
        let selection = builder.selection
        preparingDebugger = true
        bottomMode = .debug
        showProblems = true
        Task {
            defer { preparingDebugger = false }
            builder.run(command: plan.command, in: root, kind: .build)
            while builder.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard editor.root == root else { return }
            guard builder.lastExitStatus == 0 else { bottomMode = .problems; return }
            guard let program = await ProgramResolver.resolve(info: info, selection: selection, root: root) else {
                fileError = "Kiln could not find the built executable to debug."
                return
            }
            guard editor.root == root else { return }
            await debug.start(program: program, workingDirectory: root)
        }
    }

    private var buildTitle: String {
        if !builder.customCommand.trimmingCharacters(in: .whitespaces).isEmpty { return "Run custom" }
        return buildPlan.map { "Build (\($0.title))" } ?? "Build"
    }

    private func toggleBreakpointAtCaret() {
        guard let document = editor.active else { return }
        editor.toggleBreakpoint(document.url, line: caret.line)
    }

    private func runBuild() {
        guard !debug.isActive, !preparingDebugger else { return }
        guard let root = editor.root, let command = buildCommand else { return }
        guard editor.saveProjectDocuments() else { return }
        builder.run(command: command, in: root, kind: .build)
        showProblems = true
    }

    private func runTests(filter: String? = nil) {
        guard !debug.isActive, !preparingDebugger else { return }
        guard let root = editor.root, let plan = ProjectCommands.test(info: builder.info, selection: builder.selection, filter: filter) else { return }
        guard editor.saveProjectDocuments() else { return }
        builder.run(command: plan.command, in: root, kind: .test)
        showProblems = true
    }

    private func runApp() {
        guard !debug.isActive, !preparingDebugger else { return }
        guard let root = editor.root, let plan = ProjectCommands.run(info: builder.info, selection: builder.selection) else { return }
        guard editor.saveProjectDocuments() else { return }
        builder.run(command: plan.command, in: root, kind: .run)
        showProblems = true
    }

    /// Scheme and configuration pickers, shown when the toolchain reported choices.
    @ViewBuilder
    private var targetPickers: some View {
        if let root = editor.root {
            if builder.info.schemes.count > 0 {
                Picker("Scheme", selection: Binding(
                    get: { builder.selection.scheme ?? builder.info.schemes.first ?? "" },
                    set: { builder.select(scheme: $0, configuration: builder.selection.configuration, root: root) })) {
                    ForEach(builder.info.schemes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 150).help("Scheme")
            }
            if builder.info.configurations.count > 1 {
                Picker("Configuration", selection: Binding(
                    get: { builder.selection.configuration ?? builder.info.configurations.first ?? "" },
                    set: { builder.select(scheme: builder.selection.scheme, configuration: $0, root: root) })) {
                    ForEach(builder.info.configurations, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 110).help("Configuration")
            }
        }
    }

    /// Invisible buttons that carry the keyboard shortcuts while the editor is on screen.
    private var shortcuts: some View {
        HStack {
            Button("") { editor.active.map { editor.save($0) } }.keyboardShortcut("s", modifiers: .command)
            Button("") { editor.saveAll() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { showQuickOpen = true }.keyboardShortcut("p", modifiers: .command)
            Button("") { runBuild() }.keyboardShortcut("b", modifiers: .command)
            Button("") { toggleBreakpointAtCaret() }.keyboardShortcut("\\", modifiers: .command)
            Button("") { if !debug.isActive { startDebugging() } }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("") { runTests() }.keyboardShortcut("u", modifiers: .command)
            Button("") { runApp() }.keyboardShortcut("r", modifiers: .command)
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

    private func refreshChanges() {
        Task { changed = await editor.changedFiles() }
    }

    /// Uncommitted work in the project, including whatever an agent run left: open, review with the gutter, or discard.
    private var changesList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(changed.isEmpty ? "No uncommitted changes" : "\(changed.count) changed file(s)").font(SSTypography.caption())
                Spacer()
                Button { refreshChanges() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .padding(SSSpacing.xs)
            List(changed) { file in
                HStack(spacing: 6) {
                    Text(file.statusCode.isEmpty ? "?" : file.statusCode)
                        .font(SSTypography.mono(10)).frame(width: 18)
                        .foregroundStyle(file.statusCode.contains("?") || file.statusCode == "A" ? SSColor.success : SSColor.warning)
                    Text(file.path).font(SSTypography.caption()).lineLimit(1).truncationMode(.head)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let root = editor.root { Task {
                        let top = await editor.git.topLevel(root.path) ?? root.path
                        editor.open(URL(fileURLWithPath: top).appendingPathComponent(file.path))
                    } }
                }
                .contextMenu { Button("Discard Changes…", role: .destructive) { discarding = file } }
            }
        }
        .onAppear { refreshChanges() }
        .confirmationDialog("Discard changes to \(discarding?.path ?? "this file")?", isPresented: Binding(
            get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Discard Changes", role: .destructive) { discardSelected() }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: { Text("This cannot be undone. Unsaved edits in an open tab for it are dropped too.") }
    }

    private func discardSelected() {
        guard let file = discarding, let root = editor.root else { return }
        discarding = nil
        Task {
            let top = await editor.git.topLevel(root.path) ?? root.path
            let url = URL(fileURLWithPath: top).appendingPathComponent(file.path)
            do {
                try await editor.git.discardChanges(top, path: file.path, untracked: file.statusCode.contains("?"))
                if let open = editor.documents.first(where: { $0.url == url.standardizedFileURL }) {
                    if FileManager.default.fileExists(atPath: url.path) { open.reload() } else { editor.close(open) }
                }
                changed = await editor.changedFiles()
            } catch {
                fileError = error.localizedDescription
            }
        }
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
            } else if navigatorMode == .changes {
                changesList
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
                    .draggable(document.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        editor.moveDocument(id, before: document.id)
                        return true
                    }
                    .contextMenu {
                        Button("Open in Split") { editor.openInSplit(document) }
                        Button("Close") { requestClose(document) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                    }
                    .help(editor.displayPath(document.url))
                }
            }
            .padding(.horizontal, SSSpacing.s).padding(.vertical, 3)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var banners: some View {
        if !editor.recoverable.isEmpty {
            Banner(text: "Unsaved changes from your last session are available for \(editor.recoverable.count) file(s).", tint: SSColor.accent) {
                Button("Open them") { editor.restoreRecoverable() }
                Button("Discard") { editor.discardRecoverable() }
            }
        }
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
            if let other = editor.secondary {
                HSplitView {
                    pane(for: document, tracksCaret: true)
                    VStack(spacing: 0) {
                        HStack {
                            Text(other.name).font(SSTypography.caption()).lineLimit(1)
                            Spacer()
                            Button { editor.closeSplit() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, SSSpacing.s).padding(.vertical, 3).background(Color.primary.opacity(0.06))
                        pane(for: other, tracksCaret: false)
                    }
                }
            } else {
                pane(for: document, tracksCaret: true)
            }
        } else {
            SSEmptyState(symbol: "doc.text", title: "No file open",
                         message: "Pick a file in the navigator, or press ⌘P to open one by name.")
        }
    }

    @ViewBuilder
    private func pane(for document: EditorDocument, tracksCaret: Bool) -> some View {
        switch document.status {
        case .editable:
            CodeTextView(
                document: document,
                language: SyntaxHighlighter.language(for: document.url),
                jump: editor.pendingLine.flatMap { $0.id == document.id ? ($0.line, $0.column) : nil },
                onJumpDone: { editor.pendingLine = nil },
                onCaretMove: { if tracksCaret { caret = ($0, $1) } },
                diagnostics: editor.languageServer.diagnostics[document.url.path] ?? [],
                onEdited: { editor.noteEdited(document) },
                breakpointLines: editor.breakpointLines(for: document.url),
                executionLine: debug.currentLocation.flatMap { DebugSession.canonicalSourcePath($0.path) == DebugSession.canonicalSourcePath(document.url.path) ? $0.line : nil },
                onToggleBreakpoint: { editor.toggleBreakpoint(document.url, line: $0) },
                onDefinition: { line, column in
                    Task {
                        if let target = await editor.languageServer.definition(url: document.url, line: line, column: column) {
                            editor.open(URL(fileURLWithPath: target.path), line: target.line + 1, column: target.column + 1)
                        }
                    }
                },
                onComplete: { line, column in
                    await editor.languageServer.completions(url: document.url, line: line, column: column).map(\.insertText)
                }
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
                Label("\(allDiagnostics.filter { $0.severity == .error }.count) errors, \(allDiagnostics.filter { $0.severity == .warning }.count) warnings",
                      systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.plain)
        }
        .font(SSTypography.caption())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, SSSpacing.m).padding(.vertical, 3)
    }

    private var debugPanel: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 620 {
                HSplitView {
                    debugFrames.frame(minWidth: 180)
                    debugVariables.frame(minWidth: 200)
                    debugConsole.frame(minWidth: 180)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Debugger pane", selection: $debugPane) {
                        ForEach(DebugPane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, SSSpacing.xs)
                    switch debugPane {
                    case .stack: debugFrames
                    case .variables: debugVariables
                    case .console: debugConsole
                    }
                }
            }
        }
    }

    private var debugFrames: some View {
            List(debug.frames) { frame in
                Button { Task { await debug.selectFrame(frame.id) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(frame.name).font(SSTypography.caption()).lineLimit(1)
                        Text(frame.path.map { "\(editor.displayPath(URL(fileURLWithPath: $0))):\(frame.line)" } ?? "no source")
                            .font(SSTypography.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .padding(.vertical, 1)
                    .background(frame.id == debug.selectedFrameID ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            .overlay { if debug.frames.isEmpty { Text(debugStatus).font(SSTypography.caption()).foregroundStyle(.secondary) } }
    }

    private var debugVariables: some View {
            List(debug.variables) { variable in
                HStack(alignment: .top, spacing: 6) {
                    Text(variable.name).font(SSTypography.mono(11)).foregroundStyle(SSColor.accent)
                    Text(variable.value).font(SSTypography.mono(11)).lineLimit(4).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if let type = variable.type { Text(type).font(SSTypography.mono(9)).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
    }

    private var debugConsole: some View {
            ScrollView {
                Text(debug.console.isEmpty ? " " : debug.console).font(SSTypography.mono(10)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(SSSpacing.xs)
            }
    }

    private var debugStatus: String {
        switch debug.state {
        case .idle: "Press Debug (⌥⌘R) to build and run under the debugger. Click the gutter to set breakpoints."
        case .starting: "Starting…"
        case .running: "Running. Hit a breakpoint or press Pause."
        case .paused(let reason): "Paused (\(reason))"
        case .finished(let code): "Finished" + (code.map { " with exit code \($0)" } ?? "")
        case .failed(let message): message
        }
    }

    private var problemsPanel: some View {
        VStack(spacing: 0) {
            Divider()
            Picker("", selection: $bottomMode) {
                ForEach(BottomMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220).padding(SSSpacing.xs)
            if bottomMode == .debug {
                debugPanel
            } else if allDiagnostics.isEmpty && builder.output.isEmpty {
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
                    List(allDiagnostics) { diagnostic in
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
                    if !builder.testResults.isEmpty {
                        List(builder.testResults) { result in
                            HStack(spacing: 6) {
                                Image(systemName: result.status == .passed ? "checkmark.circle.fill" : result.status == .failed ? "xmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(result.status == .passed ? SSColor.success : result.status == .failed ? SSColor.danger : .secondary)
                                Text(result.name).font(SSTypography.caption()).lineLimit(2)
                                Spacer()
                                if let seconds = result.seconds { Text(String(format: "%.2fs", seconds)).font(SSTypography.mono(10)).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                            .contextMenu { Button("Run only this test") { runTests(filter: result.name) } }
                        }
                        .frame(minWidth: 200)
                    }
                    ScrollView {
                        Text(builder.output).font(SSTypography.mono(10)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(SSSpacing.xs)
                    }
                    .frame(minWidth: 200)
                }
            }
        }
        .frame(height: 190)
        .clipped()
    }

    /// Puts the build errors in the agent's message box; the user reads and sends it.
    private func askAgentToFix() {
        let errors = builder.diagnostics.filter { $0.severity == .error }.prefix(15)
            .map { "\(editor.displayPath(URL(fileURLWithPath: $0.path))):\($0.line): \($0.message)" }
            .joined(separator: "\n")
        app.chatSession?.draft = "The build failed. Fix these errors in \(editor.root?.path ?? "the project"), then rebuild to confirm:\n\n\(errors)"
    }

    /// Build problems plus the language server's live ones for the file in front.
    private var allDiagnostics: [Diagnostic] {
        var list = builder.diagnostics
        if let document = editor.active {
            for live in editor.languageServer.diagnostics[document.url.path] ?? [] {
                list.append(Diagnostic(path: document.url.path, line: live.line + 1, column: live.column + 1, severity: live.severity, message: live.message))
            }
        }
        return list
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
