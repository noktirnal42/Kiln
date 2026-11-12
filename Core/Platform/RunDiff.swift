import Foundation

/// What one agent run changed, read back from its checkpoint: the file as it was before the first edit against the file now.
/// Pure data and functions; the thread's diff card and the tests both use it.
public struct RunFileDiff: Identifiable, Equatable, Sendable {
    public enum Change: String, Sendable { case added, modified, deleted }
    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable { case context, added, removed, gap }
        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
    }
    public var id: String { path }
    public var path: String
    public var change: Change
    public var additions: Int
    public var deletions: Int
    public var lines: [Line]
    /// Not shown line by line (binary or very large).
    public var summaryOnly: Bool
    /// False when someone changed the file after the run, so reverting would overwrite their work.
    public var canRevert: Bool
}

public enum UnifiedDiff {
    /// Changed lines with `context` unchanged lines around each change; distant stretches collapse into a `gap` line.
    public static func lines(old: [String], new: [String], context: Int = 3, limit: Int = 400) -> [RunFileDiff.Line] {
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var merged: [RunFileDiff.Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                merged.append(.init(kind: .removed, text: old[i], oldNumber: i + 1, newNumber: nil)); i += 1
            } else if j < new.count, inserted.contains(j) {
                merged.append(.init(kind: .added, text: new[j], oldNumber: nil, newNumber: j + 1)); j += 1
            } else if i < old.count, j < new.count {
                merged.append(.init(kind: .context, text: new[j], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            } else { break }
        }
        var keep = [Bool](repeating: false, count: merged.count)
        for (index, line) in merged.enumerated() where line.kind != .context {
            for k in max(0, index - context)...min(merged.count - 1, index + context) { keep[k] = true }
        }
        var result: [RunFileDiff.Line] = []
        var skipping = false
        for (index, line) in merged.enumerated() {
            if keep[index] { skipping = false; result.append(line) }
            else if !skipping { skipping = true; if !result.isEmpty { result.append(.init(kind: .gap, text: "⋯", oldNumber: nil, newNumber: nil)) } }
        }
        if let last = result.last, last.kind == .gap { result.removeLast() }
        return Array(result.prefix(limit))
    }
}

public enum RunDiff {
    static let maxBytes = 400_000

    /// One entry per file whose contents now differ from before the run. Files edited and then put back drop out.
    public static func files(manifest: CheckpointManifest, store: CheckpointStore, workspaceRoot: URL) -> [RunFileDiff] {
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        return manifest.files.compactMap { entry in
            let url = root.appendingPathComponent(entry.path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return nil }
            let before: Data? = entry.existed ? entry.blob.flatMap { try? Data(contentsOf: store.blobURL(manifest.id, $0)) } : nil
            let after: Data? = try? Data(contentsOf: url)
            if before == nil, entry.existed { return nil }                // the saved copy is gone: nothing honest to show
            if before == nil, after == nil { return nil }                 // created and deleted again
            if let before, let after, before == after { return nil }
            let change: RunFileDiff.Change = before == nil ? .added : (after == nil ? .deleted : .modified)
            let canRevert = CheckpointStore.hash(of: url) == entry.afterHash
            func text(_ data: Data?) -> [String]? {
                guard let data else { return [] }
                guard data.count <= maxBytes, !data.contains(0), let string = String(data: data, encoding: .utf8) else { return nil }
                var parts = string.components(separatedBy: "\n")
                if parts.last == "" { parts.removeLast() }
                return parts
            }
            guard let old = text(before), let new = text(after) else {
                return RunFileDiff(path: entry.path, change: change, additions: 0, deletions: 0, lines: [], summaryOnly: true, canRevert: canRevert)
            }
            let lines = UnifiedDiff.lines(old: old, new: new)
            return RunFileDiff(path: entry.path, change: change,
                            additions: lines.filter { $0.kind == .added }.count, deletions: lines.filter { $0.kind == .removed }.count,
                            lines: lines, summaryOnly: false, canRevert: canRevert)
        }
    }
}

extension CheckpointStore {
    /// Puts one file back as it was before the run: restores the saved copy, or moves a file the run created to the Trash.
    /// Refuses when the file changed since the run (that is someone else's work) or sits outside the project.
    public func revert(file path: String, in manifest: CheckpointManifest, workspaceRoot: URL) -> String {
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let entry = manifest.files.first(where: { $0.path == path }) else { return "\(path) is not part of this run." }
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return "\(path) is outside this project." }
        if Self.hash(of: target) != entry.afterHash {
            return "\(path) changed after the run, so it was left alone."
        }
        if entry.existed, let blob = entry.blob {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: blobURL(manifest.id, blob)).write(to: target, options: .atomic)
                return "Restored \(path)."
            } catch { return "Could not restore \(path): \(error.localizedDescription)" }
        }
        guard FileManager.default.fileExists(atPath: target.path) else { return "\(path) is already gone." }
        do { try FileManager.default.trashItem(at: target, resultingItemURL: nil); return "Moved \(path) to the Trash." }
        catch { return "Could not remove \(path): \(error.localizedDescription)" }
    }
}
