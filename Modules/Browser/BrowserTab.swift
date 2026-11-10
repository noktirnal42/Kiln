import Foundation
import WebKit
import Observation
import AppKit

/// One browser tab: a web view plus the state the toolbar and the agent tools read from it.
@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    nonisolated let id = UUID()
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored weak var owner: BrowserModule?

    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var failure: String?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A short handle the agent can quote back: the first eight characters of the tab's UUID.
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }

    init(configuration: WKWebViewConfiguration, owner: BrowserModule) {
        // A fixed size so snapshots and layout work while the tab is not on screen.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        self.owner = owner
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    func load(_ url: URL) {
        failure = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { failure = nil; webView.reload() }
    func stop() { webView.stopLoading() }

    /// Waits until the current load finishes or fails, or `timeout` seconds pass. Never throws: a slow
    /// page is reported by what is on it, not by an error.
    func waitForLoad(timeout: TimeInterval = 20) async {
        guard isLoading else { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.resumeWaiters()
        }
        await withCheckedContinuation { waiters.append($0) }
        deadline.cancel()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// Called when the tab is closed so a waiting agent call is not left hanging.
    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations = []
        resumeWaiters()
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        // Only web pages. `file:`, `javascript:` and custom schemes (another app's deep link) are not opened.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.hasPrefix("attachment")
        decisionHandler(navigationResponse.canShowMIMEType && !isAttachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
        resumeWaiters()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    private func record(_ error: Error) {
        let ns = error as NSError
        // A download or a superseded load cancels the navigation it replaced; that is not a failure to show.
        if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) && ns.code != 102 {
            failure = error.localizedDescription
        }
        resumeWaiters()
    }
}

extension BrowserTab: WKUIDelegate {
    /// WebKit must own the returned web view's first navigation and configuration. Returning nil
    /// breaks popup-based sign-in flows that communicate with their opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let owner else { return nil }
        return owner.newTab(url: nil, select: true, configuration: configuration).webView
    }
}

extension BrowserTab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let owner else { completionHandler(nil); return }
        completionHandler(owner.beginDownload(download, suggestedName: suggestedFilename, source: response.url))
    }

    func downloadDidFinish(_ download: WKDownload) { owner?.finishDownload(download, error: nil) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        owner?.finishDownload(download, error: error)
    }
}
