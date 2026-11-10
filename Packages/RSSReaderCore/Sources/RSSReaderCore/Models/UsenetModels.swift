import Foundation

// MARK: - Server configuration

public struct UsenetServerConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var username: String?
    public var maxConnections: Int
    public var isEnabled: Bool
    public var addedAt: Date
    public var lastConnectedAt: Date?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 563,
        useTLS: Bool = true,
        username: String? = nil,
        maxConnections: Int = 4,
        isEnabled: Bool = true,
        addedAt: Date = .now,
        lastConnectedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.maxConnections = maxConnections
        self.isEnabled = isEnabled
        self.addedAt = addedAt
        self.lastConnectedAt = lastConnectedAt
        self.lastError = lastError
    }

    public var credentialKey: String { "usenet.\(id.uuidString)" }
}

// MARK: - Group

public struct UsenetGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var serverID: UUID
    public var name: String
    public var groupDescription: String
    public var articleCount: Int
    public var lowWater: Int
    public var highWater: Int
    public var isSubscribed: Bool
    public var lastArticleNumber: Int?
    public var unreadCount: Int
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        serverID: UUID,
        name: String,
        groupDescription: String = "",
        articleCount: Int = 0,
        lowWater: Int = 0,
        highWater: Int = 0,
        isSubscribed: Bool = false,
        lastArticleNumber: Int? = nil,
        unreadCount: Int = 0,
        sortIndex: Int = 0
    ) {
        self.serverID = serverID
        self.id = id
        self.name = name
        self.groupDescription = groupDescription
        self.articleCount = articleCount
        self.lowWater = lowWater
        self.highWater = highWater
        self.isSubscribed = isSubscribed
        self.lastArticleNumber = lastArticleNumber
        self.unreadCount = unreadCount
        self.sortIndex = sortIndex
    }

    /// Newsgroup hierarchy prefix (`comp`, `sci`, `alt`, …).
    public var hierarchy: String {
        name.split(separator: ".").first.map(String.init) ?? name
    }
}

// MARK: - Article

public struct UsenetArticle: Identifiable, Codable, Hashable, Sendable {
    public var id: String { messageID }

    public var serverID: UUID
    public var groupName: String
    public var number: Int
    public var messageID: String
    public var subject: String
    public var author: String
    public var date: Date
    public var references: [String]
    public var body: String
    public var headers: [String: String]
    public var isRead: Bool
    public var isStarred: Bool
    public var fetchedAt: Date

    public init(
        serverID: UUID,
        groupName: String,
        number: Int,
        messageID: String,
        subject: String,
        author: String,
        date: Date,
        references: [String] = [],
        body: String = "",
        headers: [String: String] = [:],
        isRead: Bool = false,
        isStarred: Bool = false,
        fetchedAt: Date = .now
    ) {
        self.serverID = serverID
        self.groupName = groupName
        self.number = number
        self.messageID = messageID
        self.subject = subject
        self.author = author
        self.date = date
        self.references = references
        self.body = body
        self.headers = headers
        self.isRead = isRead
        self.isStarred = isStarred
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Wire-level values

public struct NNTPGroupInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var articleCount: Int
    public var lowWater: Int
    public var highWater: Int
    public var status: String

    public init(name: String, articleCount: Int, lowWater: Int, highWater: Int, status: String = "y") {
        self.name = name
        self.articleCount = articleCount
        self.lowWater = lowWater
        self.highWater = highWater
        self.status = status
    }
}

public struct NNTPOverviewEntry: Hashable, Sendable {
    public var number: Int
    public var subject: String
    public var author: String
    public var date: Date
    public var messageID: String
    public var references: [String]
    public var byteCount: Int
    public var lineCount: Int

    public init(
        number: Int,
        subject: String,
        author: String,
        date: Date,
        messageID: String,
        references: [String] = [],
        byteCount: Int = 0,
        lineCount: Int = 0
    ) {
        self.number = number
        self.subject = subject
        self.author = author
        self.date = date
        self.messageID = messageID
        self.references = references
        self.byteCount = byteCount
        self.lineCount = lineCount
    }
}
