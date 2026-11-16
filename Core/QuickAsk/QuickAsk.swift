import Foundation

/// A question or a piece of shared content on its way into Kiln's message box.
public struct QuickAskRequest: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Typed by the person into Kiln's own menu-bar field.
        case menuBar
        /// A `kiln://ask` link, which any web page or app can open.
        case link
        /// Text or a link handed over by the Share menu.
        case share
    }

    public var text: String
    public var source: Source

    public init(text: String, source: Source) { self.text = text; self.source = source }

    /// Only the menu-bar field, where the person typed the words themselves, may send at once. A link or a share can come from a web
    /// page or another app, so it only fills the message box and the person decides.
    public var maySendAtOnce: Bool { source == .menuBar }
}

public enum QuickAskLink {
    public static let scheme = "kiln"
    public static let maxCharacters = 8_000

    /// `kiln://ask?text=…` and `kiln://share?title=…&url=…&text=…`. Nothing else is accepted.
    public static func parse(_ url: URL) -> QuickAskRequest? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String { sanitize(items.first { $0.name == name }?.value ?? "") }
        switch host {
        case "ask":
            let text = value("text")
            return text.isEmpty ? nil : QuickAskRequest(text: text, source: .link)
        case "share":
            let combined = combine(title: value("title"), url: value("url"), text: value("text"))
            return combined.isEmpty ? nil : QuickAskRequest(text: combined, source: .share)
        default:
            return nil
        }
    }

    /// Title, then a web address, then the text, each only when present. A shared address must be http or https; anything else is dropped.
    public static func combine(title: String, url: String, text: String) -> String {
        var lines: [String] = []
        if !title.isEmpty { lines.append(title) }
        if let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased() ?? ""), address.host != nil { lines.append(address.absoluteString) }
        if !text.isEmpty { lines.append(lines.isEmpty ? text : "\n" + text) }
        return clip(lines.joined(separator: "\n"))
    }

    /// Control characters other than line breaks and tabs are removed, line endings are normalised, and the text is trimmed and clipped.
    public static func sanitize(_ raw: String) -> String {
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = normalised.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            let category = scalar.properties.generalCategory
            return category != .control && category != .format
        }
        return clip(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func clip(_ text: String) -> String { text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text }

    /// What goes in the message box: added after what the person is already typing, never over it.
    public static func merge(existing: String, adding: String) -> String {
        let current = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? adding : existing.trimmingCharacters(in: .newlines) + "\n\n" + adding
    }

    public static func askLink(_ text: String) -> URL? {
        var components = URLComponents(); components.scheme = scheme; components.host = "ask"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    public static func shareLink(title: String, url: String, text: String) -> URL? {
        var components = URLComponents(); components.scheme = scheme; components.host = "share"
        components.queryItems = [("title", title), ("url", url), ("text", text)].filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }
}
