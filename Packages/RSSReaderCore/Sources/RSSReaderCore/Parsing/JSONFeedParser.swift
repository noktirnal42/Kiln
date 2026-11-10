import Foundation

/// JSON Feed 1.1 parser (https://www.jsonfeed.org/version/1.1/).
enum JSONFeedParser {
    static func parse(data: Data, sourceURL: URL?) throws -> ParsedFeed {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw FeedParserError.invalidFeed("Malformed JSON feed.")
        }

        let title = string(root["title"]) ?? sourceURL?.host() ?? "Untitled Feed"
        let homePage = url(root["home_page_url"], base: sourceURL)
        let feedURL = url(root["feed_url"], base: sourceURL)
        let description = string(root["description"])
        let icon = url(root["icon"] ?? root["favicon"], base: sourceURL ?? homePage)

        let rawItems = root["items"] as? [[String: Any]] ?? []
        var items: [ParsedItem] = []
        items.reserveCapacity(rawItems.count)

        for raw in rawItems {
            let itemTitle = string(raw["title"]) ?? ""
            let externalURL = url(raw["url"] ?? raw["external_url"], base: homePage ?? sourceURL)
            let contentHTML = string(raw["content_html"])
                ?? string(raw["content_text"]).map { HTMLUtilities.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>") }
                ?? ""
            let summary = string(raw["summary"]) ?? ""
            let published = FeedDateParser.parse(string(raw["date_published"]))
            let modified = FeedDateParser.parse(string(raw["date_modified"]))
            let identifier = string(raw["id"])

            var author: String?
            if let authorObject = raw["author"] as? [String: Any] {
                author = string(authorObject["name"])
            } else if let authors = raw["authors"] as? [[String: Any]] {
                author = authors.compactMap { string($0["name"]) }.joined(separator: ", ").nilIfEmpty
            }

            var enclosures: [Enclosure] = []
            if let attachments = raw["attachments"] as? [[String: Any]] {
                for attachment in attachments {
                    guard let attachmentURL = url(attachment["url"], base: homePage ?? sourceURL) else { continue }
                    enclosures.append(
                        Enclosure(
                            url: attachmentURL,
                            mimeType: string(attachment["mime_type"]),
                            byteLength: attachment["size_in_bytes"] as? Int,
                            duration: attachment["duration_in_seconds"] as? Double
                        )
                    )
                }
            }

            let tags = (raw["tags"] as? [String]) ?? []
            let guid = identifier
                ?? externalURL?.absoluteString
                ?? StableIdentifier.hash("\(itemTitle)|\(published?.timeIntervalSince1970 ?? 0)")

            let resolvedTitle = itemTitle.isEmpty
                ? String(HTMLUtilities.plainText(fromHTML: contentHTML).prefix(90))
                : itemTitle

            items.append(
                ParsedItem(
                    guid: guid,
                    title: resolvedTitle.isEmpty ? "Untitled" : resolvedTitle,
                    link: externalURL,
                    author: author,
                    publishedAt: published ?? modified ?? .now,
                    updatedAt: modified,
                    summaryHTML: summary,
                    contentHTML: contentHTML,
                    enclosures: enclosures,
                    categories: tags
                )
            )
        }

        return ParsedFeed(
            title: title,
            siteURL: homePage ?? feedURL,
            summary: description,
            iconURL: icon,
            format: .json,
            items: items
        )
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func url(_ value: Any?, base: URL?) -> URL? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if let base { return URL(string: trimmed, relativeTo: base)?.absoluteURL }
        return URL(string: trimmed)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
