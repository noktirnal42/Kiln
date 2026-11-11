import Foundation
import Observation
import RSSReaderCore

@MainActor @Observable final class NewsState {
    static let shared = NewsState()
    private let defaults: UserDefaults
    var sources: [String] { didSet { defaults.set(sources, forKey: "news.sources") } }
    var selected: String?
    var articles: [ParsedItem] = []
    var articleSources: [String: String] = [:]
    private var refreshGeneration = 0
    static let all = "__all__"
    var title = "News"
    var busy = false
    var message: String?
    
    // New: read/star state tracking
    var articleReadStatus: [String: Bool] = [:]  // article.id -> read
    var articleStarred: [String: Bool] = [:]   // article.id -> starred
    
    // New: read later queue (stored in UserDefaults as array of URLs)
    var readLater: [String] { didSet { defaults.set(readLater, forKey: "news.read_later") } }
    
    // New: OPML data (import/export)
    var opmlData: Data? { didSet { defaults.set(opmlData, forKey: "news.opml") } }
    
    private var fetch: @Sendable (URL) async throws -> FeedFetchResult
    private var persistentArchive: [ParsedItem] = []  // local article history
    
    init(defaults: UserDefaults = .standard, fetch: (@Sendable (URL) async throws -> FeedFetchResult)? = nil) {
        self.defaults = defaults
        let fetcher = FeedFetcher()
        self.fetch = fetch ?? { url in try await fetcher.fetch(url: url) }
        sources = defaults.stringArray(forKey: "news.sources") ?? []
        readLater = defaults.array(forKey: "news.read_later") as? [String] ?? []
        // Load OPML data if present
        if let saved = defaults.data(forKey: "news.opml") {
            opmlData = saved
        }
    }
    func add(_ value: String) throws {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NewsError.invalid("Enter an HTTP or HTTPS feed URL without credentials.") }
        if !sources.contains(url.absoluteString) { sources.append(url.absoluteString) }
    }
    func remove(_ value: String) { sources.removeAll { $0 == value }; if selected == value { selected = nil; articles = [] } }
    
    // New: toggle read/star status
    func toggleRead(id: String) {
        articleReadStatus[id] = !(articleReadStatus[id] ?? false)
    }
    func toggleStar(id: String) {
        articleStarred[id] = !(articleStarred[id] ?? false)
    }
    
    // New: add to read later queue
    func addToReadLater(_ url: String) {
        if !readLater.contains(url) { readLater.append(url) }
    }
    func removeFromReadLater(_ url: String) {
        readLater.removeAll { $0 == url }
    }
    
    // Original refresh method

    func refresh(_ value: String) async throws {
        guard value == Self.all || sources.contains(value) else { throw NewsError.invalid("Select a subscribed source first.") }
        refreshGeneration += 1
        let generation = refreshGeneration
        let targets = value == Self.all ? sources : [value]
        let results = await withTaskGroup(of: (String, FeedFetchResult?, String?).self, returning: [(String, FeedFetchResult?, String?)].self) { group in
            for source in targets {
                guard let url = URL(string: source) else { continue }
                group.addTask { [fetch] in
                    do { return (source, try await fetch(url), nil) }
                    catch { return (source, nil, error.localizedDescription) }
                }
            }
            var collected: [(String, FeedFetchResult?, String?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        guard generation == refreshGeneration else { return }
        var combined: [ParsedItem] = []
        var origins: [String: String] = [:]
        var failures: [String] = []
        var names: [String] = []
        for (source, result, error) in results {
            if let result {
                names.append(result.feed.title)
                for item in result.feed.items.prefix(200) {
                    // A source-qualified ID preserves distinct entries with the same GUID.
                    var entry = item
                    entry.guid = source + "|" + item.id
                    origins[entry.id] = result.feed.title.isEmpty ? source : result.feed.title
                    combined.append(entry)
                }
            } else if let error { failures.append("\(source): \(error)") }
        }
        // Keep `selected` as the exact source tag so the sources list stays in sync;
        // only the header title is human-readable. Mutating `selected` to a display
        // name breaks the List selection and re-triggers refresh() with an unknown value.
        if value == Self.all { selected = Self.all }
        title = value == Self.all ? "All stories" : (names.first ?? "News")
        articles = combined
        articleSources = origins
        if !failures.isEmpty { message = "Some feeds could not refresh: " + failures.joined(separator: "; ") }
        else { message = combined.isEmpty ? "No stories found." : nil }
        if names.isEmpty && !failures.isEmpty { throw NewsError.invalid(message ?? "Feed refresh failed.") }
    }



// New: refresh with background trigger (requires approval)
    func refreshBackground(_ trigger: String = "manual") async throws {
        guard sources.isEmpty == false else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let targets = sources  // refresh all subscriptions
        let results = await withTaskGroup(of: (String, FeedFetchResult?, String?).self, returning: [(String, FeedFetchResult?, String?)].self) { group in
            for source in targets {
                guard let url = URL(string: source) else { continue }
                group.addTask { [fetch] in
                    do { return (source, try await fetch(url), nil) }
                    catch { return (source, nil, error.localizedDescription) }
                }
            }
            var collected: [(String, FeedFetchResult?, String?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        guard generation == refreshGeneration else { return }
        var combined: [ParsedItem] = []
        var origins: [String: String] = [:]
        var failures: [String] = []
        var names: [String] = []
        for (source, result, error) in results {
            if let result {
                names.append(result.feed.title)
                for item in result.feed.items.prefix(200) {
                    // A source-qualified ID preserves distinct entries with the same GUID.
                    var entry = item
                    entry.guid = source + "|" + item.id
                    origins[entry.id] = result.feed.title.isEmpty ? source : result.feed.title
                    combined.append(entry)
                }
            } else if let error { failures.append("\(source): \(error)") }
        }
        selected = sources.isEmpty ? nil : sources.first
        title = sources.isEmpty ? "News" : (names.first ?? "News")
        articles = combined
        articleSources = origins
        if !failures.isEmpty { message = "Some feeds could not refresh: " + failures.joined(separator: "; ") }
        else { message = combined.isEmpty ? "No stories found." : nil }
        if names.isEmpty && !failures.isEmpty { throw NewsError.invalid(message ?? "Feed refresh failed.") }
    }
    
    // New: full article extraction (simplified - uses WKWebView readability in GUI)
    func extractFullArticle(_ article: ParsedItem) -> String? {
        // In the GUI, this would use a JavaScript-based readability extractor
        // For now, return the summary HTML with a note
        return article.summaryHTML
    }
    
    // New: OPML import - parse and add subscriptions
    func importOPML(_ opmlString: String) {
        // Parse OPML and add feed URLs to sources
        // Simplified: look for <xmlUrl> tags
        let tags = opmlString.components(separatedBy: "<xmlUrl>")
        for tag in tags.dropFirst() {
            let urlString = tag.components(separatedBy: "</xmlUrl>").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let url = URL(string: urlString), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                try? add(url.absoluteString)
            }
        }
        // Save OPML data
        opmlData = opmlString.data(using: .utf8)
    }
    
    // New: OPML export - export current subscriptions
    func exportOPML() -> String {
        // Build OPML manually without multi-line string literals
        var xmlLines: [String] = []
        xmlLines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        xmlLines.append("<outline xmlns=\"http://www.opml.org/rss\" version=\"2.0\">")
        for source in sources {
            xmlLines.append("  <outline text=\"\(source)\" title=\"\(source)\" xmlUrl=\"\(source)\"/>")
        }
        xmlLines.append("</outline>")
        return xmlLines.joined(separator: "\n")
    }
    
    // New: persistent archive management
    func addToArchive(_ article: ParsedItem) {
        // Add to local persistent archive (simplified - in production use SQLite)
        persistentArchive.append(article)
        // Keep only last 500 articles to prevent unbounded growth
        if persistentArchive.count > 500 { persistentArchive.removeFirst(persistentArchive.count - 500) }
    }
    
    // New: search archive by text
    func searchArchive(_ query: String) -> [ParsedItem] {
        persistentArchive.filter { article in
            "\(article.title) \(article.summaryHTML)".localizedCaseInsensitiveContains(query)
        }
    }
}
enum NewsError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil } }
