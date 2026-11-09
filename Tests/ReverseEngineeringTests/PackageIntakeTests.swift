import Foundation
import Testing
@testable import Kiln

@Suite("Package intake")
struct PackageIntakeTests {
    @Test func acceptsHTTPAndHTTPSOnly() throws {
        #expect(try KilnPackageCatalog.downloadableURL("https://example.com/app.apk").host == "example.com")
        #expect(try KilnPackageCatalog.downloadableURL(" http://example.com/a.ipa \n").lastPathComponent == "a.ipa")
        for bad in ["file:///etc/passwd", "ftp://example.com/a.apk", "example.com/a.apk", "https://", ""] {
            #expect(throws: PackageIntakeError.self) { try KilnPackageCatalog.downloadableURL(bad) }
        }
    }

    @Test func fileNamesStayInsideTheFolder() {
        #expect(KilnPackageCatalog.fileName(for: URL(string: "https://x.test/dir/app.apk?token=1")!) == "app.apk")
        #expect(KilnPackageCatalog.fileName(for: URL(string: "https://x.test/..")!).hasPrefix("package-"))
        #expect(KilnPackageCatalog.fileName(for: URL(string: "https://x.test/")!).hasPrefix("package-"))
    }

    @Test func storeListingsAreBuiltWithoutNetwork() async throws {
        let google = try #require(KilnPackageCatalog.listingURL(source: .google, query: "my app & more"))
        #expect(google.absoluteString.hasPrefix("https://play.google.com/store/search?q=my%20app%20&%20more"))
        #expect(KilnPackageCatalog.listingURL(source: .aptoide, query: "x") == nil)
        // Listing-only sources must not touch the network and must not claim a direct download.
        for source in [KilnPackageSource.google, .apkpure, .amazon] {
            let results = try await KilnPackageCatalog.search(source: source, query: "notes")
            #expect(results.count == 1)
            #expect(results[0].directURL == nil)
        }
    }

    @Test func directSourceIsDownloadable() async throws {
        let results = try await KilnPackageCatalog.search(source: .direct, query: "https://x.test/pkg/app.deb")
        #expect(results.first?.directURL?.lastPathComponent == "app.deb")
        await #expect(throws: PackageIntakeError.self) {
            try await KilnPackageCatalog.search(source: .direct, query: "file:///tmp/a")
        }
    }
}

@Suite("Package checksum")
struct PackageChecksumTests {
    @Test func md5MatchesKnownDigest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("md5-\(UUID().uuidString).bin")
        try Data("kiln".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try KilnPackageCatalog.md5(of: file) == "9e8287435ae73a052c9459e215e46a28")
    }
}
