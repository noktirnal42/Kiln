import Foundation
import CryptoKit

// Dictionary index and store (docs/DECRYPTION_TOOLING.md stage 3): the app ships a curated index
// of public, freely licensed wordlists, not the lists themselves. The store downloads an entry
// over HTTPS only, enforces a size cap, and pins the SHA-256 observed on first verified download
// (trust-on-first-use, because upstream lists are re-tagged); every later download and every
// reuse is verified against the pin, and a mismatch discards the file. License and attribution
// ride along with each entry. Nothing but these pinned public sources is ever fetched.

public struct WordlistEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let category: String
    public let license: String
    public let sourceURL: String
    /// Approximate upstream size, for display only; the hard cap is enforced at download time.
    public let sizeBytes: Int64
    public let notes: String
}

public enum WordlistCatalog {
    /// Download cap for any catalog entry (largest known public password lists are single-digit MB).
    public static let maxDownloadBytes = 64 * 1024 * 1024

    public static let entries: [WordlistEntry] = [
        WordlistEntry(name: "seclists-top-10000", category: "passwords", license: "MIT",
                      sourceURL: "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10-million-password-list-top-10000.txt",
                      sizeBytes: 76_000, notes: "10,000 most common passwords; standard first list for authorized key testing."),
        WordlistEntry(name: "seclists-top-1000000", category: "passwords", license: "MIT",
                      sourceURL: "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10-million-password-list-top-1000000.txt",
                      sizeBytes: 7_800_000, notes: "Million-entry common-password list; slower runs, same rules."),
    ]

    public static func entry(named name: String) -> WordlistEntry? { entries.first { $0.name == name } }
}

public final class WordlistStore: @unchecked Sendable {
    public let directory: URL
    let session: URLSession

    public init(directory: URL? = nil, session: URLSession = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AxiomRE/Wordlists", isDirectory: true)
        self.session = session
    }

    var manifestURL: URL { directory.appendingPathComponent("pinned-hashes.json") }

    /// Name → pinned SHA-256 for every installed list.
    public func installed() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
    }

    public func path(for name: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitized(name)).txt")
    }

    static func sanitized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
    }

    /// Downloads a catalog entry, verifies it (against the pin when one exists, otherwise pins it),
    /// and stores it atomically. Returns the stored file URL.
    @discardableResult
    public func download(_ entry: WordlistEntry, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard let url = URL(string: entry.sourceURL), url.scheme == "https" else {
            throw AxiomError.message("Catalog sources must be HTTPS URLs.")
        }
        progress?(0)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AxiomError.message("Download failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1).")
        }
        guard data.count <= WordlistCatalog.maxDownloadBytes else {
            throw AxiomError.message("Download exceeds the \(WordlistCatalog.maxDownloadBytes / 1024 / 1024) MiB cap; refusing.")
        }
        progress?(1)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var pins = try installed()
        if let pinned = pins[entry.name] {
            guard pinned == hash else {
                throw AxiomError.message("Downloaded \(entry.name) does not match the pinned SHA-256 (expected \(pinned.prefix(16))…, got \(hash.prefix(16))…). The upstream file changed; re-pin deliberately or investigate.")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = path(for: entry.name)
        let temporary = directory.appendingPathComponent("\(Self.sanitized(entry.name)).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: file)
        pins[entry.name] = hash
        let manifest = try JSONEncoder().encode(pins.sorted { $0.key < $1.key }.reduce(into: [String: String]()) { $0[$1.key] = $1.value })
        try manifest.write(to: manifestURL, options: .atomic)
        return file
    }

    /// Verifies an installed file against its pin; refuses to hand back unverified bytes.
    public func verifiedData(named name: String) throws -> Data {
        let pins = try installed()
        guard let pinned = pins[name] else { throw AxiomError.message("\(name) is not installed.") }
        let file = path(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw AxiomError.message("\(name) is pinned but the file is missing; re-download it.") }
        let data = try Data(contentsOf: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == pinned else { throw AxiomError.message("\(name) failed its pinned SHA-256 check; delete and re-download.") }
        return data
    }
}
