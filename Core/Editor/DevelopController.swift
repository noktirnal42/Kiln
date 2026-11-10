import Foundation

/// The Develop activity's actions as a service: open at a line, outline, definition, references, rename, build, test,
/// run and debug. The editor view, the command palette, the agent tools (`ide_*`) and the MCP server all call this, so
/// there is one implementation of each action and nothing lives only in a view.
@MainActor @Observable
public final class DevelopController {
    public let editor: EditorWorkspace
    public let builder: BuildRunner
    public private(set) var preparingDebugger = false
    /// A message for the user (shown as an alert by the editor view), cleared when dismissed.
    public var error: String?
    /// One-line description of what the IDE is doing right now, for the status bar's activity strip.
    public var activity: String? {
        if preparingDebugger { return "Preparing the debugger…" }
        if builder.isRunning {
            switch builder.currentKind { case .build: return "Building…"; case .test: return "Testing…"; case .run: return "Running…" }
        }
        switch editor.debug.state {
        case .starting: return "Starting the debugger…"
        case .running: return "Debugging — running"
        case .paused(let reason): return "Debugging — paused (\(reason))"
        default: break
        }
        if case .starting = editor.languageServer.state { return "Starting the language server…" }
        return nil
    }

    // MARK: Interface state shared by the view, the palette and the agent

    public enum Navigator: String, CaseIterable, Sendable {
        case files = "Files", symbols = "Symbols", find = "Find", issues = "Issues", tests = "Tests", changes = "Changes"
        public var symbolName: String {
            switch self {
            case .files: "folder"; case .symbols: "list.bullet.indent"; case .find: "magnifyingglass"
            case .issues: "exclamationmark.triangle"; case .tests: "checkmark.diamond"; case .changes: "plusminus.circle"
            }
        }
    }
    public var navigator: Navigator = .files
    /// Something the palette or an agent asked the editor view to show; the view handles it and clears it.
    public enum Request: Equatable, Sendable { case rename, quickOpen, goToLine, showProblems, showDebug, quickHelp }
    public var request: Request?
    public var showNavigator = true
    public var showBottom = true
    public var showInspector = false
    /// Outline per open document (language server symbols, or the pattern outline), refreshed as the text changes.
    public private(set) var outlines: [UUID: [LSPSymbol]] = [:]
    /// Last Find References / search-for-symbol result shown in the Find navigator.
    public var references: (title: String, places: [Place])?
    /// Quick Help text for the symbol last asked about.
    public var quickHelp: String?

    public func refreshOutline(for document: EditorDocument) async {
        let symbols = await outline(for: document)
        outlines[document.id] = symbols
    }

