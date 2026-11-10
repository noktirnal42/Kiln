import Foundation

public enum FeedParserError: Error, LocalizedError, Sendable {
    case invalidFeed(String)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .invalidFeed(let detail):
            "The feed could not be parsed: \(detail)"
        case .unsupportedFormat:
            "The document is not a recognised RSS, Atom, RDF or JSON feed."
        }
    }
}

/// Parses RSS 2.0, Atom 1.0, RSS 1.0 (RDF) and JSON Feed 1.1.
public enum FeedParser {
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> ParsedFeed {
        guard !data.isEmpty else {
            throw FeedParserError.invalidFeed("The response was empty.")
        }

        if isJSON(data) {
            return try JSONFeedParser.parse(data: data, sourceURL: sourceURL)
        }

        let delegate = XMLFeedParserDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "Malformed XML."
            throw FeedParserError.invalidFeed(detail)
        }
        return try delegate.makeFeed()
    }

    private static func isJSON(_ data: Data) -> Bool {
        for byte in data.prefix(64) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF:
                continue
            case UInt8(ascii: "{"):
                return true
            default:
                return false
            }
        }
        return false
    }
}

// MARK: - XML delegate

private final class XMLFeedParserDelegate: NSObject, XMLParserDelegate {
    private struct Channel {
        var title = ""
        var link: URL?
        var summary = ""
        var icon: URL?
        var language: String?
    }

    private struct Item {
        var guid: String?
        var title = ""
        var link: URL?
        var author: String?
        var published: Date?
        var updated: Date?
        var summary = ""
        var content = ""
        var enclosures: [Enclosure] = []
        var categories: [String] = []
    }

    private let sourceURL: URL?
    private var channel = Channel()
    private var items: [Item] = []
    private var current: Item?

    private var elementNames: [String] = []
    private var rawNames: [String] = []
    private var textStack: [String] = []
    private var sawAtom = false
    private var sawRDF = false

