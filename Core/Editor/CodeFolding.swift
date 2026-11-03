import Foundation

/// A foldable block. Lines are 0-based; folding hides lines `startLine + 1 ... lastHiddenLine` and keeps the start line.
public struct FoldRegion: Equatable, Sendable {
    public let startLine: Int
    public let lastHiddenLine: Int
}

/// Finds foldable blocks and the character ranges folding hides. Pure, so it is tested without a view.
public enum CodeFolding {
    /// Brace blocks (the closing-brace line stays visible, as in Xcode) or, for Python/YAML, indentation blocks.
    public static func regions(in text: String, indentationBased: Bool) -> [FoldRegion] {
        indentationBased ? indentationRegions(in: text) : braceRegions(in: text)
    }

    static func braceRegions(in text: String) -> [FoldRegion] {
        var stack: [Int] = []
        var best: [Int: Int] = [:]   // start line -> closing line (the outermost wins)
        var line = 0
        var inLineComment = false, inBlockComment = false
        var quote: Character?
        var previous: Character = "\n"
        for ch in text {
            if ch == "\n" {
                line += 1; inLineComment = false
                if quote != nil, quote != "`" { quote = nil }
                previous = ch; continue
            }
            if inLineComment { previous = ch; continue }
            if inBlockComment {
                if previous == "*", ch == "/" { inBlockComment = false; previous = "\n"; continue }
                previous = ch; continue
            }
            if let open = quote {
                if ch == open, previous != "\\" { quote = nil; previous = "\n"; continue }
                previous = (previous == "\\" && ch == "\\") ? "\n" : ch; continue
            }
            switch ch {
            case "/" where previous == "/": inLineComment = true
            case "*" where previous == "/": inBlockComment = true
            case "\"", "'", "`": quote = ch
            case "{": stack.append(line)
            case "}":
                if let start = stack.popLast(), line - start >= 2 { best[start] = max(best[start] ?? 0, line) }
            default: break
            }
            previous = ch
        }
        return best.map { FoldRegion(startLine: $0.key, lastHiddenLine: $0.value - 1) }.sorted { $0.startLine < $1.startLine }
    }

    static func indentationRegions(in text: String) -> [FoldRegion] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func indent(_ s: Substring) -> Int? {
            guard s.contains(where: { !$0.isWhitespace }) else { return nil }
            return s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
        var regions: [FoldRegion] = []
        for i in lines.indices {
            guard let base = indent(lines[i]) else { continue }
            var last: Int?
            var j = i + 1
            while j < lines.count {
                if let next = indent(lines[j]) {
                    if next <= base { break }
                    last = j
                }
                j += 1
            }
            if let last, last > i { regions.append(FoldRegion(startLine: i, lastHiddenLine: last)) }
        }
        return regions
    }

    /// The character ranges folded away: from the first hidden line's start through the newline ending the last hidden line.
    /// The view blanks the glyphs in them (keeping the newlines so lines still break) and collapses each wholly-hidden line.
    /// Nested folds are merged.
    public static func hiddenRanges(in text: NSString, folded: [FoldRegion]) -> [NSRange] {
        var starts: [Int] = [0]   // character offset of each line start
        var index = 0
        while index < text.length {
            if text.character(at: index) == 10 { starts.append(index + 1) }
            index += 1
        }
        func lineEnd(_ line: Int) -> Int { line + 1 < starts.count ? starts[line + 1] - 1 : text.length }
        var ranges: [NSRange] = []
        for region in folded.sorted(by: { $0.startLine < $1.startLine }) {
            guard region.startLine >= 0, region.lastHiddenLine > region.startLine, region.lastHiddenLine < starts.count else { continue }
            guard region.startLine + 1 < starts.count else { continue }
            let from = starts[region.startLine + 1], to = min(text.length, lineEnd(region.lastHiddenLine) + 1)
            guard to > from else { continue }
            if let last = ranges.last, from <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), to) - last.location)
            } else {
                ranges.append(NSRange(location: from, length: to - from))
            }
        }
        return ranges
    }

    /// The innermost region that contains the line (as its start or a hidden line), for ⌘⌥[.
    public static func innermost(containing line: Int, in regions: [FoldRegion]) -> FoldRegion? {
        regions.filter { $0.startLine <= line && line <= $0.lastHiddenLine }.max { $0.startLine < $1.startLine }
    }
}
