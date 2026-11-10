import Foundation

/// Checkpoints: before the agent changes a file in the workspace, the file's previous contents are saved, grouped by the
/// message that started the run. Rewinding restores those files and removes files the agent created, newest run first.
///
/// What it cannot do, said plainly in every report: undo what a shell command did (`run_command`, `git_commit`, installs,
/// network calls), restore anything outside the workspace folder (those writes are never touched), or bring back
/// changes made by someone else between the run and the rewind (those are overwritten only if the agent had changed
/// the same file; the rewind says which files it skipped).
public struct CheckpointManifest: Codable, Equatable, Identifiable, Sendable {
    public struct FileEntry: Codable, Equatable, Sendable {
        public var path: String          // relative to the workspace
        public var existed: Bool
        public var blob: String?         // file name in the checkpoint's blobs folder
        /// Hash of the file as the agent left it, so a rewind can tell if someone changed it afterwards.
        public var afterHash: String?
    }
    public var id: UUID
    public var conversationID: UUID
    /// The user message the run answered; rewinding to that message undoes this checkpoint.
    public var messageID: UUID
    public var workspace: String
    public var createdAt: Date
    public var files: [FileEntry] = []
    /// Tool calls whose effects cannot be restored, with what they were.
    public var unrestorable: [String] = []
    public var rewound = false
    public var isEmpty: Bool { files.isEmpty && unrestorable.isEmpty }
}

public struct RewindReport: Equatable, Sendable {
    public var restored: [String] = []
    public var deleted: [String] = []
    /// Files not touched, with the reason (changed since the run, outside the workspace, unreadable).
    public var skipped: [String] = []
    public var unrestorable: [String] = []
    public var checkpoints = 0

    public var summary: String {
        var parts: [String] = []
        parts.append("Restored \(restored.count) file\(restored.count == 1 ? "" : "s")")
        if !deleted.isEmpty { parts.append("removed \(deleted.count) the agent created") }
        if !skipped.isEmpty { parts.append("left \(skipped.count) alone (\(skipped.prefix(3).joined(separator: "; "))\(skipped.count > 3 ? "…" : ""))") }
        var text = parts.joined(separator: ", ") + "."
        if !unrestorable.isEmpty {
            text += " Not undone: \(unrestorable.count) command\(unrestorable.count == 1 ? "" : "s") whose effects can't be restored (\(unrestorable.prefix(3).joined(separator: "; "))\(unrestorable.count > 3 ? "…" : ""))."
        }
        return text
    }
}

public final class CheckpointStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    public static var `default`: CheckpointStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CheckpointStore(directory: base.appendingPathComponent("Kiln/Checkpoints", isDirectory: true))
    }

    func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func save(_ manifest: CheckpointManifest) {
        lock.lock(); defer { lock.unlock() }
        let url = folder(manifest.id)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) { try? data.write(to: url.appendingPathComponent("manifest.json"), options: .atomic) }
    }

    public func all(conversationID: UUID? = nil) -> [CheckpointManifest] {
        lock.lock(); defer { lock.unlock() }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? JSONDecoder().decode(CheckpointManifest.self, from: Data(contentsOf: $0.appendingPathComponent("manifest.json"))) }
            .filter { conversationID == nil || $0.conversationID == conversationID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder(id))
    }

    func blobURL(_ id: UUID, _ name: String) -> URL { folder(id).appendingPathComponent("blobs/\(name)") }

    /// Rewinds every checkpoint of the conversation from `messageID`'s onward, newest first. Pass the id of the user message
    /// that started the earliest run to undo; checkpoints of earlier messages stay.
    public func rewind(conversationID: UUID, messages orderedMessageIDs: [UUID], from messageID: UUID, workspaceRoot: URL) -> RewindReport {
        var report = RewindReport()
        guard let start = orderedMessageIDs.firstIndex(of: messageID) else { return report }
        let affected = Set(orderedMessageIDs[start...])
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        for manifest in all(conversationID: conversationID).reversed() where affected.contains(manifest.messageID) && !manifest.rewound {
            report.checkpoints += 1
            report.unrestorable += manifest.unrestorable
            for entry in manifest.files.reversed() {
                let target = root.appendingPathComponent(entry.path).standardizedFileURL
                guard target.path.hasPrefix(root.path + "/"), manifest.workspace == workspaceRoot.path || manifest.workspace == root.path else {
                    report.skipped.append("\(entry.path): outside this project"); continue
                }
                if let expected = entry.afterHash, let now = Self.hash(of: target), now != expected {
                    report.skipped.append("\(entry.path): changed since the run")
                    continue
                }
                if entry.afterHash != nil, Self.hash(of: target) == nil, !entry.existed { continue }   // already gone
                if entry.existed, let blob = entry.blob {
                    do {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(contentsOf: blobURL(manifest.id, blob)).write(to: target, options: .atomic)
                        report.restored.append(entry.path)
                    } catch { report.skipped.append("\(entry.path): \(error.localizedDescription)") }
                } else if FileManager.default.fileExists(atPath: target.path) {
                    do { try FileManager.default.trashItem(at: target, resultingItemURL: nil); report.deleted.append(entry.path) }
                    catch { report.skipped.append("\(entry.path): \(error.localizedDescription)") }
                }
            }
            var done = manifest; done.rewound = true; save(done)
        }
        return report
    }

    static func hash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var h: UInt64 = 1469598103934665603
        for byte in data { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return String(h, radix: 16) + "-\(data.count)"
    }
}

