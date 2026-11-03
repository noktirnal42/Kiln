import Foundation

/// Editor preferences, kept in UserDefaults and applied live to every open editor.
@MainActor @Observable
public final class EditorSettings {
    public static let shared = EditorSettings()

    public var fontSize: Double { didSet { defaults.set(fontSize, forKey: "editor.fontSize") } }
    public var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: "editor.tabWidth") } }
    public var insertSpaces: Bool { didSet { defaults.set(insertSpaces, forKey: "editor.insertSpaces") } }
    public var softWrap: Bool { didSet { defaults.set(softWrap, forKey: "editor.softWrap") } }
    public var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: "editor.lineNumbers") } }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let size = defaults.double(forKey: "editor.fontSize")
        fontSize = size == 0 ? 13 : min(max(size, 9), 32)
        let width = defaults.integer(forKey: "editor.tabWidth")
        tabWidth = [2, 3, 4, 8].contains(width) ? width : 4
        insertSpaces = defaults.object(forKey: "editor.insertSpaces") as? Bool ?? true
        softWrap = defaults.object(forKey: "editor.softWrap") as? Bool ?? false
        showLineNumbers = defaults.object(forKey: "editor.lineNumbers") as? Bool ?? true
    }

    /// What Tab inserts.
    public var indentUnit: String { insertSpaces ? String(repeating: " ", count: tabWidth) : "\t" }
}

/// Finds the bracket that pairs with the one at `index` (or just before it), ignoring nothing but nesting.
public enum BracketMatcher {
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// UTF-16 offsets of the bracket the caret touches and its partner, or nil.
    public static func match(in text: String, caret: Int) -> (NSRange, NSRange)? {
        let units = Array(text.utf16)
        func char(_ offset: Int) -> Character? {
            guard offset >= 0, offset < units.count, let scalar = Unicode.Scalar(units[offset]) else { return nil }
            return Character(scalar)
        }
        for offset in [caret - 1, caret] {
            guard let c = char(offset) else { continue }
            if let close = pairs[c] {
                var depth = 0
                var i = offset
                while i < units.count {
                    if let d = char(i) {
                        if d == c { depth += 1 } else if d == close { depth -= 1; if depth == 0 { return (NSRange(location: offset, length: 1), NSRange(location: i, length: 1)) } }
                    }
                    i += 1
                }
            } else if let open = closers[c] {
                var depth = 0
                var i = offset
                while i >= 0 {
                    if let d = char(i) {
                        if d == c { depth += 1 } else if d == open { depth -= 1; if depth == 0 { return (NSRange(location: offset, length: 1), NSRange(location: i, length: 1)) } }
                    }
                    i -= 1
                }
            }
        }
        return nil
    }
}
