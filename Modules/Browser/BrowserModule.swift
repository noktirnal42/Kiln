import Foundation
import SwiftUI
import WebKit
import Observation
import AppKit

/// What a page looked like when the agent read it.
struct BrowserPage: Sendable, Equatable {
    var title: String
    var url: String
    var text: String
    var truncated: Bool
    var outline: String
}

struct BrowserDownload: Identifiable, Equatable {
    enum State: Equatable { case inProgress, finished, failed(String) }
    let id = UUID()
    var name: String
    var source: URL?
    var fileURL: URL
    var state: State = .inProgress
    /// Set once the file has been handed to the package intake (Analyze).
    var importedAs: String?
    var importError: String?
    var isPackage: Bool { BrowserURL.isPackageName(name) }
}

enum BrowserToolError: LocalizedError, Equatable {
    case badURL(String)
    case noSuchTab(String)
    case page(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let text): "Not an http(s) URL: \(text). browser_open needs a full address such as https://example.com."
        case .noSuchTab(let id): "No tab \(id). Call browser_list_tabs for the open tabs."
        case .page(let reason): reason
        }
    }
}

/// The Browser: tabbed WKWebViews sharing one persistent, Kiln-only website data store.
///
/// Page content is untrusted. Nothing here fills in credentials, and the agent-facing operations
/// (`BrowserAgentTools`) say so in their descriptions and in every page they return.
@MainActor
@Observable
public final class BrowserModule: @preconcurrency Module, ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.browser"
    public nonisolated static let displayName = "Browser"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [.networkClient, .fileSystemWrite]

    /// Kiln's own cookie jar and storage: separate from Safari and from every other app, kept between launches.
    static let dataStoreIdentifier = UUID(uuidString: "6B1D8A52-4F0E-4C63-9A57-2E6F0A7D31C4")!

    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: UUID?
    private(set) var downloads: [BrowserDownload] = []

    /// Hands a finished download to the package intake. Wired by the app to the Analyze module; nil in tests.
    @ObservationIgnored var importPackage: (@MainActor (URL) async throws -> String)?

    @ObservationIgnored private let dataStoreOverride: WKWebsiteDataStore?
    @ObservationIgnored private let downloadsOverride: URL?
    @ObservationIgnored private var activeDownloads: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private lazy var configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStoreOverride ?? WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }()
    /// Scripts run here, so a page cannot replace the functions Kiln uses to read and click it.
    private static let world = WKContentWorld.world(name: "KilnBrowser")
    private var context: ModuleContext?

    public nonisolated init() {
        dataStoreOverride = nil
        downloadsOverride = nil
    }

    /// For tests: a throwaway data store and downloads folder, so nothing lands in the real app support folder.
    init(dataStore: WKWebsiteDataStore, downloadsFolder: URL) {
        dataStoreOverride = dataStore
        downloadsOverride = downloadsFolder
    }

    var downloadsFolder: URL { downloadsOverride ?? KilnPackageCatalog.defaultDownloadsFolder }
    var dataStore: WKWebsiteDataStore { configuration.websiteDataStore }
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }

    // MARK: Module lifecycle

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        context.logger.info("Browser module initialized")
    }

    public func activate() async throws {
        if tabs.isEmpty { newTab(url: nil, select: true) }
    }

    public func deactivate() async throws {}

    public func shutdown() async throws {
        for tab in tabs { tab.tearDown() }
        tabs = []
        selectedTabID = nil
        context = nil
    }

    public func makeRootView() -> AnyView { AnyView(BrowserRootView(module: self)) }

    public nonisolated func contributeCommands() -> [CommandContribution] {
        [CommandContribution(identifier: "browser.newTab", title: "New Browser Tab", shortcut: "⌘T", category: "Browser")]
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL?, select: Bool, configuration popupConfiguration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: popupConfiguration ?? configuration, owner: self)
        tabs.append(tab)
        if select || selectedTabID == nil { selectedTabID = tab.id }
        if let url { tab.load(url) }
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].tearDown()
        tabs.remove(at: index)
        if selectedTabID == id { selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        if tabs.isEmpty { newTab(url: nil, select: true) }
    }

    /// Resolves the agent's `tab` argument: nothing means the selected tab; otherwise a 1-based index, or a tab id
    /// (full or the short form `browser_list_tabs` prints).
    func tab(matching reference: String?) throws -> BrowserTab {
        let text = reference?.trimmingCharacters(in: .whitespaces) ?? ""
        if text.isEmpty {
            if let selected = selectedTab { return selected }
            throw BrowserToolError.page("The browser has no open tab. Use browser_open first.")
        }
        if let index = Int(text), tabs.indices.contains(index - 1) { return tabs[index - 1] }
        let lowered = text.lowercased()
        if let match = tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(lowered) }) { return match }
        throw BrowserToolError.noSuchTab(text)
    }

    // MARK: Agent operations

    /// Loads `address` (an http(s) URL) in the named tab, or in a new tab when `reference` is nil and
    /// `inNewTab` is set. Waits for the load to finish.
    func open(address: String, tab reference: String?, inNewTab: Bool) async throws -> BrowserTab {
        guard let url = BrowserURL.resolveStrict(address) else { throw BrowserToolError.badURL(address) }
        let target = (inNewTab || (tabs.isEmpty && (reference ?? "").isEmpty)) ? newTab(url: nil, select: true) : try tab(matching: reference)
        selectedTabID = target.id
        target.load(url)
        await target.waitForLoad()
        return target
    }

    func readPage(tab reference: String?) async throws -> BrowserPage {
        let tab = try tab(matching: reference)
        await tab.waitForLoad()
        let text = try await run(BrowserScripts.readText, ["maxChars": BrowserScripts.maxTextCharacters], in: tab)
        let outline = try await run(BrowserScripts.outline, ["maxItems": BrowserScripts.maxOutlineItems], in: tab)
        return BrowserPage(
            title: text["title"] as? String ?? "", url: text["url"] as? String ?? "",
            text: text["text"] as? String ?? "", truncated: text["truncated"] as? Bool ?? false,
            outline: outline["outline"] as? String ?? "")
    }

    func click(ref: Int, tab reference: String?) async throws -> String {
        let tab = try tab(matching: reference)
        let result = try await run(BrowserScripts.click, ["ref": ref], in: tab)
        guard result["ok"] as? Bool == true else { throw BrowserToolError.page(result["error"] as? String ?? "Click failed.") }
        await settle(tab)
        return "Clicked \(result["clicked"] as? String ?? "element \(ref)"). Page is now: \(tab.url?.absoluteString ?? "unknown")"
    }

    func type(ref: Int, text: String, submit: Bool, tab reference: String?) async throws -> String {
        let tab = try tab(matching: reference)
        let result = try await run(BrowserScripts.type, ["ref": ref, "text": text, "submit": submit], in: tab)
        guard result["ok"] as? Bool == true else { throw BrowserToolError.page(result["error"] as? String ?? "Typing failed.") }
        if result["submitted"] as? Bool == true { await settle(tab) }
        return "Typed \(text.count) characters into element \(ref)" + (result["submitted"] as? Bool == true ? " and submitted its form." : ".")
    }

    /// A PNG of the tab's viewport, in a temporary folder. Returns the file and its pixel size.
    func screenshot(tab reference: String?) async throws -> (file: URL, width: Int, height: Int) {
        let tab = try tab(matching: reference)
        await tab.waitForLoad()
        let image = try await tab.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw BrowserToolError.page("Could not encode the screenshot.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KilnBrowser", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(tab.shortID)-\(Int(Date().timeIntervalSince1970)).png")
        try png.write(to: file)
        return (file, rep.pixelsWide, rep.pixelsHigh)
    }

    /// After an action, give a navigation it caused a moment to start, then wait for it to finish.
    private func settle(_ tab: BrowserTab) async {
        try? await Task.sleep(for: .milliseconds(500))
        await tab.waitForLoad(timeout: 15)
    }

    private func run(_ script: String, _ arguments: [String: Any], in tab: BrowserTab) async throws -> [String: Any] {
        let value: Any?
        do {
            value = try await tab.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: Self.world)
        } catch {
            throw BrowserToolError.page("The page could not be read: \(error.localizedDescription)")
        }
        guard let json = value as? String, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw BrowserToolError.page("The page returned nothing readable (it may still be blank).")
        }
        return object
    }

    // MARK: Downloads

    /// Chooses where a download goes and starts tracking it. Files always land in the package intake's
    /// downloads folder under a safe, non-clobbering name.
    func beginDownload(_ download: WKDownload, suggestedName: String, source: URL?) -> URL? {
        let folder = downloadsFolder
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        let name = BrowserURL.uniqueDownloadName(suggested: suggestedName) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let record = BrowserDownload(name: name, source: source, fileURL: folder.appendingPathComponent(name))
        downloads.insert(record, at: 0)
        activeDownloads[ObjectIdentifier(download)] = record.id
        return record.fileURL
    }

    func finishDownload(_ download: WKDownload, error: Error?) {
        guard let id = activeDownloads.removeValue(forKey: ObjectIdentifier(download)),
              let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = error.map { .failed($0.localizedDescription) } ?? .finished
    }

    /// Sends a finished package or binary to Analyze. The user chooses this; a download never imports itself.
    func importDownload(_ id: UUID) async {
        guard let index = downloads.firstIndex(where: { $0.id == id }), downloads[index].state == .finished else { return }
        guard let importPackage else {
            downloads[index].importError = "Analyze is not available."
            return
        }
        do {
            let name = try await importPackage(downloads[index].fileURL)
            if let i = downloads.firstIndex(where: { $0.id == id }) { downloads[i].importedAs = name; downloads[i].importError = nil }
        } catch {
            if let i = downloads.firstIndex(where: { $0.id == id }) { downloads[i].importError = error.localizedDescription }
        }
    }

    // MARK: Website data

    /// Cookies, caches and storage for every site. Tabs stay open; sites will see a fresh visitor.
    func clearWebsiteData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
