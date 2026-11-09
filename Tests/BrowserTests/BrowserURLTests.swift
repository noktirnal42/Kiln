import Foundation
import Testing
@testable import Kiln

struct BrowserURLTests {
    @Test func fullAddressesAreKeptAsTyped() {
        #expect(BrowserURL.resolve("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(BrowserURL.resolve("  http://example.com  ")?.absoluteString == "http://example.com")
    }

    @Test func bareHostsGetHTTPSAndLocalHostsGetHTTP() {
        #expect(BrowserURL.resolve("example.com")?.absoluteString == "https://example.com")
        #expect(BrowserURL.resolve("example.com/path")?.absoluteString == "https://example.com/path")
        #expect(BrowserURL.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserURL.resolve("127.0.0.1:8080/x")?.absoluteString == "http://127.0.0.1:8080/x")
        #expect(BrowserURL.resolve("example.com:8443")?.absoluteString == "https://example.com:8443")
    }

    @Test func otherTextBecomesASearch() throws {
        let url = try #require(BrowserURL.resolve("swift concurrency tips"))
        #expect(url.host() == "duckduckgo.com")
        #expect(url.absoluteString.contains("swift%20concurrency%20tips"))
        #expect(BrowserURL.resolve("hello")?.host() == "duckduckgo.com")
    }

    @Test func dangerousAndNonWebSchemesAreRefused() {
        for text in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,<b>x</b>", "mailto:a@b.com", "ftp://example.com", "x-apple.systempreferences:", "https://"] {
            #expect(BrowserURL.resolve(text) == nil, "\(text)")
            #expect(BrowserURL.resolveStrict(text) == nil, "\(text)")
        }
        #expect(BrowserURL.resolve("") == nil)
        #expect(BrowserURL.resolve("about:blank")?.absoluteString == "about:blank")
    }

    @Test func theAgentNeverGetsASilentSearchOrBareHost() {
        #expect(BrowserURL.resolveStrict("example.com") == nil)
        #expect(BrowserURL.resolveStrict("find me a thing") == nil)
        #expect(BrowserURL.resolveStrict("https://example.com")?.host() == "example.com")
    }

    @Test func packageNamesAreRecognised() {
        for name in ["app.apk", "App.IPA", "tool.dmg", "lib.so", "setup.exe", "bundle.xapk"] { #expect(BrowserURL.isPackageName(name), "\(name)") }
        for name in ["notes.txt", "photo.png", "archive", "apk"] { #expect(!BrowserURL.isPackageName(name), "\(name)") }
    }

    @Test func downloadNamesStayInTheFolderAndNeverClobber() {
        #expect(BrowserURL.uniqueDownloadName(suggested: "../../etc/passwd", existing: { _ in false }) == "passwd")
        #expect(BrowserURL.uniqueDownloadName(suggested: "a.apk", existing: { _ in false }) == "a.apk")
        let taken: Set<String> = ["a.apk", "a-2.apk"]
        #expect(BrowserURL.uniqueDownloadName(suggested: "a.apk", existing: { taken.contains($0) }) == "a-3.apk")
        #expect(!BrowserURL.uniqueDownloadName(suggested: "", existing: { _ in false }).isEmpty)
    }
}
