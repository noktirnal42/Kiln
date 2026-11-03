import Foundation

/// A node in the file navigator.
public struct FileNode: Identifiable, Hashable, Sendable {
    public var url: URL
    public var isDirectory: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

/// The editor's shared state for the whole app: which folder is open, which files are open, and which one is in
/// front. It lives in `AppModel`, not in a view, so unsaved edits are still there after visiting another tool.
@MainActor @Observable
public final class EditorWorkspace {
    public private(set) var root: URL?
    public var git = GitService()
    /// Live diagnostics, go to definition and completion for Swift / C-family files (sourcekit-lsp).
    public let languageServer = LanguageServerClient()
    /// The debugger; breakpoints are kept per project and survive relaunch.
    public let debug = DebugSession()
    public var languageServerEnabled = true
    public private(set) var documents: [EditorDocument] = []
    public var activeID: UUID?
    /// A second editor pane beside the active one (split view); nil when not split.
    public var secondaryID: UUID?
    public var secondary: EditorDocument? {
        guard let secondaryID, secondaryID != activeID else { return nil }
        return documents.first { $0.id == secondaryID }
    }
    public func openInSplit(_ document: EditorDocument) {
        guard document.id != activeID else { return }
        secondaryID = document.id
    }
    public func closeSplit() { secondaryID = nil }
    /// A line to scroll to the next time the active document is shown (from a diagnostic or go-to-line).
    public var pendingLine: (id: UUID, line: Int, column: Int)?
    public var message: String?
    public var showHidden = false

    private var pollTask: Task<Void, Never>?
    private let recovery: EditorRecoveryStore

    public init(recovery: EditorRecoveryStore = EditorRecoveryStore()) {
        self.recovery = recovery
    }

    /// Files from a previous session that have unsaved work waiting; shown as a banner until opened or discarded.
    public private(set) var recoverable: [URL] = []

    public func refreshRecoverable() {
        let open = Set(documents.map(\.url))
        recoverable = recovery.pendingURLs().filter { !open.contains($0.standardizedFileURL) }
    }

    public func restoreRecoverable() {
        for url in recoverable { open(url) }
        recoverable = []
    }

    public func discardRecoverable() {
        for url in recoverable { recovery.discard(for: url) }
        recoverable = []
    }

    /// Called when the user quits and chooses Don't Save: nothing should be offered back next launch.
    public func discardAllUnsaved() {
        recovery.discardAll()
        recoverable = []
    }

    public var active: EditorDocument? { documents.first { $0.id == activeID } }
    public var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }
    public var dirtyDocuments: [EditorDocument] { documents.filter(\.isDirty) }

    // MARK: Workspace

    /// Points the editor at a project folder. Open files outside it stay open (they are still the user's work).
    public func setRoot(_ path: String?) {
        guard let path, !path.isEmpty else {
            if root != nil { languageServer.stop(); debug.reset() }
            root = nil
            debug.breakpoints = [:]
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url != root else { return }
        if root != nil { languageServer.stop(); debug.reset() }
        root = url
        loadBreakpoints()
    }

    public nonisolated static let ignoredNames: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".DS_Store", "build", "dist", "xcuserdata", "__pycache__", ".venv",
        ".swiftpm", "Pods", "target",
    ]