/// Records one run's file changes into a checkpoint. The orchestrator calls `beforeTool` ahead of every tool call and
/// `afterTool` once it has run.
public final class CheckpointRecorder: @unchecked Sendable {
    private let store: CheckpointStore
    private let root: URL
    private let lock = NSLock()
    private var manifest: CheckpointManifest
    private var pending: [String: URL] = [:]
    static let fileTools: Set<String> = ["write_file", "edit_file", "delete_file"]
    static let commandTools: Set<String> = ["run_command", "stream_command", "background_command", "git_commit", "git_branch"]

    public init(store: CheckpointStore, conversationID: UUID, messageID: UUID, workspaceRoot: URL) {
        self.store = store
        self.root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.manifest = CheckpointManifest(id: UUID(), conversationID: conversationID, messageID: messageID,
                                           workspace: workspaceRoot.path, createdAt: Date())
    }

    public var checkpointID: UUID { lock.withLock { manifest.id } }
    public var changedFiles: [String] { lock.withLock { manifest.files.map(\.path) } }
    public var isEmpty: Bool { lock.withLock { manifest.isEmpty } }

    private func resolve(_ path: String) -> URL? {
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        return resolved.path.hasPrefix(root.path + "/") ? resolved : nil
    }

    public func beforeTool(name: String, argumentsJSON: String, callID: String) {
        if Self.commandTools.contains(name) {
            let args = ToolArgs.object(from: argumentsJSON) ?? [:]
            let what = (args["command"] as? String) ?? (args["message"] as? String) ?? (args["name"] as? String) ?? ""
            lock.withLock { manifest.unrestorable.append("\(name) \(String(what.prefix(80)))".trimmingCharacters(in: .whitespaces)) }
            persist()
            return
        }
        guard Self.fileTools.contains(name),
              let path = (ToolArgs.object(from: argumentsJSON) ?? [:])["path"] as? String,
              let url = resolve(path) else { return }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        lock.lock()
        defer { lock.unlock() }
        pending[callID] = url
        guard !manifest.files.contains(where: { $0.path == relative }) else { return }
        var entry = CheckpointManifest.FileEntry(path: relative, existed: false, blob: nil, afterHash: nil)
        if let data = try? Data(contentsOf: url) {
            let blob = "\(manifest.files.count)-\(UUID().uuidString.prefix(8))"
            try? FileManager.default.createDirectory(at: store.folder(manifest.id).appendingPathComponent("blobs"), withIntermediateDirectories: true)
            if (try? data.write(to: store.blobURL(manifest.id, blob))) != nil { entry.existed = true; entry.blob = blob }
        }
        manifest.files.append(entry)
        persistLocked()
    }

    /// Records what the file looks like after the call, so a later rewind can tell if someone else changed it since.
    public func afterTool(callID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let url = pending.removeValue(forKey: callID) else { return }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        if let index = manifest.files.firstIndex(where: { $0.path == relative }) {
            manifest.files[index].afterHash = CheckpointStore.hash(of: url) ?? manifest.files[index].afterHash
            persistLocked()
        }
    }

    private func persist() { lock.lock(); persistLocked(); lock.unlock() }
    private func persistLocked() { store.save(manifest) }

    /// Call when the run ends. A run that changed nothing leaves no checkpoint behind.
    public func finish() -> CheckpointManifest? {
        lock.lock(); defer { lock.unlock() }
        if manifest.isEmpty { store.delete(manifest.id); return nil }
        store.save(manifest)
        return manifest
    }
}
