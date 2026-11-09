import Foundation
import CryptoKit

/// Where a package can be looked up. Only `.direct` and `.aptoide` produce a file Kiln can fetch itself;
/// the others hand back the public store listing so the person downloads from the store.
enum KilnPackageSource: String, CaseIterable, Identifiable, Sendable {
    case apple, google, aptoide, apkpure, amazon, direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google Play"
        case .aptoide: "Aptoide"
        case .apkpure: "APKPure"
        case .amazon: "Amazon"
        case .direct: "Direct URL"
        }
    }

    var icon: String {
        switch self {
        case .apple: "applelogo"
        case .google: "play.logo"
        case .aptoide: "antenna.radiowaves.left.and.right"
        case .apkpure: "arrow.down.circle"
        case .amazon: "cart"
        case .direct: "link"
        }
    }

    var helpText: String {
        switch self {
        case .apple: "Searches Apple's public catalog and opens the App Store listing. Kiln does not sign in to download IPAs."
        case .google: "Opens the Google Play search. Kiln does not sign in to download APKs."
        case .aptoide: "Searches Aptoide and downloads the APK when the listing provides a direct file."
        case .apkpure, .amazon: "Opens the store's search page in your browser."
        case .direct: "Paste a link to a package you are allowed to analyze."
        }
    }
}

struct KilnPackageResult: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let listingURL: URL
    /// Set only when Kiln can download the file itself.
    let directURL: URL?
    /// MD5 the store published for `directURL`, when it published one.
    var md5: String? = nil
}

enum PackageIntakeError: LocalizedError {
    case unsupportedURL
    case badStatus(Int)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: "Only http and https links can be downloaded."
        case .badStatus(let code): "The server answered \(code), so nothing was downloaded."
        case .checksumMismatch: "The downloaded file does not match the checksum the store published, so it was discarded."
        }
    }
}

enum KilnPackageCatalog {
    private struct AppleResponse: Decodable { let results: [AppleResult] }
    private struct AppleResult: Decodable {
        let trackId: Int?; let trackName: String?; let artistName: String?; let bundleId: String?; let trackViewUrl: URL?
    }
    private struct AptoideResponse: Decodable { let datalist: AptoideList? }
    private struct AptoideList: Decodable { let list: [AptoideResult]? }
    private struct AptoideResult: Decodable {
        let name: String?; let package: String?
        let developer: AptoideDeveloper?; let file: AptoideFile?
    }
    private struct AptoideDeveloper: Decodable { let name: String? }
    private struct AptoideFile: Decodable { let path: URL?; let vername: String?; let md5sum: String? }

    static var defaultDownloadsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kiln/ReverseEngineering/Downloads", isDirectory: true)
    }

    /// http(s) only: a `file://` link would copy a local file into the project folder under another name.
    static func downloadableURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { throw PackageIntakeError.unsupportedURL }
        return url
    }

    /// A file name that stays inside the downloads folder whatever the URL contains.
    static func fileName(for url: URL) -> String {
        let last = url.lastPathComponent == "/" ? "" : url.lastPathComponent
        let cleaned = last.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "package-\(UUID().uuidString)" : cleaned
    }

    static func listingURL(source: KilnPackageSource, query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch source {
        case .google: return URL(string: "https://play.google.com/store/search?q=\(encoded)&c=apps&hl=en")
        case .apkpure: return URL(string: "https://apkpure.com/search?q=\(encoded)")
        case .amazon: return URL(string: "https://www.amazon.com/s?k=\(encoded)&i=mobile-apps")
        case .apple, .aptoide, .direct: return nil
        }
    }

    static func search(source: KilnPackageSource, query: String) async throws -> [KilnPackageResult] {
        switch source {
        case .direct:
            let url = try downloadableURL(query)
            return [KilnPackageResult(id: url.absoluteString, name: fileName(for: url), detail: url.absoluteString,
                                      listingURL: url, directURL: url)]
        case .apple:
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [URLQueryItem(name: "term", value: query),
                                     URLQueryItem(name: "entity", value: "software"),
                                     URLQueryItem(name: "limit", value: "12")]
            let response = try await get(components.url!, as: AppleResponse.self)
            return response.results.compactMap { item in
                guard let name = item.trackName, let listing = item.trackViewUrl else { return nil }
                return KilnPackageResult(id: "apple-\(item.trackId ?? 0)", name: name,
                                         detail: "\(item.artistName ?? "Apple App Store") · \(item.bundleId ?? "")",
                                         listingURL: listing, directURL: nil)
            }
        case .aptoide:
            var components = URLComponents(string: "https://ws75.aptoide.com/api/7/apps/search")!
            components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: "12")]
            let response = try await get(components.url!, as: AptoideResponse.self)
            return (response.datalist?.list ?? []).compactMap { item in
                guard let name = item.name, let direct = item.file?.path,
                      ["http", "https"].contains(direct.scheme?.lowercased() ?? "") else { return nil }
                return KilnPackageResult(id: "aptoide-\(item.package ?? name)", name: name,
                                         detail: "\(item.developer?.name ?? "Aptoide") · \(item.file?.vername ?? "unknown")",
                                         listingURL: direct, directURL: direct, md5: item.file?.md5sum)
            }
        case .google, .apkpure, .amazon:
            guard let listing = listingURL(source: source, query: query) else { return [] }
            return [KilnPackageResult(id: source.rawValue + "-search", name: query,
                                      detail: source.title + " listing", listingURL: listing, directURL: nil)]
        }
    }

    /// Fetches `url` into `folder` and returns the saved file. A non-2xx answer is an error, not a "package".
    static func download(_ url: URL, into folder: URL, expectedMD5: String? = nil) async throws -> URL {
        _ = try downloadableURL(url.absoluteString)
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw PackageIntakeError.badStatus(http.statusCode)
        }
        if let expectedMD5, !expectedMD5.isEmpty, try md5(of: temporary) != expectedMD5.lowercased() {
            try? FileManager.default.removeItem(at: temporary)
            throw PackageIntakeError.checksumMismatch
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName(for: url))
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func md5(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard status < 400 else { throw PackageIntakeError.badStatus(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
