import Foundation

public struct DiscoveredFeed: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public var title: String
    public var url: URL
    public var format: FeedFormat

    public init(title: String, url: URL, format: FeedFormat = .unknown) {
        self.title = title
        self.url = url
        self.format = format
    }
}

/// Finds feed links in HTML without a full HTML parser.
public enum FeedDiscovery {
    private static let feedMIMETypes = [
        "application/rss+xml",
        "application/atom+xml",
        "application/feed+json",
        "application/json",
        "application/xml",
        "text/xml"
    ]

    public static func links(inHTML html: String, baseURL: URL) -> [DiscoveredFeed] {
        guard !html.isEmpty else { return [] }
        var results: [DiscoveredFeed] = []
        var seen = Set<String>()

        let pattern = "(?is)<link\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            let tag = ns.substring(with: match.range)
            let attributes = attributes(from: tag)
            guard let href = attributes["href"] else { continue }
            let rel = (attributes["rel"] ?? "").lowercased()
            let type = (attributes["type"] ?? "").lowercased()
            let title = attributes["title"] ?? ""

            let isAlternate = rel.split(separator: " ").contains("alternate")
            guard isAlternate, feedMIMETypes.contains(where: { type.contains($0) }) else { continue }

            guard let url = resolve(href, base: baseURL) else { continue }
            guard !seen.contains(url.absoluteString) else { continue }
            seen.insert(url.absoluteString)

            let format: FeedFormat
            if type.contains("atom") {
                format = .atom
            } else if type.contains("json") {
                format = .json
            } else {
                format = .rss
            }

            let resolvedTitle: String
            if !title.isEmpty {
                resolvedTitle = title
            } else if let host = url.host() {
                resolvedTitle = host
            } else {
                resolvedTitle = "Discovered Feed"
            }

            results.append(DiscoveredFeed(title: resolvedTitle, url: url, format: format))
        }
        return results
    }

    private static func attributes(from tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 2 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            if match.range(at: 3).location != NSNotFound {
                result[key] = ns.substring(with: match.range(at: 3))
            } else if match.range(at: 4).location != NSNotFound {
                result[key] = ns.substring(with: match.range(at: 4))
            }
        }
        return result
    }

    private static func resolve(_ href: String, base: URL) -> URL? {
        let trimmed = HTMLUtilities.decodeHTMLEntities(
            href.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}
