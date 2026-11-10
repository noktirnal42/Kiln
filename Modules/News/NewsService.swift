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
    private let fetch: @Sendable (URL) async throws -> FeedFetchResult
    init(defaults: UserDefaults = .standard, fetch: (@Sendable (URL) async throws -> FeedFetchResult)? = nil) {
        self.defaults = defaults
        let fetcher = FeedFetcher()
        self.fetch = fetch ?? { url in try await fetcher.fetch(url: url) }
        sources = defaults.stringArray(forKey: "news.sources") ?? []
    }
    func add(_ value: String) throws {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NewsError.invalid("Enter an HTTP or HTTPS feed URL without credentials.") }
        if !sources.contains(url.absoluteString) { sources.append(url.absoluteString) }
    }
    func remove(_ value: String) { sources.removeAll { $0 == value }; if selected == value { selected = nil; articles = [] } }
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
        selected = value
        title = value == Self.all ? "All stories" : (names.first ?? "News")
        articles = combined
        articleSources = origins
        if !failures.isEmpty { message = "Some feeds could not refresh: " + failures.joined(separator: "; ") }
        else { message = combined.isEmpty ? "No stories found." : nil }
        if names.isEmpty && !failures.isEmpty { throw NewsError.invalid(message ?? "Feed refresh failed.") }
    }
}
enum NewsError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil } }
