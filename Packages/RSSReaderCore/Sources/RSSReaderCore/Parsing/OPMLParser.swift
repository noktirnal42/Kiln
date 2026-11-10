import Foundation

public struct OPMLFeed: Identifiable, Codable, Hashable, Sendable {
    public var title: String
    public var xmlURL: URL
    public var htmlURL: URL?
    public var category: String?

    public var id: String { xmlURL.absoluteString }

    public init(title: String, xmlURL: URL, htmlURL: URL? = nil, category: String? = nil) {
        self.title = title
        self.xmlURL = xmlURL
        self.htmlURL = htmlURL
        self.category = category
    }
}

public enum OPMLParser {
    public static func parse(data: Data) throws -> [OPMLFeed] {
        let delegate = OPMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw FeedParserError.invalidFeed(
                parser.parserError?.localizedDescription ?? "Malformed OPML."
            )
        }
        return delegate.feeds
    }

    public static func export(feeds: [OPMLFeed], title: String = "RSS Reader Subscriptions") throws -> Data {
        var grouped: [String: [OPMLFeed]] = [:]
        var uncategorised: [OPMLFeed] = []
        for feed in feeds {
            if let category = feed.category, !category.isEmpty {
                grouped[category, default: []].append(feed)
            } else {
                uncategorised.append(feed)
            }
        }

        func outline(_ feed: OPMLFeed, indent: String) -> String {
            var attributes = "text=\"\(escape(feed.title))\" title=\"\(escape(feed.title))\" type=\"rss\" xmlUrl=\"\(escape(feed.xmlURL.absoluteString))\""
            if let htmlURL = feed.htmlURL {
                attributes += " htmlUrl=\"\(escape(htmlURL.absoluteString))\""
            }
            return "\(indent)<outline \(attributes)/>"
        }

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\">")
        lines.append("  <head>")
        lines.append("    <title>\(escape(title))</title>")
        lines.append("    <dateCreated>\(RFC822Date.string(from: .now))</dateCreated>")
        lines.append("  </head>")
        lines.append("  <body>")
        for feed in uncategorised.sorted(by: { $0.title < $1.title }) {
            lines.append(outline(feed, indent: "    "))
        }
        for category in grouped.keys.sorted() {
            lines.append("    <outline text=\"\(escape(category))\" title=\"\(escape(category))\">")
            for feed in grouped[category, default: []].sorted(by: { $0.title < $1.title }) {
                lines.append(outline(feed, indent: "      "))
            }
            lines.append("    </outline>")
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func escape(_ string: String) -> String {
        HTMLUtilities.escapeHTML(string)
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    var feeds: [OPMLFeed] = []
    private var categoryStack: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        let xmlURLString = attributeDict.first { $0.key.lowercased() == "xmlurl" }?.value
        let htmlURLString = attributeDict.first { $0.key.lowercased() == "htmlurl" }?.value
        let title = attributeDict["title"]
            ?? attributeDict["text"]
            ?? xmlURLString
            ?? "Untitled"

        if let xmlURLString,
           let url = URL(string: xmlURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            feeds.append(
                OPMLFeed(
                    title: title,
                    xmlURL: url,
                    htmlURL: htmlURLString.flatMap { URL(string: $0) },
                    category: categoryStack.last
                )
            )
        } else {
            categoryStack.append(title)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "outline" else { return }
        // Nested category outlines are popped when their element closes.
        if !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
    }
}

enum RFC822Date {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