    /// One level of the navigator, folders first. Hidden files and build output are skipped unless asked for.
    public func children(of directory: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { showHidden || !Self.ignoredNames.contains($0.lastPathComponent) }
            .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: Set(keys)))?.isDirectory ?? false) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Every file under the root (bounded), for quick open.
    public func allFiles(limit: Int = 20_000) -> [URL] {
        guard let root else { return [] }
        var result: [URL] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            if Self.ignoredNames.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            result.append(url)
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: Documents

    @discardableResult
    public func open(_ url: URL, line: Int? = nil, column: Int = 1) -> EditorDocument {
        let url = url.standardizedFileURL
        if let existing = documents.first(where: {
            DebugSession.canonicalSourcePath($0.url.path) == DebugSession.canonicalSourcePath(url.path)
        }) {
            activeID = existing.id
            existing.checkForExternalChange()
            if let line { pendingLine = (existing.id, line, column) }
            return existing
        }
        let document = EditorDocument(url: url)
        if let saved = recovery.recovered(for: url, currentDiskText: document.text) {
            document.applyRecovered(saved)
        }
        documents.append(document)
        loadGitBase(for: document)
        startLanguageServerIfNeeded()
        if serves(document) { languageServer.didOpen(url: document.url, text: document.text) }
        activeID = document.id
        if let line { pendingLine = (document.id, line, column) }
        return document
    }

    func serves(_ document: EditorDocument) -> Bool {
        document.isEditable && LanguageServerClient.serves(SyntaxHighlighter.language(for: document.url))
    }

    /// Starts sourcekit-lsp for the project the first time a Swift/C file is open, then announces the open files.
    public func startLanguageServerIfNeeded() {
        guard languageServerEnabled, let root, documents.contains(where: serves) else { return }
        switch languageServer.state {
        case .stopped:
            Task {
                await languageServer.start(root: root)
                if languageServer.state == .running {
                    for document in documents where serves(document) { languageServer.didOpen(url: document.url, text: document.text) }
                }
            }
        default: break
        }
    }

    /// Called as the user types; the server sees the whole text (full sync).
    public func noteEdited(_ document: EditorDocument) {
        guard serves(document) else { return }
        languageServer.didChange(url: document.url, text: document.text)
    }

    // MARK: Breakpoints

    private var breakpointsKey: String { "debug.breakpoints." + (root?.path ?? "") }

    private func loadBreakpoints() {
        let stored = UserDefaults.standard.dictionary(forKey: breakpointsKey) as? [String: [Int]] ?? [:]
        debug.breakpoints = stored.mapValues(Set.init)
    }

    public func toggleBreakpoint(_ url: URL, line: Int) {
        debug.toggleBreakpoint(path: url.path, line: line)
        UserDefaults.standard.set(debug.breakpoints.mapValues { $0.sorted() }, forKey: breakpointsKey)
    }

    public func breakpointLines(for url: URL) -> Set<Int> { debug.breakpoints[url.path] ?? [] }

    /// Reads the committed version off the main thread; the gutter markers appear once it arrives.
    public func loadGitBase(for document: EditorDocument) {
        let url = document.url
        let service = git
        Task { [weak document] in
            let directory = url.deletingLastPathComponent().path
            guard let top = await service.topLevel(directory), url.path.hasPrefix(top + "/") else { return }
            let relative = String(url.path.dropFirst(top.count + 1))
            let base = await service.headContent(top, relativePath: relative)
            await MainActor.run { document?.gitBase = base }
        }
    }

    /// Files with uncommitted changes in the project (what an agent run or a manual edit left behind).
    public func changedFiles() async -> [GitFileStatus] {
        guard let root else { return [] }
        let service = git
        guard let top = await service.topLevel(root.path) else { return [] }
        return (try? await service.status(top)) ?? []
    }

    /// Path relative to the project root (or absolute when outside it), as shown in diagnostics and tabs.
    public func displayPath(_ url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.path }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    public func save(_ document: EditorDocument, overwrite: Bool = false) {
        do {
            try document.save(overwrite: overwrite)
            recovery.discard(for: document.url)
            loadGitBase(for: document)
            if serves(document) { languageServer.didSave(url: document.url) }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Build actions save only the current project; unrelated open drafts remain untouched.
    @discardableResult
    public func saveProjectDocuments() -> Bool {
        guard let root else { return false }
        let directory = DebugSession.canonicalSourcePath(root.path)
        func belongs(_ document: EditorDocument) -> Bool {
            let path = DebugSession.canonicalSourcePath(document.url.path)
            return path.hasPrefix(directory == "/" ? "/" : directory + "/")
        }
        for document in dirtyDocuments where belongs(document) { save(document) }
        return !dirtyDocuments.contains(where: belongs)
    }

    public func saveAll() {
        for document in dirtyDocuments { save(document) }
    }

    /// Removes the tab. The caller decides what to do about unsaved edits first (`document.isDirty`).
    public func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        if serves(document) { languageServer.didClose(url: document.url) }
        documents.remove(at: index)
        if secondaryID == document.id { secondaryID = nil }
        recovery.discard(for: document.url)
        if activeID == document.id {
            activeID = documents.indices.contains(index) ? documents[index].id : documents.last?.id
        }
    }

    // MARK: File operations

    public enum FileOperationError: Error, LocalizedError {
        case exists(String), invalidName, failed(String)
        public var errorDescription: String? {
            switch self {
            case .exists(let name): "\(name) already exists."
            case .invalidName: "Use a name without slashes."
            case .failed(let reason): reason
            }
        }
    }

    private func validated(_ name: String, in directory: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { throw FileOperationError.invalidName }
        let target = directory.appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileOperationError.exists(trimmed) }
        return target
    }

    @discardableResult
    public func createFile(named name: String, in directory: URL) throws -> URL {
        let target = try validated(name, in: directory)
        guard FileManager.default.createFile(atPath: target.path, contents: Data()) else {
            throw FileOperationError.failed("Could not create \(target.lastPathComponent).")
        }
        open(target)
        return target
    }

    @discardableResult
    public func createFolder(named name: String, in directory: URL) throws -> URL {
        let target = try validated(name, in: directory)
        do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        catch { throw FileOperationError.failed(error.localizedDescription) }
        return target
    }

    /// Renames a file or folder. Open tabs for it must be saved first; they are reopened under the new name.
    @discardableResult
    public func rename(_ url: URL, to name: String) throws -> URL {
        let target = try validated(name, in: url.deletingLastPathComponent())
        let affected = documents.filter { $0.url == url || $0.url.path.hasPrefix(url.path + "/") }
        guard !affected.contains(where: \.isDirty) else { throw FileOperationError.failed("Save or discard your changes in the open files first.") }
        do { try FileManager.default.moveItem(at: url, to: target) } catch { throw FileOperationError.failed(error.localizedDescription) }
        let wasActive = affected.contains { $0.id == activeID }
        for document in affected { close(document) }
        if wasActive, url.hasDirectoryPath == false { open(target) }
        return target
    }

    /// Moves to the Trash (recoverable). Open tabs for it are closed; unsaved edits in them are dropped.
    public func trash(_ url: URL) throws {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { throw FileOperationError.failed(error.localizedDescription) }
        for document in documents where document.url == url || document.url.path.hasPrefix(url.path + "/") { close(document) }
    }

    // MARK: Safety nets

    /// Starts checking open files for outside changes and keeping recovery copies of unsaved work.
    public func startWatching(interval: TimeInterval = 2) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.tick()
            }
        }
    }

    public func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func tick() {
        for document in documents { document.checkForExternalChange() }
        writeRecovery()
    }

    public func writeRecovery() {
        for document in documents where document.isDirty {
            recovery.store(document.text, for: document.url)
        }
    }
}

