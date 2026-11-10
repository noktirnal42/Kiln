import Foundation
import Testing
import RSSReaderCore
@testable import Kiln

@MainActor struct NewsTests {
    @Test func subscriptionsValidateAndPersist() throws {
        let suite = "kiln.news.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = NewsState(defaults: defaults)
        #expect(throws: (any Error).self) { try state.add("file:///etc/passwd") }
        #expect(throws: (any Error).self) { try state.add("https://user:pass@example.com/feed") }
        try state.add("https://example.com/feed"); try state.add("https://example.com/feed")
        #expect(NewsState(defaults: defaults).sources.count == 1)
        state.remove("https://example.com/feed")
        #expect(NewsState(defaults: defaults).sources.isEmpty)
    }
    @Test func modernReaderParsesAnRSSFeed() throws {
        let xml = "<rss version=\"2.0\"><channel><title>Test</title><item><title>Story</title><link>https://example.com/story</link></item></channel></rss>"
        let feed = try FeedParser.parse(data: Data(xml.utf8))
        #expect(feed.title == "Test" && feed.items.first?.title == "Story")
        #expect(!BuiltInSources.all.isEmpty)
    }
    @Test func allStoriesCombinesSuccessfulSourcesAndReportsFailures() async throws {
        let suite = "kiln.news.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = NewsState(defaults: defaults, fetch: { url in
            if url.host == "bad.example" { throw NewsError.invalid("offline") }
            let feed = ParsedFeed(title: url.host ?? "", format: .rss, items: [ParsedItem(title: "Story", summaryHTML: "", contentHTML: "")])
            return FeedFetchResult(feed: feed, finalURL: url, etag: nil, lastModified: nil, notModified: false, byteCount: 1)
        })
        try state.add("https://one.example/feed"); try state.add("https://two.example/feed"); try state.add("https://bad.example/feed")
        try await state.refresh(NewsState.all)
        #expect(state.articles.count == 2)
        #expect(Set(state.articles.map(\.id)).count == 2)
        #expect(Set(state.articleSources.values) == ["one.example", "two.example"])
        #expect(state.message?.contains("bad.example") == true)
    }
    @Test func networkAndMutationsRequireApproval() {
        #expect(NewsTool(kind: .directory).spec.permission == .read)
        #expect(NewsTool(kind: .subscribe).spec.permission == .write)
        #expect(NewsTool(kind: .refresh).spec.permission == .execute)
        #expect(MapsTool(kind: .location).spec.permission == .execute)
        #expect(MapsTool(kind: .directions).spec.permission == .execute)
    }
}
