import Foundation

// MARK: - Feed format

/// Wire format detected for a subscription.
public enum FeedFormat: String, Codable, Sendable, CaseIterable {
    case rss
    case atom
    case rdf
    case json
    case unknown

    public var displayName: String {
        switch self {
        case .rss: "RSS 2.0"
        case .atom: "Atom"
        case .rdf: "RSS 1.0 / RDF"
        case .json: "JSON Feed"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - Category

public struct FeedCategory: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#6E8BFF",
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
    }
}

// MARK: - Feed

public struct Feed: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var siteURL: URL?
    public var summary: String?
    public var iconURL: URL?
    public var format: FeedFormat
    public var categoryID: UUID?
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var addedAt: Date
    public var lastRefreshedAt: Date?
    public var lastError: String?
    public var etag: String?
    public var lastModified: String?
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        siteURL: URL? = nil,
        summary: String? = nil,
        iconURL: URL? = nil,
        format: FeedFormat = .unknown,
        categoryID: UUID? = nil,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        addedAt: Date = .now,
        lastRefreshedAt: Date? = nil,
        lastError: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.siteURL = siteURL
        self.summary = summary
        self.iconURL = iconURL
        self.format = format
        self.categoryID = categoryID
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.addedAt = addedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.lastError = lastError
        self.etag = etag
        self.lastModified = lastModified
        self.sortIndex = sortIndex
    }

    public var host: String {
        url.host() ?? url.absoluteString
    }
}

// MARK: - Enclosure

public struct Enclosure: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public var url: URL
    public var mimeType: String?
    public var byteLength: Int?
    public var duration: TimeInterval?

    public init(
        url: URL,
        mimeType: String? = nil,
        byteLength: Int? = nil,
        duration: TimeInterval? = nil
    ) {
        self.url = url
        self.mimeType = mimeType
        self.byteLength = byteLength
        self.duration = duration
    }

    public var isAudio: Bool {
        mimeType?.hasPrefix("audio/") == true || ["mp3", "m4a", "aac", "ogg", "flac"]
            .contains(url.pathExtension.lowercased())
    }

    public var isVideo: Bool {
        mimeType?.hasPrefix("video/") == true || ["mp4", "m4v", "mov", "webm"]
            .contains(url.pathExtension.lowercased())
    }

    public var isImage: Bool {
        mimeType?.hasPrefix("image/") == true || ["jpg", "jpeg", "png", "gif", "webp", "avif"]
            .contains(url.pathExtension.lowercased())
    }
}

// MARK: - Article

public struct Article: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var feedID: UUID
    public var guid: String
    public var title: String
    public var link: URL?
    public var author: String?
    public var publishedAt: Date
    public var updatedAt: Date?
    public var summary: String
    public var contentHTML: String
    public var enclosures: [Enclosure]
    public var isRead: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var fetchedAt: Date

    public init(
        id: UUID = UUID(),
        feedID: UUID,
        guid: String,
        title: String,
        link: URL? = nil,
        author: String? = nil,
        publishedAt: Date = .now,
        updatedAt: Date? = nil,
        summary: String = "",
        contentHTML: String = "",
        enclosures: [Enclosure] = [],
        isRead: Bool = false,
        isStarred: Bool = false,
        isArchived: Bool = false,
        fetchedAt: Date = .now
    ) {
        self.id = id
        self.feedID = feedID
        self.guid = guid
        self.title = title
        self.link = link
        self.author = author
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.contentHTML = contentHTML
        self.enclosures = enclosures
        self.isRead = isRead
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.fetchedAt = fetchedAt
    }

    /// Plain-text body used by the search index and previews.
    public var plainText: String {
        HTMLUtilities.plainText(fromHTML: contentHTML.isEmpty ? summary : contentHTML)
    }

    public var readingMinutes: Int {
        let words = plainText.split { $0.isWhitespace }.count
        return max(1, Int((Double(words) / 220.0).rounded(.up)))
    }

    public var displaySummary: String {
        let text = HTMLUtilities.plainText(
            fromHTML: summary.isEmpty ? contentHTML : summary
        )
        return String(text.prefix(360))
    }
}

// MARK: - Filters

public enum ArticleFilter: Hashable, Codable, Sendable {
    case all
    case unread
    case starred
    case today
    case feed(UUID)
    case category(UUID)

    public var displayName: String {
        switch self {
        case .all: "All Articles"
        case .unread: "Unread"
        case .starred: "Starred"
        case .today: "Today"
        case .feed: "Feed"
        case .category: "Category"
        }
    }
}

// MARK: - Search

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var article: Article
    public var snippet: String

    public var id: UUID { article.id }

    public init(article: Article, snippet: String) {
        self.article = article
        self.snippet = snippet
    }
}

// MARK: - Library stats

public struct LibraryStatistics: Hashable, Sendable {
    public var feedCount: Int
    public var articleCount: Int
    public var unreadCount: Int
    public var starredCount: Int
    public var databaseBytes: Int64

    public init(
        feedCount: Int = 0,
        articleCount: Int = 0,
        unreadCount: Int = 0,
        starredCount: Int = 0,
        databaseBytes: Int64 = 0
    ) {
        self.feedCount = feedCount
        self.articleCount = articleCount
        self.unreadCount = unreadCount
        self.starredCount = starredCount
        self.databaseBytes = databaseBytes
    }
}

// MARK: - Parsed feed (pre-persistence)

public struct ParsedItem: Identifiable, Codable, Hashable, Sendable {
    public var guid: String?
    public var title: String
    public var link: URL?
    public var author: String?
    public var publishedAt: Date?
    public var updatedAt: Date?
    public var summaryHTML: String
    public var contentHTML: String
    public var enclosures: [Enclosure]
    public var categories: [String]

    public var id: String {
        guid ?? link?.absoluteString ?? title
    }

    public init(
        guid: String? = nil,
        title: String = "",
        link: URL? = nil,
        author: String? = nil,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil,
        summaryHTML: String = "",
        contentHTML: String = "",
        enclosures: [Enclosure] = [],
        categories: [String] = []
    ) {
        self.guid = guid
        self.title = title
        self.link = link
        self.author = author
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.summaryHTML = summaryHTML
        self.contentHTML = contentHTML
        self.enclosures = enclosures
        self.categories = categories
    }
}

public struct ParsedFeed: Codable, Hashable, Sendable {
    public var title: String
    public var siteURL: URL?
    public var summary: String?
    public var iconURL: URL?
    public var format: FeedFormat
    public var items: [ParsedItem]

    public init(
        title: String,
        siteURL: URL? = nil,
        summary: String? = nil,
        iconURL: URL? = nil,
        format: FeedFormat = .unknown,
        items: [ParsedItem] = []
    ) {
        self.title = title
        self.siteURL = siteURL
        self.summary = summary
        self.iconURL = iconURL
        self.format = format
        self.items = items
    }
}

// MARK: - Stable identifiers

public enum StableIdentifier {
    /// FNV-1a, stable across launches (unlike `hashValue`).
    public static func hash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