/// Keeps unsaved text on disk so quitting or crashing with edits does not lose them. The copy is offered back the
/// next time that file is opened, and only if the file on disk still matches what the edits were based on.
public final class EditorRecoveryStore: @unchecked Sendable {
    private struct Entry: Codable { var path: String; var text: String; var baseHash: String }
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kiln/EditorRecovery", isDirectory: true)
    }

    private func file(for url: URL) -> URL {
        directory.appendingPathComponent(KeychainService.fingerprint(of: url.path) + ".json")
    }

    func store(_ text: String, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let entry = Entry(path: url.path, text: text, baseHash: KeychainService.fingerprint(of: base))
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file(for: url), options: .atomic) }
    }

    func recovered(for url: URL, currentDiskText: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(for: url)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.path == url.path,
              entry.baseHash == KeychainService.fingerprint(of: currentDiskText) else { return nil }
        return entry.text
    }

    /// Files with saved-but-unrestored work whose disk content still matches what the edits were based on.
    func pendingURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> URL? in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  let disk = try? String(contentsOfFile: entry.path, encoding: .utf8),
                  entry.baseHash == KeychainService.fingerprint(of: disk) else { return nil }
            return URL(fileURLWithPath: entry.path)
        }.sorted { $0.path < $1.path }
    }

    func discardAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    func discard(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file(for: url))
    }
}
