import Foundation
import WebKit

/// How Kiln's browser presents itself to websites and which media features it turns on.
///
/// A bare `WKWebView` reports a user agent with no Safari token, so streaming and cloud-gaming sites (Xbox Cloud Gaming,
/// GeForce NOW and the like) decide the browser cannot stream and refuse to start. The same engine is Safari's, so the
/// browser says so: it names itself as Safari of the Mac's own version. Fullscreen for page elements and playback
/// without a click are what a game stream needs after that.
enum BrowserIdentity {
    /// The text WebKit appends to its user agent: "Version/26.0 Safari/605.1.15" on macOS 26.
    static func applicationName(macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        "Version/\(max(macOSMajorVersion, 15)).0 Safari/605.1.15"
    }

    @MainActor
    static func apply(to configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = applicationName()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
    }
}
