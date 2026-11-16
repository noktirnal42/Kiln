import Foundation

/// Slack writes mentions, channels and links as `<...>` markup and escapes `& < >`. This turns that into text a person (or a model)
/// can read, and spots markup that would notify many people.
public enum SlackText {
    private static let angle = try! NSRegularExpression(pattern: "<([^<>]+)>")

    public static func plain(_ raw: String, users: [String: String] = [:]) -> String {
        var out = ""
        var last = raw.startIndex
        let ns = raw as NSString
        for match in angle.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            guard let whole = Range(match.range, in: raw), let inner = Range(match.range(at: 1), in: raw) else { continue }
            out += raw[last..<whole.lowerBound]
            out += rendered(String(raw[inner]), users: users)
            last = whole.upperBound
        }
        out += raw[last...]
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func rendered(_ inner: String, users: [String: String]) -> String {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0]
        let label = parts.count > 1 ? parts[1] : nil
        if target.hasPrefix("@") {
            let id = String(target.dropFirst())
            return "@" + (label ?? users[id] ?? id)
        }
        if target.hasPrefix("#") {
            let id = String(target.dropFirst())
            return "#" + (label ?? id)
        }
        if target.hasPrefix("!") {
            let word = String(target.dropFirst())
            if let label { return label.hasPrefix("@") ? label : "@" + label }
            return "@" + (word.split(separator: "^").first.map(String.init) ?? word)
        }
        if target.hasPrefix("mailto:") { return label ?? String(target.dropFirst("mailto:".count)) }
        if target.contains("://") { return label.map { "\($0) (\(target))" } ?? target }
        return inner
    }

    /// True when the text would notify a whole channel or a user group (`<!channel>`, `<!here>`, `<!everyone>`, `<!subteam^…>`).
    public static func hasBroadcastMention(_ text: String) -> Bool {
        let ns = text as NSString
        for match in angle.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 1))
            let target = inner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? inner
            if ["!channel", "!here", "!everyone"].contains(target) || target.hasPrefix("!subteam^") { return true }
        }
        return false
    }
}
