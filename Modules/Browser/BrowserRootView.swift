import SwiftUI
import WebKit
import AppKit

/// Hosts a tab's web view. The web view is owned by the tab, so switching tabs swaps the subview
/// instead of recreating the page.
struct BrowserWebContainer: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(tab.webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== tab.webView { attach(tab.webView, to: container) }
    }

    private func attach(_ view: WKWebView, to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

struct BrowserRootView: View {
    let module: BrowserModule
    @State private var addressText = ""
    @State private var addressNote: String?
    @State private var showFind = false
    @State private var findText = ""
    @State private var findMissing = false
    @State private var confirmClear = false
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    private var tab: BrowserTab? { module.selectedTab }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            toolbar
            if showFind { findBar }
            if let tab, tab.isLoading {
                ProgressView(value: tab.progress).progressViewStyle(.linear).tint(SSColor.accent).frame(height: 2)
            } else {
                Color.clear.frame(height: 2)
            }
            content
            if !module.downloads.isEmpty { downloadsTray }
        }
        .background(SSColor.canvas)
        .background { shortcuts }
        .task { if module.tabs.isEmpty { module.newTab(url: nil, select: true) } }
        .onChange(of: tab?.url) { _, newValue in if !addressFocused { addressText = newValue?.absoluteString ?? "" } }
        .onChange(of: module.selectedTabID) { _, _ in addressText = tab?.url?.absoluteString ?? ""; addressNote = nil }
        .confirmationDialog("Clear all website data?", isPresented: $confirmClear) {
            Button("Clear Cookies and Site Data", role: .destructive) { Task { await module.clearWebsiteData() } }
        } message: {
            Text("Signs you out of every site in Kiln's Browser. Safari and other apps are not affected.")
        }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(module.tabs) { item in tabButton(item) }
                }
            }
            Button { module.newTab(url: nil, select: true); addressFocused = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")
        }
        .padding(.horizontal, SSSpacing.s).padding(.vertical, 4)
    }

    private func tabButton(_ item: BrowserTab) -> some View {
        let selected = item.id == module.selectedTabID
        return HStack(spacing: 6) {
            if item.isLoading { ProgressView().controlSize(.mini) } else { Image(systemName: "globe").foregroundStyle(.secondary) }
            Text(item.displayTitle).lineLimit(1).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: 160, alignment: .leading)
            Button { module.closeTab(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless).help("Close Tab").accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? SSColor.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { module.selectedTabID = item.id }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: SSSpacing.s) {
            Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!(tab?.canGoBack ?? false)).help("Back (⌘[)").accessibilityLabel("Back")
            Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!(tab?.canGoForward ?? false)).help("Forward (⌘])").accessibilityLabel("Forward")
            Button {
                if tab?.isLoading == true { tab?.stop() } else { tab?.reload() }
            } label: { Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise") }
                .disabled(tab?.url == nil && tab?.isLoading != true)
                .help(tab?.isLoading == true ? "Stop" : "Reload (⌘R)")
                .accessibilityLabel(tab?.isLoading == true ? "Stop" : "Reload")

            TextField("Search or enter address", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(go)
                .accessibilityLabel("Address")

            Button { showFind.toggle(); if showFind { findFocused = true } else { clearFind() } } label: { Image(systemName: "magnifyingglass") }
                .help("Find in Page (⌘F)").accessibilityLabel("Find in Page")
            Menu {
                Button("Clear Cookies and Site Data…") { confirmClear = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Browser Options")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, SSSpacing.s).padding(.vertical, 6)
    }

    private func go() {
        guard let tab else { return }
        guard let url = BrowserURL.resolve(addressText) else {
            addressNote = "Kiln's Browser opens http and https pages only."
            return
        }
        addressNote = nil
        tab.load(url)
        addressFocused = false
    }

    // MARK: Find

    private var findBar: some View {
        HStack(spacing: SSSpacing.s) {
            TextField("Find in page", text: $findText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                .focused($findFocused)
                .onSubmit { find(backwards: false) }
                .accessibilityLabel("Find in page")
            Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous Match")
            Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next Match")
            if findMissing { Text("Not found").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Done") { showFind = false; clearFind() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, SSSpacing.s).padding(.bottom, 6)
    }

    private func find(backwards: Bool) {
        guard let tab, !findText.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        tab.webView.find(findText, configuration: configuration) { result in
            Task { @MainActor in findMissing = !result.matchFound }
        }
    }

    private func clearFind() {
        findMissing = false
        tab?.webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let tab {
            ZStack {
                BrowserWebContainer(tab: tab).id(tab.id)
                if tab.url == nil && !tab.isLoading { startPage }
                if let failure = tab.failure { failureBanner(failure) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var startPage: some View {
        VStack(spacing: SSSpacing.s) {
            Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Search or enter an address").font(SSTypography.headline())
            Text("Pages open here, in Kiln's own browser. Ask the agent to open or read a page with browser_open and browser_read_page.")
                .font(SSTypography.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let addressNote { Text(addressNote).font(SSTypography.caption()).foregroundStyle(SSColor.warning) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SSColor.canvas)
    }

    private func failureBanner(_ text: String) -> some View {
        VStack {
            HStack(spacing: SSSpacing.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SSColor.warning)
                Text(text).font(SSTypography.caption()).lineLimit(2)
                Spacer()
                Button("Retry") { tab?.reload() }.buttonStyle(.borderless)
            }
            .padding(SSSpacing.s)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(SSSpacing.s)
            Spacer()
        }
    }

    // MARK: Downloads

    private var downloadsTray: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(module.downloads.prefix(6)) { item in downloadRow(item) }
                }
                .padding(SSSpacing.s)
            }
            .frame(maxHeight: 130)
        }
        .background(SSColor.surface)
    }

    private func downloadRow(_ item: BrowserDownload) -> some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: item.isPackage ? "shippingbox" : "arrow.down.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(ThemeRuntime.font(12, .medium)).lineLimit(1)
                switch item.state {
                case .inProgress: Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason): Text(reason).font(.caption).foregroundStyle(SSColor.danger).lineLimit(1)
                case .finished:
                    if let imported = item.importedAs { Text("Sent to Analyze: \(imported)").font(.caption).foregroundStyle(SSColor.success) }
                    else if let error = item.importError { Text(error).font(.caption).foregroundStyle(SSColor.danger).lineLimit(1) }
                    else { Text("Saved to the package downloads folder").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if item.state == .finished {
                if item.isPackage && item.importedAs == nil {
                    Button("Analyze in Kiln") { Task { await module.importDownload(item.id) } }
                        .controlSize(.small)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Group {
            Button("New Tab") { module.newTab(url: nil, select: true); addressFocused = true }
                .keyboardShortcut("t", modifiers: .command)
            Button("Focus Address") { addressFocused = true }.keyboardShortcut("l", modifiers: .command)
            Button("Reload") { tab?.reload() }.keyboardShortcut("r", modifiers: .command)
            Button("Back") { tab?.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { tab?.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("Find") { showFind = true; findFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("Close Tab") { if let id = module.selectedTabID { module.closeTab(id) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