    init(sourceURL: URL?) {
        self.sourceURL = sourceURL
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let raw = (qName?.isEmpty == false ? qName : elementName) ?? elementName
        let local = Self.localName(raw)
        rawNames.append(raw)
        elementNames.append(local)
        textStack.append("")

        switch local {
        case "feed":
            sawAtom = true
        case "rdf":
            sawRDF = true
        case "item", "entry":
            current = Item()
        case "enclosure":
            addEnclosure(from: attributeDict)
        case "link":
            handleLink(attributeDict)
        case "content" where raw.contains(":"):
            // media:content and friends
            if attributeDict["medium"] != nil || attributeDict["type"] != nil {
                addEnclosure(from: attributeDict)
            }
        case "thumbnail", "media":
            if let urlString = attributeDict["url"], let url = resolve(urlString) {
                if current == nil, channel.icon == nil {
                    channel.icon = url
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            appendText(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = elementNames.popLast() ?? Self.localName(elementName)
        _ = rawNames.popLast()
        let value = textStack.popLast()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !textStack.isEmpty {
            textStack[textStack.count - 1] += value
        }

        let parsedDate = FeedDateParser.parse(value)
        let isInAuthor = elementNames.contains("author") || elementNames.contains("creator")

        switch local {
        case "item", "entry":
            if let item = current {
                items.append(item)
                current = nil
            }

        case "title":
            if current != nil {
                if current?.title.isEmpty == true { current?.title = value }
            } else if channel.title.isEmpty {
                channel.title = value
            }

        case "link":
            // Text-form links (RSS). Attribute-form links are handled at start.
            if !value.isEmpty {
                if current != nil, current?.link == nil {
                    current?.link = resolve(value)
                } else if current == nil, channel.link == nil {
                    channel.link = resolve(value)
                }
            }

        case "guid", "id":
            if var item = current, item.guid == nil, !value.isEmpty {
                item.guid = value
                current = item
            }

        case "description":
            if current != nil {
                if current?.summary.isEmpty == true { current?.summary = value }
            } else if channel.summary.isEmpty {
                channel.summary = value
            }

        case "summary":
            if current != nil, current?.summary.isEmpty == true {
                current?.summary = value
            }

        case "content", "encoded":
            if current != nil, current?.content.isEmpty == true {
                current?.content = value
            }

        case "pubdate", "published", "issued", "created", "date":
            if current != nil, current?.published == nil, let parsedDate {
                current?.published = parsedDate
            }

        case "updated", "modified":
            if current != nil, current?.updated == nil, let parsedDate {
                current?.updated = parsedDate
            }

        case "author":
            if current != nil, current?.author == nil, !value.isEmpty {
                current?.author = value
            }

        case "creator":
            if current != nil, !value.isEmpty, current?.author == nil {
                current?.author = value
            }

        case "name":
            if current != nil, isInAuthor, !value.isEmpty, current?.author == nil {
                current?.author = value
            }

        case "category":
            if var item = current {
                let term = value
                if !term.isEmpty, !item.categories.contains(term) {
                    item.categories.append(term)
                    current = item
                }
            }

        case "url":
            if current == nil, elementNames.contains("image"), channel.icon == nil {
                channel.icon = resolve(value)
            }

        case "icon", "logo":
            if current == nil, channel.icon == nil, !value.isEmpty {
                channel.icon = resolve(value)
            }

        case "language":
            if current == nil, channel.language == nil, !value.isEmpty {
                channel.language = value
            }

        default:
            break
        }
    }

    // MARK: Result

    func makeFeed() throws -> ParsedFeed {
        guard sawAtom || sawRDF || !items.isEmpty || !channel.title.isEmpty || !channel.summary.isEmpty else {
            throw FeedParserError.unsupportedFormat
        }
        guard !items.isEmpty || !channel.title.isEmpty else {
            throw FeedParserError.invalidFeed("No channel metadata or items were found.")
        }

        let siteURL = channel.link
        let format: FeedFormat = sawAtom ? .atom : (sawRDF ? .rdf : .rss)

        let parsedItems = items.map { item -> ParsedItem in
            let published = item.published ?? item.updated ?? .now
            let content = item.content.isEmpty ? item.summary : item.content
            let summary = item.summary.isEmpty ? item.content : item.summary

            var title = item.title
            if title.isEmpty {
                let text = HTMLUtilities.plainText(fromHTML: content)
                title = text.isEmpty ? "Untitled" : String(text.prefix(90))
            }

            let guid = item.guid
                ?? item.link?.absoluteString
                ?? StableIdentifier.hash("\(title)|\(published.timeIntervalSince1970)|\(item.author ?? "")")

            return ParsedItem(
                guid: guid,
                title: title,
                link: item.link,
                author: item.author?.isEmpty == false ? item.author : nil,
                publishedAt: published,
                updatedAt: item.updated,
                summaryHTML: summary,
                contentHTML: content,
                enclosures: item.enclosures,
                categories: item.categories
            )
        }

        let title = channel.title.isEmpty ? (siteURL?.host() ?? "Untitled Feed") : channel.title
        return ParsedFeed(
            title: title,
            siteURL: siteURL,
            summary: channel.summary.isEmpty ? nil : channel.summary,
            iconURL: channel.icon,
            format: format,
            items: parsedItems
        )
    }

    // MARK: Helpers

    private func appendText(_ string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += string
    }

    private func addEnclosure(from attributes: [String: String]) {
        guard let item = current,
              let urlString = attributes["url"] ?? attributes["href"],
              let url = resolve(urlString) else { return }
        let mime = attributes["type"] ?? attributes["medium"]
        let length = attributes["length"].flatMap(Int.init)
            ?? attributes["fileSize"].flatMap(Int.init)
        let duration = attributes["duration"].flatMap { Double($0) }
        current?.enclosures.append(
            Enclosure(url: url, mimeType: mime, byteLength: length, duration: duration)
        )
        _ = item
    }

    private func handleLink(_ attributes: [String: String]) {
        guard let href = attributes["href"],
              let url = resolve(href) else { return }

        let rel = (attributes["rel"] ?? "alternate").lowercased()
        let type = attributes["type"]?.lowercased()

        if rel == "enclosure" || (type?.hasPrefix("audio/") == true || type?.hasPrefix("video/") == true) {
            if current != nil {
                current?.enclosures.append(
                    Enclosure(
                        url: url,
                        mimeType: attributes["type"],
                        byteLength: attributes["length"].flatMap(Int.init)
                    )
                )
            }
            return
        }

        guard rel == "alternate" || attributes["rel"] == nil else { return }

        if current != nil {
            if current?.link == nil, type?.contains("html") != false || type == nil {
                current?.link = url
            }
        } else if channel.link == nil {
            channel.link = url
        }
    }

    private func resolve(_ string: String) -> URL? {
        let trimmed = HTMLUtilities.decodeHTMLEntities(
            string.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if let sourceURL {
            return URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL
        }
        return URL(string: trimmed)
    }

    private static func localName(_ raw: String) -> String {
        let local = raw.split(separator: ":").last.map(String.init) ?? raw
        return local.lowercased()
    }
}
