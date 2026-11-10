import Foundation

public struct FeedFetchResult: Sendable {
    public let feed: ParsedFeed
    public let finalURL: URL
    public let etag: String?
    public let lastModified: String?
    public let notModified: Bool
    public let byteCount: Int
    public let fetchedAt: Date

    public init(
        feed: ParsedFeed,
        finalURL: URL,
        etag: String?,
        lastModified: String?,
        notModified: Bool,
        byteCount: Int,
        fetchedAt: Date = .now
    ) {
        self.feed = feed
        self.finalURL = finalURL
        self.etag = etag
        self.lastModified = lastModified
        self.notModified = notModified
        self.byteCount = byteCount
        self.fetchedAt = fetchedAt
    }
}

public enum FeedFetchError: Error, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .httpStatus(let code): "The server returned HTTP \(code)."
        case .emptyResponse: "The server returned an empty document."
        case .transport(let message): message
        }
    }
}

/// Async feed downloader with conditional GET, redirect handling and discovery.
public actor FeedFetcher {
    public static let userAgent =
        "ModernReader/1.0 (macOS; iOS; +https://github.com/modern-reader) AppleWebKit"

    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Fetching

    public func fetch(
        url: URL,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws -> FeedFetchResult {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw FeedFetchError.transport(error.localizedDescription)
        } catch {
            throw FeedFetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedFetchError.invalidResponse
        }

        let finalURL = http.url ?? url
        let newETag = http.value(forHTTPHeaderField: "ETag")
        let newLastModified = http.value(forHTTPHeaderField: "Last-Modified")

        if http.statusCode == 304 {
            return FeedFetchResult(
                feed: ParsedFeed(title: "", format: .unknown, items: []),
                finalURL: finalURL,
                etag: newETag ?? etag,
                lastModified: newLastModified ?? lastModified,
                notModified: true,
                byteCount: 0
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw FeedFetchError.emptyResponse
        }

        let feed = try FeedParser.parse(data: data, sourceURL: finalURL)
        return FeedFetchResult(
            feed: feed,
            finalURL: finalURL,
            etag: newETag,
            lastModified: newLastModified,
            notModified: false,
            byteCount: data.count
        )
    }

    public func fetch(_ feed: Feed) async throws -> FeedFetchResult {
        try await fetch(url: feed.url, etag: feed.etag, lastModified: feed.lastModified)
    }

    public func validate(url: URL) async throws -> ParsedFeed {
        try await fetch(url: url).feed
    }

    // MARK: - Discovery

    /// Looks for `<link rel="alternate">` feeds on a page, then probes conventional paths.
    public func discover(pageURL: URL) async throws -> [DiscoveredFeed] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: pageURL)
        } catch {
            throw FeedFetchError.transport(error.localizedDescription)
        }

        let finalURL = (response as? HTTPURLResponse)?.url ?? pageURL
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let found = FeedDiscovery.links(inHTML: html, baseURL: finalURL)
        if !found.isEmpty { return found }

        // Conventional locations, validated by actually parsing them.
        let candidates = ["/feed", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml", "/feed/"]
        var probes: [DiscoveredFeed] = []
        for path in candidates {
            guard let candidate = URL(string: path, relativeTo: finalURL)?.absoluteURL else { continue }
            guard let feed = try? await fetch(url: candidate).feed else { continue }
            probes.append(
                DiscoveredFeed(
                    title: feed.title.isEmpty ? (candidate.host() ?? "Feed") : feed.title,
                    url: candidate,
                    format: feed.format
                )
            )
            if probes.count >= 3 { break }
        }
        return probes
    }
}
