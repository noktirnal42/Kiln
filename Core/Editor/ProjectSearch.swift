import Foundation

public struct ProjectHit: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var path: String
    public var line: Int
    public var column: Int
    public var text: String
}

/// Text search across a project folder, for the editor's Find in Project. It skips build output, binaries and big files.
public enum ProjectSearch {
    public static let maxFileBytes = 1_000_000

    public static func search(root: URL, query: String, caseSensitive: Bool = false, limit: Int = 300,
                              showHidden: Bool = false) -> [ProjectHit] {
        let needle = caseSensitive ? query : query.lowercased()
        guard !needle.isEmpty, let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        var hits: [ProjectHit] = []
        for case let url as URL in walker {
            if Task.isCancelled { break }
            if EditorWorkspace.ignoredNames.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            if (values?.fileSize ?? 0) > maxFileBytes { continue }
            guard let data = try? Data(contentsOf: url), !data.prefix(4096).contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var lineNumber = 0
            text.enumerateLines { line, stop in
                lineNumber += 1
                let haystack = caseSensitive ? line : line.lowercased()
                guard let range = haystack.range(of: needle) else { return }
                let column = haystack.distance(from: haystack.startIndex, to: range.lowerBound) + 1
                hits.append(ProjectHit(path: url.path, line: lineNumber, column: column,
                                      text: String(line.trimmingCharacters(in: .whitespaces).prefix(200))))
                if hits.count >= limit { stop = true }
            }
            if hits.count >= limit { break }
        }
        return hits
    }
}
