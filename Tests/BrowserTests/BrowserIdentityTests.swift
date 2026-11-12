import Foundation
import Testing
import WebKit
@testable import Kiln

@MainActor
struct BrowserIdentityTests {
    @Test func theApplicationNameNamesSafariOfTheMacsVersion() {
        #expect(BrowserIdentity.applicationName(macOSMajorVersion: 26) == "Version/26.0 Safari/605.1.15")
        #expect(BrowserIdentity.applicationName(macOSMajorVersion: 3) == "Version/15.0 Safari/605.1.15", "never older than the first Safari with the features streaming needs")
    }

    @Test func aRealTabSendsAUserAgentThatSaysSafari() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-browser-tests-\(UUID().uuidString)")
        let module = BrowserModule(dataStore: .nonPersistent(), downloadsFolder: folder)
        let tab = module.newTab(url: nil, select: false)
        let agent = try #require(try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String)
        #expect(agent.contains("AppleWebKit/"))
        #expect(agent.contains(" Version/"), Comment(rawValue: "streaming sites look for the Version token that Safari sends: \(agent)"))
        #expect(agent.contains(" Safari/605.1.15"), Comment(rawValue: agent))
    }

    @Test func fullscreenAndPlaybackWithoutAClickAreOn() {
        let configuration = WKWebViewConfiguration()
        BrowserIdentity.apply(to: configuration)
        #expect(configuration.preferences.isElementFullscreenEnabled)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
    }
}
