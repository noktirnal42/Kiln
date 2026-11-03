import Foundation

/// Line-level difference between the committed version of a file and the text in the editor, for the gutter markers and
/// "revert this change".
public enum LineDiff {
    public struct Hunk: Equatable, Sendable {
        public enum Kind: Sendable { case added, modified, removed }
        public var kind: Kind
        /// Lines in the current text this hunk covers (empty range for a removal: the position it was removed from).
        public var current: Range<Int>
        /// The committed lines it replaces.
        public var base: [String]
    }

    public static func hunks(base: [String], current: [String]) -> [Hunk] {
        let changes = current.difference(from: base)
        var removedBase = Set<Int>()
        var insertedCurrent = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removedBase.insert(offset)
            case .insert(let offset, _, _): insertedCurrent.insert(offset)
            }
        }
        // Lines that survived on both sides pair up in order; what lies between consecutive pairs is a hunk.
        let keptBase = (0..<base.count).filter { !removedBase.contains($0) }
        let keptCurrent = (0..<current.count).filter { !insertedCurrent.contains($0) }
        var result: [Hunk] = []
        var baseCursor = 0
        var currentCursor = 0
        func close(baseEnd: Int, currentEnd: Int) {
            let baseLines = Array(base[baseCursor..<baseEnd])
            guard !baseLines.isEmpty || currentEnd > currentCursor else { return }
            let kind: Hunk.Kind = baseLines.isEmpty ? .added : (currentEnd == currentCursor ? .removed : .modified)
            result.append(Hunk(kind: kind, current: currentCursor..<currentEnd, base: baseLines))
        }
        for (b, c) in zip(keptBase, keptCurrent) {
            close(baseEnd: b, currentEnd: c)
            baseCursor = b + 1
            currentCursor = c + 1
        }
        close(baseEnd: base.count, currentEnd: current.count)
        return result
    }

    /// The hunk touching a 0-based line (a removal touches the line it was removed before).
    public static func hunk(at line: Int, in hunks: [Hunk]) -> Hunk? {
        hunks.first { $0.current.contains(line) || ($0.kind == .removed && $0.current.lowerBound == line) }
    }

    /// `text` with the hunk's lines put back to the committed ones.
    public static func revert(_ hunk: Hunk, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let upper = min(hunk.current.upperBound, lines.count)
        lines.replaceSubrange(min(hunk.current.lowerBound, lines.count)..<upper, with: hunk.base)
        return lines.joined(separator: "\n")
    }
}