    /// Back / forward through places the editor has been (jump to definition, search hits, the debugger's stops).
    public private(set) var history: [(path: String, line: Int)] = []
    public private(set) var historyIndex = -1
    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex + 1 < history.count }

    /// Records the current place; called before a jump so ⌃⌘← returns to it.
    public func recordPlace(path: String, line: Int) {
        if historyIndex >= 0, history[historyIndex].path == path, abs(history[historyIndex].line - line) < 3 { return }
        history = Array(history.prefix(historyIndex + 1)) + [(path, line)]
        if history.count > 60 { history.removeFirst() }
        historyIndex = history.count - 1
    }

    public func goBack() { step(-1) }
    public func goForward() { step(1) }
    private func step(_ delta: Int) {
        let target = historyIndex + delta
        guard history.indices.contains(target) else { return }
        // Remember where we are now before leaving the newest entry.
        if delta < 0, historyIndex == history.count - 1, let active = editor.active { recordPlace(path: active.url.path, line: editor.caret.line) }
        historyIndex = min(max(historyIndex + delta, 0), history.count - 1)
        let place = history[historyIndex]
        editor.open(URL(fileURLWithPath: place.path), line: place.line)
    }

    /// Opens a place and remembers where the user was.
    public func jump(to path: String, line: Int, column: Int = 1) {
        if let active = editor.active { recordPlace(path: active.url.path, line: editor.caret.line) }
        editor.open(URL(fileURLWithPath: path), line: line, column: column)
        recordPlace(path: path, line: line)
    }

    public init(editor: EditorWorkspace, builder: BuildRunner) {
        self.editor = editor
        self.builder = builder
    }

    public enum IDEError: Error, LocalizedError, Equatable {
        case noProject, noBuildPlan, busy(String), notFound(String), unavailable(String), failed(String)
        public var errorDescription: String? {
            switch self {
            case .noProject: "No project folder is open. Pick a folder first."
            case .noBuildPlan: "Kiln could not work out how to build this folder (no Package.swift, Xcode project, Cargo.toml, go.mod, package.json or Makefile)."
            case .busy(let what): what
            case .notFound(let what): what
            case .unavailable(let what): what
            case .failed(let why): why
            }
        }
    }

    // MARK: Project

    /// Points the editor and the builder at a folder (the agent's workspace) and reads its schemes.
    public func attach(root: URL) async {
        editor.setRoot(root.path)
        await builder.loadProject(at: root)
    }

    public var buildPlan: BuildRunner.Plan? {
        if !builder.customCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            return BuildRunner.Plan(title: "Custom", command: builder.customCommand)
        }
        if let plan = ProjectCommands.build(info: builder.info, selection: builder.selection) { return plan }
        return editor.root.flatMap { BuildRunner.detectPlan(in: $0) }
    }

    private func requireRoot() throws -> URL {
        guard let root = editor.root else { throw IDEError.noProject }
        return root
    }

    /// Resolves a path given relative to the project (or absolute inside it).
    public func resolve(_ path: String) throws -> URL {
        let root = try requireRoot()
        return try WorkspacePathResolver.resolve(path, in: root)
    }

    // MARK: Opening

    @discardableResult
    public func open(path: String, line: Int? = nil, column: Int = 1) throws -> EditorDocument {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw IDEError.notFound("\(path) does not exist.") }
        return editor.open(url, line: line, column: column)
    }

    // MARK: Build, test, run

    public struct RunReport: Equatable, Sendable {
        public var kind: String
        public var command: String
        public var finished: Bool
        public var exitStatus: Int32?
        public var errors: Int
        public var warnings: Int
        public var issues: [Diagnostic]
        public var tests: [TestResult]
        public var tail: String

        public var succeeded: Bool { finished && exitStatus == 0 }

        public func rendered(root: URL?, issueLimit: Int = 40) -> String {
            var lines: [String] = []
            if !finished { lines.append("\(kind) is still running (\(command)). Call ide_build_status for progress or ide_stop to cancel.") }
            else { lines.append("\(kind) \(exitStatus == 0 ? "succeeded" : "failed (exit \(exitStatus ?? -1))") — \(errors) error(s), \(warnings) warning(s).") }
            for issue in issues.prefix(issueLimit) {
                let path = root.flatMap { WorkspacePathResolver.relativePath(of: issue.path, under: $0) } ?? issue.path
                lines.append("\(path):\(issue.line):\(issue.column): \(issue.severity.rawValue): \(issue.message)")
            }
            if issues.count > issueLimit { lines.append("… \(issues.count - issueLimit) more issue(s).") }
            if !tests.isEmpty {
                let failed = tests.filter { $0.status == .failed }
                lines.append("Tests: \(tests.count - failed.count) passed, \(failed.count) failed, of \(tests.count).")
                for test in failed.prefix(20) { lines.append("  ✘ \(test.name)") }
            }
            if !(finished && exitStatus == 0) || issues.isEmpty && tests.isEmpty {
                let tail = self.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { lines.append("--- output (tail) ---\n" + tail) }
            }
            return lines.joined(separator: "\n")
        }
    }

    private func checkIdle() throws {
        if builder.isRunning { throw IDEError.busy("A \(builder.currentKind.rawValue) is already running. Wait for it or stop it first.") }
        if preparingDebugger || editor.debug.isActive { throw IDEError.busy("The debugger is active. Stop it first.") }
    }

    private func start(_ plan: BuildRunner.Plan, kind: BuildRunner.RunKind) throws {
        try checkIdle()
        let root = try requireRoot()
        guard editor.saveProjectDocuments() else { throw IDEError.failed("Save all changes in the project first (some files have conflicts).") }
        builder.run(command: plan.command, in: root, kind: kind)
    }

    /// Starts a build without waiting. The UI uses this; agents use `buildAndWait`.
    public func startBuild() throws {
        guard let plan = buildPlan else { throw IDEError.noBuildPlan }
        try start(plan, kind: .build)
    }

    public func startTests(filter: String? = nil) throws {
        guard let plan = ProjectCommands.test(info: builder.info, selection: builder.selection, filter: filter) else {
            throw IDEError.unavailable("This project has no test command Kiln recognises.")
        }
        try start(plan, kind: .test)
    }

    public func startRun() throws {
        guard let plan = ProjectCommands.run(info: builder.info, selection: builder.selection) else {
            throw IDEError.unavailable("This project has nothing Kiln knows how to run.")
        }
        try start(plan, kind: .run)
    }

    public func stop() async {
        builder.cancel()
        if editor.debug.isActive { await editor.debug.stop() }
    }

    public func report(finishedOnly: Bool = false, command: String = "") -> RunReport {
        RunReport(kind: builder.currentKind.rawValue.capitalized, command: command, finished: !builder.isRunning,
                  exitStatus: builder.lastExitStatus, errors: builder.errorCount, warnings: builder.warningCount,
                  issues: builder.diagnostics, tests: builder.testResults, tail: String(builder.output.suffix(2500)))
    }

    /// Waits for the current run to finish, up to `timeout` seconds.
    public func waitForBuilder(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while builder.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    public func buildAndWait(timeout: TimeInterval = 600) async throws -> RunReport {
        try startBuild()
        await waitForBuilder(timeout: timeout)
        return report(command: buildPlan?.command ?? "")
    }

    public func testAndWait(filter: String? = nil, timeout: TimeInterval = 900) async throws -> RunReport {
        try startTests(filter: filter)
        await waitForBuilder(timeout: timeout)
        return report(command: "tests")
    }

    /// Runs the project's executable; returns when it exits or after `timeout` seconds (it keeps running then).
    public func runAndWait(timeout: TimeInterval = 60) async throws -> RunReport {
        try startRun()
        await waitForBuilder(timeout: timeout)
        return report(command: "run")
    }

    // MARK: Debugging

    public func startDebugging() async throws {
        try checkIdle()
        let root = try requireRoot()
        guard let plan = buildPlan else { throw IDEError.noBuildPlan }
        guard DebugSession.isAvailable else { throw IDEError.unavailable("lldb was not found. Install the Xcode command line tools.") }
        guard editor.saveProjectDocuments() else { throw IDEError.failed("Save all changes in the project first.") }
        let info = builder.info, selection = builder.selection
        preparingDebugger = true
        defer { preparingDebugger = false }
        builder.run(command: plan.command, in: root, kind: .build)
        while builder.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard editor.root == root else { return }
        guard builder.lastExitStatus == 0 else {
            throw IDEError.failed("The build failed, so there is nothing to debug (\(builder.errorCount) error(s)).")
        }
        guard let program = await ProgramResolver.resolve(info: info, selection: selection, root: root) else {
            throw IDEError.failed("Kiln could not find the built executable to debug.")
        }
        guard editor.root == root else { return }
        await editor.debug.start(program: program, workingDirectory: root)
        if case .failed(let message) = editor.debug.state { throw IDEError.failed(message) }
    }

    /// Waits until the debugger stops at a breakpoint, exits or fails (or `timeout` passes).
    public func waitForDebugStop(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch editor.debug.state {
            case .running, .starting: try? await Task.sleep(nanoseconds: 100_000_000)
            default: return
            }
        }
    }

    public enum DebugAction: String, CaseIterable, Sendable { case `continue`, pause, stepOver = "step_over", stepInto = "step_into", stepOut = "step_out", stop }

    public func debug(_ action: DebugAction, wait: TimeInterval = 15) async throws {
        let session = editor.debug
        guard session.isActive else { throw IDEError.busy("The debugger is not running. Start it with ide_debug_start.") }
        if action != .pause, action != .stop, !session.isPaused { throw IDEError.busy("The program is running; pause it or wait for a breakpoint first.") }
        switch action {
        case .continue: await session.resume()
        case .pause: await session.pause()
        case .stepOver: await session.stepOver()
        case .stepInto: await session.stepInto()
        case .stepOut: await session.stepOut()
        case .stop: await session.stop(); return
        }
        await waitForDebugStop(timeout: wait)
    }

    /// Plain-text summary of the debugger: state, stack, locals and the tail of the program's output.
    public func debugSummary(root: URL? = nil) -> String {
        let session = editor.debug
        var lines: [String] = []
        switch session.state {
        case .idle: lines.append("Debugger: idle.")
        case .starting: lines.append("Debugger: starting.")
        case .running: lines.append("Debugger: program running.")
        case .paused(let reason): lines.append("Debugger: paused (\(reason)).")
        case .finished(let code): lines.append("Debugger: program finished" + (code.map { " with exit code \($0)." } ?? "."))
        case .failed(let message): lines.append("Debugger: failed — \(message)")
        }
        if let location = session.currentLocation {
            lines.append("At \(editor.displayPath(URL(fileURLWithPath: location.path))):\(location.line)")
        }
        if !session.threads.isEmpty {
            lines.append("Threads:")
            for thread in session.threads.prefix(20) { lines.append("  \(thread.selected ? "*" : " ") #\(thread.id) \(thread.summary)") }
        }
        if !session.frames.isEmpty {
            lines.append("Stack:")
            for frame in session.frames.prefix(30) {
                let place = frame.path.map { " at \(editor.displayPath(URL(fileURLWithPath: $0))):\(frame.line)" } ?? ""
                lines.append("  #\(frame.id) \(frame.name)\(place)")
            }
        }
        if !session.variables.isEmpty {
            lines.append("Variables:")
            for variable in session.variables.prefix(60) { lines.append("  \(variable.name) = \(variable.value)" + (variable.type.map { "  (\($0))" } ?? "")) }
        }
        let breakpoints = session.breakpoints.flatMap { path, lines in lines.sorted().map { (path, $0) } }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        if !breakpoints.isEmpty {
            lines.append("Breakpoints:")
            for (path, line) in breakpoints {
                let condition = session.breakpointConditions[path]?[line].map { "  if \($0)" } ?? ""
                lines.append("  \(editor.displayPath(URL(fileURLWithPath: path))):\(line)\(condition)")
            }
        }
        let output = session.console.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { lines.append("Console (tail):\n" + String(output.suffix(1500))) }
        return lines.joined(separator: "\n")
    }

    public func setBreakpoint(path: String, line: Int, condition: String? = nil, enabled: Bool = true) throws {
        let url = try resolve(path)
        guard line >= 1 else { throw IDEError.failed("Lines start at 1.") }
        let has = editor.breakpointLines(for: url).contains(line)
        if enabled && !has { editor.toggleBreakpoint(url, line: line) }
        if !enabled && has { editor.toggleBreakpoint(url, line: line) }
        editor.setBreakpointCondition(url, line: line, condition: enabled ? condition : nil)
    }

    // MARK: Language services

    /// Opens the file (so the server knows it) and waits for sourcekit-lsp to be ready. False when there is no server.
    @discardableResult
    public func prepareLanguageServer(for document: EditorDocument, timeout: TimeInterval = 30) async -> Bool {
        guard editor.serves(document) else { return false }
        editor.startLanguageServerIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        var idleTicks = 0
        while Date() < deadline {
            switch editor.languageServer.state {
            case .running: return true
            case .failed: return false
            case .starting: idleTicks = 0
            case .stopped:
                idleTicks += 1          // the start is kicked off asynchronously; give it a moment before giving up
                if idleTicks > 20 { return false }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return editor.languageServer.state == .running
    }

    /// The outline of a document: from the language server when it answers, otherwise from the pattern outline.
    public func outline(for document: EditorDocument) async -> [LSPSymbol] {
        if editor.serves(document), editor.languageServer.state == .running {
            let symbols = await editor.languageServer.documentSymbols(url: document.url)
            if !symbols.isEmpty { return symbols }
        }
        return SymbolOutline.symbols(in: document.text, language: SyntaxHighlighter.language(for: document.url))
    }

    public struct Place: Equatable, Sendable {
        public var path: String
        public var line: Int       // 1-based
        public var column: Int     // 1-based
        public var text: String
    }

    public func definition(path: String, line: Int, column: Int) async throws -> Place? {
        let document = try open(path: path)
        guard await prepareLanguageServer(for: document) else {
            throw IDEError.unavailable("No language server is available for this file (sourcekit-lsp serves Swift and C-family files).")
        }
        guard let place = await editor.languageServer.definition(url: document.url, line: line - 1, column: column - 1) else { return nil }
        return makePlace(place)
    }

    public func references(path: String, line: Int, column: Int) async throws -> [Place] {
        let document = try open(path: path)
        guard await prepareLanguageServer(for: document) else {
            // No server: fall back to whole-word text matches of the word under the position.
            return textReferences(document: document, line: line, column: column)
        }
        let found = await editor.languageServer.references(url: document.url, line: line - 1, column: column - 1)
        return found.map(makePlace)
    }

    public func hover(path: String, line: Int, column: Int) async throws -> String? {
        let document = try open(path: path)
        guard await prepareLanguageServer(for: document) else { return nil }
        return await editor.languageServer.hover(url: document.url, line: line - 1, column: column - 1)
    }

    func makePlace(_ location: LSPLocation) -> Place {
        let text = (try? String(contentsOfFile: location.path, encoding: .utf8))?
            .components(separatedBy: "\n").dropFirst(location.line).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return Place(path: location.path, line: location.line + 1, column: location.column + 1, text: String(text.prefix(200)))
    }

    /// The identifier at a 1-based position, or nil.
    public static func word(in text: String, line: Int, column: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        let chars = Array(lines[line - 1])
        guard !chars.isEmpty else { return nil }
        var index = min(max(column - 1, 0), chars.count - 1)
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        if !isWord(chars[index]), index > 0, isWord(chars[index - 1]) { index -= 1 }
        guard isWord(chars[index]) else { return nil }
        var start = index, end = index
        while start > 0, isWord(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, isWord(chars[end + 1]) { end += 1 }
        return String(chars[start...end])
    }

    private func textReferences(document: EditorDocument, line: Int, column: Int) -> [Place] {
        guard let root = editor.root, let word = Self.word(in: document.text, line: line, column: column) else { return [] }
        let pattern = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b")
        return ProjectSearch.search(root: root, query: word, caseSensitive: true, limit: 500).compactMap { hit in
            guard let pattern, pattern.firstMatch(in: hit.text, range: NSRange(hit.text.startIndex..., in: hit.text)) != nil else { return nil }
            return Place(path: hit.path, line: hit.line, column: hit.column, text: hit.text)
        }
    }

    // MARK: Rename

    public struct RenameResult: Equatable, Sendable {
        public var files: [String]
        public var edits: Int
        public var applied: Bool
    }

    /// Renames the symbol at a 1-based position through the language server. With `apply` false, only reports what would change.
    public func rename(path: String, line: Int, column: Int, to newName: String, apply: Bool = true) async throws -> RenameResult {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { throw IDEError.failed("The new name must be one identifier.") }
        let document = try open(path: path)
        guard await prepareLanguageServer(for: document) else {
            throw IDEError.unavailable("Rename needs a language server (sourcekit-lsp for Swift and C-family files); none is available for this file.")
        }
        guard let edit = await editor.languageServer.rename(url: document.url, line: line - 1, column: column - 1, to: name), edit.editCount > 0 else {
            throw IDEError.failed("The language server could not rename the symbol at \(path):\(line):\(column).")
        }
        let root = editor.root
        let files = edit.edits.keys.sorted().map { path in root.flatMap { WorkspacePathResolver.relativePath(of: path, under: $0) } ?? path }
        guard apply else { return RenameResult(files: files, edits: edit.editCount, applied: false) }
        try applyEdit(edit)
        return RenameResult(files: files, edits: edit.editCount, applied: true)
    }

    /// Applies a workspace edit: open documents are edited and saved, others are rewritten on disk. Only files inside the project.
    public func applyEdit(_ edit: LSPWorkspaceEdit) throws {
        let root = try requireRoot()
        for (path, _) in edit.edits {
            guard WorkspacePathResolver.relativePath(of: path, under: root) != nil else {
                throw IDEError.failed("Refusing to edit \(path): it is outside the project.")
            }
        }
        for (path, edits) in edit.edits {
            let url = URL(fileURLWithPath: path)
            if let document = editor.documents.first(where: { DebugSession.canonicalSourcePath($0.url.path) == DebugSession.canonicalSourcePath(path) }) {
                document.text = LSPWorkspaceEdit.apply(edits, to: document.text)
                editor.noteEdited(document)
                editor.save(document)
                if document.isDirty { throw IDEError.failed(editor.message ?? "Could not save \(url.lastPathComponent).") }
            } else {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw IDEError.failed("Could not read \(url.lastPathComponent).") }
                try LSPWorkspaceEdit.apply(edits, to: text).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Diagnostics

    /// Language-server diagnostics for open files and the last build's issues, as plain lines.
    public func diagnosticsSummary(path: String? = nil) throws -> String {
        var lines: [String] = []
        let filter = try path.map { try resolve($0).path }
        for (file, list) in editor.languageServer.diagnostics.sorted(by: { $0.key < $1.key }) where filter == nil || file == filter {
            for d in list { lines.append("\(editor.displayPath(URL(fileURLWithPath: file))):\(d.line + 1):\(d.column + 1): \(d.severity.rawValue): \(d.message)  [editor]") }
        }
        for d in builder.diagnostics where filter == nil || d.path == filter {
            lines.append("\(editor.displayPath(URL(fileURLWithPath: d.path))):\(d.line):\(d.column): \(d.severity.rawValue): \(d.message)  [build]")
        }
        return lines.isEmpty ? "No issues." : lines.joined(separator: "\n")
    }

    // MARK: At the caret (menus, palette, shortcuts)

    private func caretTarget() -> (path: String, line: Int, column: Int)? {
        guard let document = editor.active else { error = "Open a file first."; return nil }
        return (document.url.path, editor.caret.line, editor.caret.column)
    }

    public func goToDefinition(path: String? = nil, line: Int? = nil, column: Int? = nil) async {
        guard let target = caretTarget() else { return }
        let (p, l, c) = (path ?? target.path, line ?? target.line, column ?? target.column)
        do {
            if let place = try await definition(path: p, line: l, column: c) { jump(to: place.path, line: place.line, column: place.column) }
            else { error = "No definition found." }
        } catch { self.error = error.localizedDescription }
    }

    public func findReferences(path: String? = nil, line: Int? = nil, column: Int? = nil) async {
        guard let target = caretTarget() else { return }
        let (p, l, c) = (path ?? target.path, line ?? target.line, column ?? target.column)
        do {
            let places = try await references(path: p, line: l, column: c)
            let word = (try? resolve(p)).flatMap { url in editor.documents.first { $0.url == url }?.text }.flatMap { Self.word(in: $0, line: l, column: c) } ?? "symbol"
            references = ("References to \(word)", places)
            navigator = .find
            showNavigator = true
            if places.isEmpty { error = "No references found for \(word)." }
        } catch { self.error = error.localizedDescription }
    }

    public func showQuickHelp(path: String? = nil, line: Int? = nil, column: Int? = nil) async {
        guard let target = caretTarget() else { return }
        do {
            quickHelp = try await hover(path: path ?? target.path, line: line ?? target.line, column: column ?? target.column)
            if quickHelp == nil { error = "No Quick Help for that position." }
        } catch { self.error = error.localizedDescription }
    }

    public func renameAtCaret(to name: String) async {
        guard let target = caretTarget() else { return }
        do {
            let result = try await rename(path: target.path, line: target.line, column: target.column, to: name)
            references = ("Renamed in \(result.files.count) file(s), \(result.edits) edit(s)", result.files.map { Place(path: (try? resolve($0).path) ?? $0, line: 1, column: 1, text: $0) })
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Blame

    public func blame(path: String) async throws -> [GitBlameLine] {
        let url = try resolve(path)
        let service = editor.git
        guard let top = await service.topLevel(url.deletingLastPathComponent().path), url.path.hasPrefix(top + "/") else {
            throw IDEError.unavailable("\(path) is not in a Git repository.")
        }
        return try await service.blame(top, path: String(url.path.dropFirst(top.count + 1)))
    }
}
