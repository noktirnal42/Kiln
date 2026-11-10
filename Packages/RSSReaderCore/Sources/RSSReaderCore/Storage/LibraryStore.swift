import Foundation

/// SQLite-backed library: feeds, articles, FTS5 search and Usenet cache.
/// All access is serialised through the actor.
public actor LibraryStore {
    private let db: SQLiteDatabase
    private let databasePath: String

    // MARK: - Init

    public init(path: String) throws {
        let database = try SQLiteDatabase(path: path)
        try database.execute(Self.schema)
        if database.userVersion < 1 {
            database.userVersion = 1
        }
        self.db = database
        self.databasePath = path
    }

    public static func inMemory() throws -> LibraryStore {
        try LibraryStore(path: ":memory:")
    }

    public static func defaultDatabaseURL() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("ModernReader", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.sqlite")
    }

    // MARK: - Schema

    private static let schema = """
    CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color_hex TEXT NOT NULL DEFAULT '#6E8BFF',
        sort_index INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS feeds (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        url TEXT NOT NULL UNIQUE,
        site_url TEXT,
        summary TEXT,
        icon_url TEXT,
        format TEXT NOT NULL DEFAULT 'unknown',
        category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        is_built_in INTEGER NOT NULL DEFAULT 0,
        added_at REAL NOT NULL,
        last_refreshed_at REAL,
        last_error TEXT,
        etag TEXT,
        last_modified TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_feeds_category ON feeds(category_id);

    CREATE TABLE IF NOT EXISTS articles (
        id TEXT PRIMARY KEY,
        feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
        guid TEXT NOT NULL,
        title TEXT NOT NULL,
        link TEXT,
        author TEXT,
        published_at REAL NOT NULL,
        updated_at REAL,
        summary TEXT NOT NULL DEFAULT '',
        content_html TEXT NOT NULL DEFAULT '',
        body_text TEXT NOT NULL DEFAULT '',
        enclosures_json TEXT NOT NULL DEFAULT '[]',
        is_read INTEGER NOT NULL DEFAULT 0,
        is_starred INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL,
        UNIQUE(feed_id, guid)
    );
    CREATE INDEX IF NOT EXISTS idx_articles_feed_date ON articles(feed_id, published_at DESC);
    CREATE INDEX IF NOT EXISTS idx_articles_unread ON articles(is_read, published_at DESC);
    CREATE INDEX IF NOT EXISTS idx_articles_starred ON articles(is_starred, published_at DESC);

    CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
        article_id UNINDEXED,
        title,
        body,
        tokenize = 'unicode61 remove_diacritics 2'
    );

    CREATE TABLE IF NOT EXISTS usenet_servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL,
        use_tls INTEGER NOT NULL DEFAULT 1,
        username TEXT,
        max_connections INTEGER NOT NULL DEFAULT 4,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        added_at REAL NOT NULL,
        last_connected_at REAL,
        last_error TEXT
    );

    CREATE TABLE IF NOT EXISTS usenet_groups (
        id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL REFERENCES usenet_servers(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        group_description TEXT NOT NULL DEFAULT '',
        article_count INTEGER NOT NULL DEFAULT 0,
        low_water INTEGER NOT NULL DEFAULT 0,
        high_water INTEGER NOT NULL DEFAULT 0,
        is_subscribed INTEGER NOT NULL DEFAULT 1,
        last_article_number INTEGER,
        unread_count INTEGER NOT NULL DEFAULT 0,
        sort_index INTEGER NOT NULL DEFAULT 0,
        UNIQUE(server_id, name)
    );
    CREATE INDEX IF NOT EXISTS idx_usenet_groups_server ON usenet_groups(server_id);

    CREATE TABLE IF NOT EXISTS usenet_articles (
        message_id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL,
        group_name TEXT NOT NULL,
        number INTEGER NOT NULL DEFAULT 0,
        subject TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        date REAL NOT NULL,
        references_text TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        headers_json TEXT NOT NULL DEFAULT '{}',
        is_read INTEGER NOT NULL DEFAULT 0,
        is_starred INTEGER NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_usenet_articles_group
        ON usenet_articles(server_id, group_name, date DESC);
    """

    // MARK: - Column lists

    private static let feedColumns = """
    id, title, url, site_url, summary, icon_url, format, category_id,
    is_enabled, is_built_in, added_at, last_refreshed_at, last_error,
    etag, last_modified, sort_index
    """

    private static let articleColumns = """
    a.id, a.feed_id, a.guid, a.title, a.link, a.author, a.published_at,
    a.updated_at, a.summary, a.content_html, a.enclosures_json,
    a.is_read, a.is_starred, a.is_archived, a.fetched_at
    """

    private static let serverColumns = """
    id, name, host, port, use_tls, username, max_connections, is_enabled,
    added_at, last_connected_at, last_error
    """

    private static let groupColumns = """
    id, server_id, name, group_description, article_count, low_water,
    high_water, is_subscribed, last_article_number, unread_count, sort_index
    """

    // MARK: - Categories

    @discardableResult
    public func saveCategory(_ category: FeedCategory) throws -> FeedCategory {
        let statement = try db.prepare("""
        INSERT INTO categories (id, name, color_hex, sort_index)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            color_hex = excluded.color_hex,
            sort_index = excluded.sort_index
        """)
        try statement.bind([
            .text(category.id.uuidString),
            .text(category.name),
            .text(category.colorHex),
            .int(category.sortIndex)
        ])
        try statement.run()
        return category
    }

    public func categories() throws -> [FeedCategory] {
        let statement = try db.prepare("SELECT id, name, color_hex, sort_index FROM categories ORDER BY sort_index, name")
        var result: [FeedCategory] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.columnText(0) ?? "") else { continue }
            result.append(
                FeedCategory(
                    id: id,
                    name: statement.columnText(1) ?? "Category",
                    colorHex: statement.columnText(2) ?? "#6E8BFF",
                    sortIndex: statement.columnInt(3)
                )
            )
        }
        return result
    }

    public func deleteCategory(id: UUID) throws {
        let statement = try db.prepare("DELETE FROM categories WHERE id = ?")
        try statement.bind([.text(id.uuidString)])
        try statement.run()
    }

    // MARK: - Feeds

    @discardableResult
    public func saveFeed(_ feed: Feed) throws -> Feed {
        let statement = try db.prepare("""
        INSERT INTO feeds (\(Self.feedColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            url = excluded.url,
            site_url = excluded.site_url,
            summary = excluded.summary,
            icon_url = excluded.icon_url,
            format = excluded.format,
            category_id = excluded.category_id,
            is_enabled = excluded.is_enabled,
            is_built_in = excluded.is_built_in,
            last_refreshed_at = excluded.last_refreshed_at,
            last_error = excluded.last_error,
            etag = excluded.etag,
            last_modified = excluded.last_modified,
            sort_index = excluded.sort_index
        """)
        try statement.bind(feedValues(feed))
        try statement.run()
        return feed
    }

    public func saveFeeds(_ feeds: [Feed]) throws {
        try db.transaction {
            for feed in feeds {
                let statement = try db.prepare("""
                INSERT INTO feeds (\(Self.feedColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    site_url = excluded.site_url,
                    summary = excluded.summary,
                    icon_url = excluded.icon_url,
                    format = excluded.format,
                    category_id = excluded.category_id
                """)
                try statement.bind(feedValues(feed))
                try statement.run()
            }
        }
    }

    public func feeds() throws -> [Feed] {
        let statement = try db.prepare("SELECT \(Self.feedColumns) FROM feeds ORDER BY sort_index, title COLLATE NOCASE")
        var result: [Feed] = []
        while try statement.step() {
            if let feed = decodeFeed(statement) { result.append(feed) }
        }
        return result
    }

    public func feed(id: UUID) throws -> Feed? {
        let statement = try db.prepare("SELECT \(Self.feedColumns) FROM feeds WHERE id = ?")
        try statement.bind([.text(id.uuidString)])
        guard try statement.step() else { return nil }
        return decodeFeed(statement)
    }

    public func feed(url: URL) throws -> Feed? {
        let statement = try db.prepare("SELECT \(Self.feedColumns) FROM feeds WHERE url = ?")
        try statement.bind([.text(url.absoluteString)])
        guard try statement.step() else { return nil }
        return decodeFeed(statement)
    }

    public func deleteFeed(id: UUID) throws {
        try db.transaction {
            let fts = try db.prepare("DELETE FROM articles_fts WHERE article_id IN (SELECT id FROM articles WHERE feed_id = ?)")
            try fts.bind([.text(id.uuidString)])
            try fts.run()

            let delete = try db.prepare("DELETE FROM feeds WHERE id = ?")
            try delete.bind([.text(id.uuidString)])
            try delete.run()
        }
    }

    // MARK: - Articles

    /// Inserts new articles and refreshes existing ones while preserving read/star state.
    /// Returns the number of newly inserted articles.
    @discardableResult
    public func upsertArticles(_ articles: [Article]) throws -> Int {
        guard !articles.isEmpty else { return 0 }
        var inserted = 0

        try db.transaction {
            let find = try db.prepare("SELECT id FROM articles WHERE feed_id = ? AND guid = ?")
            let insert = try db.prepare("""
            INSERT INTO articles (
                id, feed_id, guid, title, link, author, published_at, updated_at,
                summary, content_html, body_text, enclosures_json,
                is_read, is_starred, is_archived, fetched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            let update = try db.prepare("""
            UPDATE articles SET
                title = ?, link = ?, author = ?, published_at = ?, updated_at = ?,
                summary = ?, content_html = ?, body_text = ?, enclosures_json = ?,
                fetched_at = ?
            WHERE feed_id = ? AND guid = ?
            """)
            let deleteFTS = try db.prepare("DELETE FROM articles_fts WHERE article_id = ?")
            let insertFTS = try db.prepare("INSERT INTO articles_fts (article_id, title, body) VALUES (?, ?, ?)")

            for article in articles {
                let bodyText = article.plainText
                let enclosuresJSON = encodeEnclosures(article.enclosures)

                try find.bind([.text(article.feedID.uuidString), .text(article.guid)])
                let found = try find.step()
                let existingID: String? = found ? find.columnText(0) : nil

                let resolvedID: String
                if let existingID {
                    try update.bind([
                        .text(article.title),
                        .text(article.link?.absoluteString ?? ""),
                        .text(article.author ?? ""),
                        .double(article.publishedAt.timeIntervalSince1970),
                        article.updatedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .text(article.summary),
                        .text(article.contentHTML),
                        .text(bodyText),
                        .text(enclosuresJSON),
                        .double(article.fetchedAt.timeIntervalSince1970),
                        .text(article.feedID.uuidString),
                        .text(article.guid)
                    ])
                    try update.run()
                    resolvedID = existingID
                } else {
                    try insert.bind([
                        .text(article.id.uuidString),
                        .text(article.feedID.uuidString),
                        .text(article.guid),
                        .text(article.title),
                        .text(article.link?.absoluteString ?? ""),
                        .text(article.author ?? ""),
                        .double(article.publishedAt.timeIntervalSince1970),
                        article.updatedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .text(article.summary),
                        .text(article.contentHTML),
                        .text(bodyText),
                        .text(enclosuresJSON),
                        .int(article.isRead ? 1 : 0),
                        .int(article.isStarred ? 1 : 0),
                        .int(article.isArchived ? 1 : 0),
                        .double(article.fetchedAt.timeIntervalSince1970)
                    ])
                    try insert.run()
                    resolvedID = article.id.uuidString
                    inserted += 1
                }

                try deleteFTS.bind([.text(resolvedID)])
                try deleteFTS.run()
                try insertFTS.bind([
                    .text(resolvedID),
                    .text(article.title),
                    .text(bodyText)
                ])
                try insertFTS.run()
            }
        }

        return inserted
    }

    public func articles(
        filter: ArticleFilter,
        limit: Int = 300,
        offset: Int = 0
    ) throws -> [Article] {
        let (clause, values) = filterClause(filter)
        let safeLimit = max(1, min(limit, 2_000))
        let statement = try db.prepare("""
        SELECT \(Self.articleColumns)
        FROM articles a
        WHERE \(clause)
        ORDER BY a.published_at DESC, a.title COLLATE NOCASE ASC
        LIMIT ? OFFSET ?
        """)
        try statement.bind(values + [.int(safeLimit), .int(max(0, offset))])
        return try decodeArticles(statement)
    }

    public func article(id: UUID) throws -> Article? {
        let statement = try db.prepare("SELECT \(Self.articleColumns) FROM articles a WHERE a.id = ?")
        try statement.bind([.text(id.uuidString)])
        guard try statement.step() else { return nil }
        return decodeArticle(statement)
    }

    public func setRead(_ read: Bool, articleIDs: [UUID]) throws {
        try updateArticles(column: "is_read", value: read ? 1 : 0, ids: articleIDs)
    }

    public func setStarred(_ starred: Bool, articleIDs: [UUID]) throws {
        try updateArticles(column: "is_starred", value: starred ? 1 : 0, ids: articleIDs)
    }

    public func setArchived(_ archived: Bool, articleIDs: [UUID]) throws {
        try updateArticles(column: "is_archived", value: archived ? 1 : 0, ids: articleIDs)
    }

    public func markAllRead(filter: ArticleFilter) throws {
        let (clause, values) = filterClause(filter)
        let statement = try db.prepare("""
        UPDATE articles SET is_read = 1
        WHERE id IN (SELECT a.id FROM articles a WHERE \(clause))
        """)
        try statement.bind(values)
        try statement.run()
    }

    public func articleCount(filter: ArticleFilter) throws -> Int {
        let (clause, values) = filterClause(filter)
        let statement = try db.prepare("SELECT COUNT(*) FROM articles a WHERE \(clause)")
        try statement.bind(values)
        guard try statement.step() else { return 0 }
        return statement.columnInt(0)
    }

    public func unreadCounts() throws -> [UUID: Int] {
        let statement = try db.prepare("""
        SELECT feed_id, COUNT(*) FROM articles
        WHERE is_read = 0 AND is_archived = 0
        GROUP BY feed_id
        """)
        var counts: [UUID: Int] = [:]
        while try statement.step() {
            guard let id = UUID(uuidString: statement.columnText(0) ?? "") else { continue }
            counts[id] = statement.columnInt(1)
        }
        return counts
    }

    public func categoryUnreadCounts() throws -> [UUID: Int] {
        let statement = try db.prepare("""
        SELECT f.category_id, COUNT(*)
        FROM articles a JOIN feeds f ON f.id = a.feed_id
        WHERE a.is_read = 0 AND a.is_archived = 0 AND f.category_id IS NOT NULL
        GROUP BY f.category_id
        """)
        var counts: [UUID: Int] = [:]
        while try statement.step() {
            guard let id = UUID(uuidString: statement.columnText(0) ?? "") else { continue }
            counts[id] = statement.columnInt(1)
        }
        return counts
    }

    public func totalUnreadCount() throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM articles WHERE is_read = 0 AND is_archived = 0")
        guard try statement.step() else { return 0 }
        return statement.columnInt(0)
    }

    /// Removes old non-starred articles. Returns the number of removed rows.
    @discardableResult
    public func pruneArticles(olderThan date: Date) throws -> Int {
        var removed = 0
        try db.transaction {
            let before = try scalar("SELECT COUNT(*) FROM articles")
            let fts = try db.prepare("""
            DELETE FROM articles_fts WHERE article_id IN (
                SELECT id FROM articles WHERE is_starred = 0 AND published_at < ?
            )
            """)
            try fts.bind([.double(date.timeIntervalSince1970)])
            try fts.run()

            let delete = try db.prepare("DELETE FROM articles WHERE is_starred = 0 AND published_at < ?")
            try delete.bind([.double(date.timeIntervalSince1970)])
            try delete.run()

            let after = try scalar("SELECT COUNT(*) FROM articles")
            removed = max(0, before - after)
        }
        return removed
    }

    // MARK: - Search

    public func search(_ rawQuery: String, limit: Int = 100) throws -> [SearchHit] {
        guard let match = Self.ftsQuery(from: rawQuery) else { return [] }
        let statement = try db.prepare("""
        SELECT \(Self.articleColumns),
               snippet(articles_fts, -1, '⟦', '⟧', '…', 24) AS snippet
        FROM articles_fts
        JOIN articles a ON a.id = articles_fts.article_id
        WHERE articles_fts MATCH ? AND a.is_archived = 0
        ORDER BY bm25(articles_fts, 8.0, 1.0)
        LIMIT ?
        """)
        try statement.bind([.text(match), .int(max(1, min(limit, 500)))])

        var hits: [SearchHit] = []
        while try statement.step() {
            guard let article = decodeArticle(statement) else { continue }
            let snippet = statement.columnText(15) ?? article.displaySummary
            hits.append(SearchHit(article: article, snippet: snippet))
        }
        return hits
    }

    /// Builds a safe FTS5 query: every token becomes a quoted prefix term.
    static func ftsQuery(from raw: String) -> String? {
        let tokens = raw
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 || raw.count <= 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(8)
            .map { "\"\($0)\"*" }
            .joined(separator: " AND ")
    }

    // MARK: - Statistics

    public func statistics() throws -> LibraryStatistics {
        let feedCount = try scalar("SELECT COUNT(*) FROM feeds WHERE is_enabled = 1")
        let articleCount = try scalar("SELECT COUNT(*) FROM articles")
        let unread = try scalar("SELECT COUNT(*) FROM articles WHERE is_read = 0 AND is_archived = 0")
        let starred = try scalar("SELECT COUNT(*) FROM articles WHERE is_starred = 1")
        let bytes: Int64
        if databasePath == ":memory:" {
            bytes = 0
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath)
            bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return LibraryStatistics(
            feedCount: feedCount,
            articleCount: articleCount,
            unreadCount: unread,
            starredCount: starred,
            databaseBytes: bytes
        )
    }

    // MARK: - Usenet servers

    @discardableResult
    public func saveUsenetServer(_ server: UsenetServerConfig) throws -> UsenetServerConfig {
        let statement = try db.prepare("""
        INSERT INTO usenet_servers (\(Self.serverColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            host = excluded.host,
            port = excluded.port,
            use_tls = excluded.use_tls,
            username = excluded.username,
            max_connections = excluded.max_connections,
            is_enabled = excluded.is_enabled,
            last_connected_at = excluded.last_connected_at,
            last_error = excluded.last_error
        """)
        try statement.bind(serverValues(server))
        try statement.run()
        return server
    }

    public func usenetServers() throws -> [UsenetServerConfig] {
        let statement = try db.prepare("SELECT \(Self.serverColumns) FROM usenet_servers ORDER BY added_at")
        var servers: [UsenetServerConfig] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.columnText(0) ?? "") else { continue }
            servers.append(
                UsenetServerConfig(
                    id: id,
                    name: statement.columnText(1) ?? "Server",
                    host: statement.columnText(2) ?? "",
                    port: statement.columnInt(3),
                    useTLS: statement.columnInt(4) == 1,
                    username: statement.columnText(5),
                    maxConnections: statement.columnInt(6),
                    isEnabled: statement.columnInt(7) == 1,
                    addedAt: Date(timeIntervalSince1970: statement.columnDouble(8)),
                    lastConnectedAt: optionalDate(statement, 9),
                    lastError: statement.columnText(10)
                )
            )
        }
        return servers
    }

    public func deleteUsenetServer(id: UUID) throws {
        try db.transaction {
            for sql in [
                "DELETE FROM usenet_articles WHERE server_id = ?",
                "DELETE FROM usenet_groups WHERE server_id = ?",
                "DELETE FROM usenet_servers WHERE id = ?"
            ] {
                let statement = try db.prepare(sql)
                try statement.bind([.text(id.uuidString)])
                try statement.run()
            }
        }
    }

    // MARK: - Usenet groups

    public func saveUsenetGroups(_ groups: [UsenetGroup]) throws {
        guard !groups.isEmpty else { return }
        try db.transaction {
            let statement = try db.prepare("""
            INSERT INTO usenet_groups (\(Self.groupColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(server_id, name) DO UPDATE SET
                group_description = CASE
                    WHEN excluded.group_description = '' THEN usenet_groups.group_description
                    ELSE excluded.group_description END,
                article_count = excluded.article_count,
                low_water = excluded.low_water,
                high_water = excluded.high_water
            """)
            for group in groups {
                try statement.bind(groupValues(group))
                try statement.run()
            }
        }
    }

    public func usenetGroups(serverID: UUID, subscribedOnly: Bool = false) throws -> [UsenetGroup] {
        let filter = subscribedOnly ? "AND is_subscribed = 1" : ""
        let statement = try db.prepare("""
        SELECT \(Self.groupColumns) FROM usenet_groups
        WHERE server_id = ? \(filter)
        ORDER BY sort_index, name COLLATE NOCASE
        """)
        try statement.bind([.text(serverID.uuidString)])
        var groups: [UsenetGroup] = []
        while try statement.step() {
            guard let id = UUID(uuidString: statement.columnText(0) ?? ""),
                  let server = UUID(uuidString: statement.columnText(1) ?? "") else { continue }
            groups.append(
                UsenetGroup(
                    id: id,
                    serverID: server,
                    name: statement.columnText(2) ?? "",
                    groupDescription: statement.columnText(3) ?? "",
                    articleCount: statement.columnInt(4),
                    lowWater: statement.columnInt(5),
                    highWater: statement.columnInt(6),
                    isSubscribed: statement.columnInt(7) == 1,
                    lastArticleNumber: statement.columnIsNull(8) ? nil : statement.columnInt(8),
                    unreadCount: statement.columnInt(9),
                    sortIndex: statement.columnInt(10)
                )
            )
        }
        return groups
    }

    public func setGroupSubscribed(_ subscribed: Bool, groupID: UUID) throws {
        let statement = try db.prepare("UPDATE usenet_groups SET is_subscribed = ? WHERE id = ?")
        try statement.bind([.int(subscribed ? 1 : 0), .text(groupID.uuidString)])
        try statement.run()
    }

    public func updateGroupWatermarks(
        serverID: UUID,
        name: String,
        highWater: Int,
        articleCount: Int
    ) throws {
        let statement = try db.prepare("""
        UPDATE usenet_groups SET high_water = ?, article_count = ?
        WHERE server_id = ? AND name = ?
        """)
        try statement.bind([
            .int(highWater), .int(articleCount),
            .text(serverID.uuidString), .text(name)
        ])
        try statement.run()
    }

    // MARK: - Usenet articles

    @discardableResult
    public func upsertUsenetArticles(_ articles: [UsenetArticle]) throws -> Int {
        guard !articles.isEmpty else { return 0 }
        var inserted = 0
        try db.transaction {
            let exists = try db.prepare("SELECT 1 FROM usenet_articles WHERE message_id = ?")
            let insert = try db.prepare("""
            INSERT INTO usenet_articles (
                message_id, server_id, group_name, number, subject, author, date,
                references_text, body, headers_json, is_read, is_starred, fetched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            let update = try db.prepare("""
            UPDATE usenet_articles SET
                number = ?, subject = ?, author = ?, date = ?, references_text = ?,
                body = ?, headers_json = ?, fetched_at = ?
            WHERE message_id = ?
            """)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            for article in articles {
                let references = article.references.joined(separator: " ")
                let headersJSON = (try? encoder.encode(article.headers))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                try exists.bind([.text(article.messageID)])
                let isExisting = try exists.step()

                if isExisting {
                    try update.bind([
                        .int(article.number), .text(article.subject), .text(article.author),
                        .double(article.date.timeIntervalSince1970), .text(references),
                        .text(article.body), .text(headersJSON),
                        .double(article.fetchedAt.timeIntervalSince1970),
                        .text(article.messageID)
                    ])
                    try update.run()
                } else {
                    try insert.bind([
                        .text(article.messageID), .text(article.serverID.uuidString),
                        .text(article.groupName), .int(article.number),
                        .text(article.subject), .text(article.author),
                        .double(article.date.timeIntervalSince1970), .text(references),
                        .text(article.body), .text(headersJSON),
                        .int(article.isRead ? 1 : 0), .int(article.isStarred ? 1 : 0),
                        .double(article.fetchedAt.timeIntervalSince1970)
                    ])
                    try insert.run()
                    inserted += 1
                }
            }
        }
        return inserted
    }

    public func usenetArticles(
        serverID: UUID,
        group: String,
        limit: Int = 200
    ) throws -> [UsenetArticle] {
        let statement = try db.prepare("""
        SELECT message_id, server_id, group_name, number, subject, author, date,
               references_text, body, headers_json, is_read, is_starred, fetched_at
        FROM usenet_articles
        WHERE server_id = ? AND group_name = ?
        ORDER BY date DESC
        LIMIT ?
        """)
        try statement.bind([
            .text(serverID.uuidString), .text(group), .int(max(1, min(limit, 1_000)))
        ])
        return try decodeUsenetArticles(statement)
    }

    public func usenetArticle(messageID: String) throws -> UsenetArticle? {
        let statement = try db.prepare("""
        SELECT message_id, server_id, group_name, number, subject, author, date,
               references_text, body, headers_json, is_read, is_starred, fetched_at
        FROM usenet_articles WHERE message_id = ?
        """)
        try statement.bind([.text(messageID)])
        return try decodeUsenetArticles(statement).first
    }

    public func setUsenetRead(_ read: Bool, messageIDs: [String]) throws {
        try updateUsenet(column: "is_read", value: read ? 1 : 0, ids: messageIDs)
    }

    public func setUsenetStarred(_ starred: Bool, messageIDs: [String]) throws {
        try updateUsenet(column: "is_starred", value: starred ? 1 : 0, ids: messageIDs)
    }

    public func usenetUnreadCounts(serverID: UUID) throws -> [String: Int] {
        let statement = try db.prepare("""
        SELECT group_name, COUNT(*) FROM usenet_articles
        WHERE server_id = ? AND is_read = 0
        GROUP BY group_name
        """)
        try statement.bind([.text(serverID.uuidString)])
        var counts: [String: Int] = [:]
        while try statement.step() {
            guard let name = statement.columnText(0) else { continue }
            counts[name] = statement.columnInt(1)
        }
        return counts
    }

    // MARK: - Maintenance

    public func vacuum() throws {
        try db.execute("VACUUM;")
    }

    // MARK: - Bind helpers

    private func feedValues(_ feed: Feed) -> [SQLValue] {
        [
            .text(feed.id.uuidString),
            .text(feed.title),
            .text(feed.url.absoluteString),
            .text(feed.siteURL?.absoluteString ?? ""),
            .text(feed.summary ?? ""),
            .text(feed.iconURL?.absoluteString ?? ""),
            .text(feed.format.rawValue),
            feed.categoryID.map { .text($0.uuidString) } ?? .null,
            .int(feed.isEnabled ? 1 : 0),
            .int(feed.isBuiltIn ? 1 : 0),
            .double(feed.addedAt.timeIntervalSince1970),
            feed.lastRefreshedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            feed.lastError.map { .text($0) } ?? .null,
            feed.etag.map { .text($0) } ?? .null,
            feed.lastModified.map { .text($0) } ?? .null,
            .int(feed.sortIndex)
        ]
    }

    private func serverValues(_ server: UsenetServerConfig) -> [SQLValue] {
        [
            .text(server.id.uuidString),
            .text(server.name),
            .text(server.host),
            .int(server.port),
            .int(server.useTLS ? 1 : 0),
            server.username.map { .text($0) } ?? .null,
            .int(server.maxConnections),
            .int(server.isEnabled ? 1 : 0),
            .double(server.addedAt.timeIntervalSince1970),
            server.lastConnectedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            server.lastError.map { .text($0) } ?? .null
        ]
    }

    private func groupValues(_ group: UsenetGroup) -> [SQLValue] {
        [
            .text(group.id.uuidString),
            .text(group.serverID.uuidString),
            .text(group.name),
            .text(group.groupDescription),
            .int(group.articleCount),
            .int(group.lowWater),
            .int(group.highWater),
            .int(group.isSubscribed ? 1 : 0),
            group.lastArticleNumber.map { .int($0) } ?? .null,
            .int(group.unreadCount),
            .int(group.sortIndex)
        ]
    }

    // MARK: - Decode helpers

    private func decodeFeed(_ statement: Statement) -> Feed? {
        guard let id = UUID(uuidString: statement.columnText(0) ?? ""),
              let url = URL(string: statement.columnText(2) ?? "") else { return nil }

        let siteURL = statement.columnText(3).flatMap(URL.init(string:))
        let iconURL = statement.columnText(5).flatMap(URL.init(string:))
        let categoryID = statement.columnText(7).flatMap(UUID.init(uuidString:))

        return Feed(
            id: id,
            title: statement.columnText(1) ?? "Untitled Feed",
            url: url,
            siteURL: siteURL,
            summary: statement.columnText(4),
            iconURL: iconURL,
            format: FeedFormat(rawValue: statement.columnText(6) ?? "") ?? .unknown,
            categoryID: categoryID,
            isEnabled: statement.columnInt(8) == 1,
            isBuiltIn: statement.columnInt(9) == 1,
            addedAt: Date(timeIntervalSince1970: statement.columnDouble(10)),
            lastRefreshedAt: optionalDate(statement, 11),
            lastError: statement.columnText(12),
            etag: statement.columnText(13),
            lastModified: statement.columnText(14),
            sortIndex: statement.columnInt(15)
        )
    }

    private func decodeArticles(_ statement: Statement) throws -> [Article] {
        var articles: [Article] = []
        while try statement.step() {
            if let article = decodeArticle(statement) {
                articles.append(article)
            }
        }
        return articles
    }

    private func decodeArticle(_ statement: Statement) -> Article? {
        guard let id = UUID(uuidString: statement.columnText(0) ?? ""),
              let feedID = UUID(uuidString: statement.columnText(1) ?? "") else { return nil }

        let link = statement.columnText(4).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let enclosuresJSON = statement.columnText(10) ?? "[]"
        let enclosures = (try? JSONDecoder().decode([Enclosure].self, from: Data(enclosuresJSON.utf8))) ?? []

        return Article(
            id: id,
            feedID: feedID,
            guid: statement.columnText(2) ?? "",
            title: statement.columnText(3) ?? "Untitled",
            link: link,
            author: statement.columnText(5),
            publishedAt: Date(timeIntervalSince1970: statement.columnDouble(6)),
            updatedAt: optionalDate(statement, 7),
            summary: statement.columnText(8) ?? "",
            contentHTML: statement.columnText(9) ?? "",
            enclosures: enclosures,
            isRead: statement.columnInt(11) == 1,
            isStarred: statement.columnInt(12) == 1,
            isArchived: statement.columnInt(13) == 1,
            fetchedAt: Date(timeIntervalSince1970: statement.columnDouble(14))
        )
    }

    private func decodeUsenetArticles(_ statement: Statement) throws -> [UsenetArticle] {
        var articles: [UsenetArticle] = []
        let decoder = JSONDecoder()
        while try statement.step() {
            guard let serverID = UUID(uuidString: statement.columnText(1) ?? "") else { continue }
            let headersJSON = statement.columnText(9) ?? "{}"
            let headers = (try? decoder.decode([String: String].self, from: Data(headersJSON.utf8))) ?? [:]
            let references = (statement.columnText(7) ?? "")
                .split(separator: " ")
                .map(String.init)

            articles.append(
                UsenetArticle(
                    serverID: serverID,
                    groupName: statement.columnText(2) ?? "",
                    number: statement.columnInt(3),
                    messageID: statement.columnText(0) ?? "",
                    subject: statement.columnText(4) ?? "",
                    author: statement.columnText(5) ?? "",
                    date: Date(timeIntervalSince1970: statement.columnDouble(6)),
                    references: references,
                    body: statement.columnText(8) ?? "",
                    headers: headers,
                    isRead: statement.columnInt(10) == 1,
                    isStarred: statement.columnInt(11) == 1,
                    fetchedAt: Date(timeIntervalSince1970: statement.columnDouble(12))
                )
            )
        }
        return articles
    }

    private func encodeEnclosures(_ enclosures: [Enclosure]) -> String {
        guard !enclosures.isEmpty else { return "[]" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(enclosures),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private func optionalDate(_ statement: Statement, _ index: Int32) -> Date? {
        statement.columnIsNull(index)
            ? nil
            : Date(timeIntervalSince1970: statement.columnDouble(index))
    }

    private func scalar(_ sql: String) throws -> Int {
        let statement = try db.prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.columnInt(0)
    }

    // MARK: - Filters

    private func filterClause(_ filter: ArticleFilter) -> (String, [SQLValue]) {
        switch filter {
        case .all:
            return ("a.is_archived = 0", [])
        case .unread:
            return ("a.is_read = 0 AND a.is_archived = 0", [])
        case .starred:
            return ("a.is_starred = 1 AND a.is_archived = 0", [])
        case .today:
            let start = Calendar.current.startOfDay(for: .now)
            return ("a.published_at >= ? AND a.is_archived = 0", [.double(start.timeIntervalSince1970)])
        case .feed(let id):
            return ("a.feed_id = ? AND a.is_archived = 0", [.text(id.uuidString)])
        case .category(let id):
            return (
                "a.feed_id IN (SELECT id FROM feeds WHERE category_id = ?) AND a.is_archived = 0",
                [.text(id.uuidString)]
            )
        }
    }

    // MARK: - Bulk updates

    private func updateArticles(column: String, value: Int, ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let statement = try db.prepare("UPDATE articles SET \(column) = ? WHERE id = ?")
            for id in ids {
                try statement.bind([.int(value), .text(id.uuidString)])
                try statement.run()
            }
        }
    }

    private func updateUsenet(column: String, value: Int, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let statement = try db.prepare("UPDATE usenet_articles SET \(column) = ? WHERE message_id = ?")
            for id in ids {
                try statement.bind([.int(value), .text(id)])
                try statement.run()
            }
        }
    }
}
