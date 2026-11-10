import Foundation
import Observation
import RSSReaderCore

@MainActor @Observable final class NewsState {
    static let shared = NewsState()
    private let defaults: UserDefaults
    var sources: [String] { didSet { defaults.set(sources, forKey: "news.sources") } }
    var selected: String?
    var articles: [ParsedItem] = []
    var title = "News"
    var busy = false
    var message: String?
    private let fetcher = FeedFetcher()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; sources = defaults.stringArray(forKey: "news.sources") ?? [] }
    func add(_ value: String) throws {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NewsError.invalid("Enter an HTTP or HTTPS feed URL without credentials.") }
        if !sources.contains(url.absoluteString) { sources.append(url.absoluteString) }
    }
    func remove(_ value: String) { sources.removeAll { $0 == value }; if selected == value { selected = nil; articles = [] } }
    func refresh(_ value: String) async throws {
        guard sources.contains(value), let url = URL(string: value) else { throw NewsError.invalid("Select a subscribed source first.") }
        let result = try await fetcher.fetch(url: url)
        selected = value; title = result.feed.title; articles = Array(result.feed.items.prefix(200)); message = articles.isEmpty ? "This feed has no entries." : nil
    }
}
enum NewsError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil } }
