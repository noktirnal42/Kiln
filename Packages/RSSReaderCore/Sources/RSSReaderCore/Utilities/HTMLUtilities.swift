import Foundation

/// Lightweight HTML utilities: text extraction, sanitisation and URL resolution.
/// Deliberately dependency-free so it behaves identically on macOS and iOS.
public enum HTMLUtilities {

    // MARK: - Plain text

    public static func plainText(fromHTML html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html

        text = replacing(
            pattern: "(?is)<(script|style|noscript|template|svg|head)\\b[^>]*>.*?</\\1\\s*>",
            in: text,
            with: " "
        )
        text = text.replacingOccurrences(
            of: "(?i)<(br|hr)\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?i)</(p|div|section|article|li|ul|ol|h[1-6]|blockquote|pre|tr|table|figure|figcaption|header|footer)\\s*>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?i)<td[^>]*>",
            with: " ",
            options: .regularExpression
        )
        text = replacing(pattern: "(?s)<[^>]+>", in: text, with: " ")
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")

        // Collapse horizontal whitespace but preserve paragraph breaks.
        text = text.replacingOccurrences(
            of: "[\\t\\x{000B}\\x{000C}\\r ]+",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: " *\\n *",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": " ", "emsp": " ", "thinsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "middot": "·",
        "bull": "•", "prime": "′", "Prime": "″", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "sbquo": "‚", "bdquo": "„", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "times": "×", "divide": "÷", "ne": "≠", "le": "≤", "ge": "≥",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
        "para": "¶", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "lsaquo": "‹", "rsaquo": "›", "oline": "‾", "frasl": "⁄",
        "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á",
        "iacute": "í", "oacute": "ó", "uacute": "ú", "yacute": "ý",
        "ccedil": "ç", "ntilde": "ñ", "uuml": "ü", "ouml": "ö",
        "auml": "ä", "euml": "ë", "iuml": "ï", "szlig": "ß",
        "oslash": "ø", "aring": "å", "aelig": "æ", "oelig": "œ",
        "Eacute": "É", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "pi": "π",
        "mu": "μ", "sigma": "σ", "omega": "ω", "infin": "∞", "sum": "∑",
        "radic": "√", "asymp": "≈", "equiv": "≡", "loz": "◊"
    ]

    public static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        result.reserveCapacity(string.count)
        var index = string.startIndex

        while index < string.endIndex {
            guard string[index] == "&",
                  let semicolon = string[index...].firstIndex(of: ";"),
                  string.distance(from: index, to: semicolon) <= 12 else {
                result.append(string[index])
                index = string.index(after: index)
                continue
            }

            let entity = String(string[string.index(after: index)..<semicolon])
            if let scalar = decodeEntity(entity) {
                result.append(scalar)
                index = string.index(after: semicolon)
            } else {
                result.append(string[index])
                index = string.index(after: index)
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            let hex = String(entity.dropFirst(2))
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }
        if entity.hasPrefix("#") {
            let decimal = String(entity.dropFirst())
            guard let value = UInt32(decimal), let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }
        return namedEntities[entity]
    }

    public static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Sanitisation

    /// Removes active content and resolves relative links against `baseURL`.
    public static func sanitize(_ html: String, baseURL: URL? = nil) -> String {
        guard !html.isEmpty else { return "" }
        var output = html

        // Drop elements that can execute or capture.
        let dangerous = ["script", "style", "iframe", "object", "embed", "form",
                         "noscript", "template", "svg", "math", "link", "meta"]
        for tag in dangerous {
            output = replacing(
                pattern: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                in: output,
                with: ""
            )
            output = replacing(
                pattern: "(?is)<\(tag)\\b[^>]*/?>",
                in: output,
                with: ""
            )
        }

        // Inline event handlers.
        output = replacing(
            pattern: "(?is)\\s+on[a-z]+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            in: output,
            with: ""
        )

        // Dangerous URLs.
        output = replacing(
            pattern: "(?is)(href|src|xlink:href)\\s*=\\s*([\"'])\\s*(?:javascript|vbscript|data:text/html)[^\"']*\\2",
            in: output,
            with: "href=\"#\""
        )

        if let baseURL {
            output = resolveRelativeURLs(in: output, baseURL: baseURL)
        }

        return output
    }

    private static func resolveRelativeURLs(in html: String, baseURL: URL) -> String {
        let pattern = "(?is)(href|src)\\s*=\\s*([\"'])([^\"']*)\\2"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let attribute = ns.substring(with: match.range(at: 1))
            let quote = ns.substring(with: match.range(at: 2))
            let raw = ns.substring(with: match.range(at: 3))

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix("//"),
                  !trimmed.lowercased().hasPrefix("mailto:"),
                  !trimmed.contains("://"),
                  !trimmed.lowercased().hasPrefix("data:") else { continue }

            guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
                continue
            }
            let replacement = "\(attribute)=\(quote)\(resolved.absoluteString)\(quote)"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func replacing(pattern: String, in string: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return string }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    /// Very small excerpt used in search results.
    public static func excerpt(from html: String, limit: Int = 220) -> String {
        let text = plainText(fromHTML: html)
            .replacingOccurrences(of: "\n", with: " ")
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
