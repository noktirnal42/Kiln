import Foundation

/// A file the assistant named in its reply (a code span like `Sources/App/Pagination.swift:42`) that exists in the project.
public struct FileMention: Identifiable, Equatable, Sendable {
    public var path: String      // as written, relative to the project root or absolute
    public var line: Int?
    public var id: String { path + ":" + String(line ?? 0) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Asks the window to show a file in the editor (the chat cannot reach the workstation shell directly).
public struct FileOpenRequest: Equatable, Sendable {
    public var id = UUID()
    public var path: String
    public var line: Int?
}

public enum FileMentions {
    /// Code spans in `text` that name an existing file under `root`, in order of first mention, at most `limit`. Fenced code is ignored.
    public static func extract(from text: String, root: String?, limit: Int = 6,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [FileMention] {
        guard let root, !root.isEmpty else { return [] }
        var inFence = false
        var found: [FileMention] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            for span in codeSpans(in: String(line)) {
                guard let mention = parse(span) else { continue }
                let full = mention.path.hasPrefix("/") ? mention.path : (root as NSString).appendingPathComponent(mention.path)
                var isDirectory: ObjCBool = false
                guard exists(full), !(FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) && isDirectory.boolValue) else { continue }
                if !found.contains(where: { $0.path == mention.path }) { found.append(mention) }
                if found.count >= limit { return found }
            }
        }
        return found
    }

    static func codeSpans(in line: String) -> [String] {
        var spans: [String] = []
        var current: String?
        for character in line {
            if character == "`" {
                if let span = current { if !span.isEmpty { spans.append(span) }; current = nil } else { current = "" }
            } else if current != nil { current?.append(character) }
        }
        return spans
    }

    /// `path/to/file.ext`, `file.ext:42` or `file.ext:42:7`. A span needs an extension and no spaces to count as a file.
    static func parse(_ span: String) -> FileMention? {
        guard !span.contains(" "), !span.contains("://") else { return nil }
        var path = span
        var line: Int?
        let parts = span.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let number = Int(parts[1]), number > 0 {
            path = String(parts[0]); line = number
        } else if parts.count > 1 { return nil }
        let ext = (path as NSString).pathExtension
        guard !path.isEmpty, (1...8).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return FileMention(path: path, line: line)
    }
}
