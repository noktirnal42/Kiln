import SwiftUI
import AppKit

enum QuickAskSettings {
    static let menuBarKey = "quickAsk.showInMenuBar"
}

/// The window that drops down from Kiln's menu-bar item: type a question, send it to the chat or just put it in the message box.
struct QuickAskPanel: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { QuickAskLink.sanitize(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Kiln").font(.headline)
            TextField("What do you want to ask?", text: $text, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(ask)
            HStack {
                Button("Ask", action: ask).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
                Button("Put in message box", action: fill).disabled(trimmed.isEmpty)
                Spacer()
                Button("Open Kiln") { Task { await app.quickAsk(QuickAskRequest(text: "", source: .menuBar)) } }.buttonStyle(.link)
            }
            Text("Tool approvals still appear in Kiln. Nothing is sent until you press Ask.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 340)
        .onAppear { focused = true }
    }

    private func ask() {
        let request = QuickAskRequest(text: trimmed, source: .menuBar)
        guard !request.text.isEmpty else { return }
        text = ""
        Task { await app.quickAsk(request, sendNow: true) }
    }

    private func fill() {
        let request = QuickAskRequest(text: trimmed, source: .menuBar)
        guard !request.text.isEmpty else { return }
        text = ""
        Task { await app.quickAsk(request, sendNow: false) }
    }
}

/// Settings → Menu bar: whether Kiln has a menu-bar item, and how links and sharing reach the message box.
struct QuickAskSettingsCard: View {
    @AppStorage(QuickAskSettings.menuBarKey) private var showInMenuBar = false

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("Menu bar and links").font(SSTypography.headline())
            Toggle("Show Kiln in the menu bar", isOn: $showInMenuBar)
            Text("A field you can type a question into from anywhere. Ask sends it to the chat and brings Kiln forward; Put in message box leaves it for you to edit. Tool approvals still appear in Kiln.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            Text("Links: kiln://ask?text=… and kiln://share?title=…&url=…&text=… put text in the message box after whatever you are typing. A link can come from any web page, so it never sends by itself.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
        }
        .padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading).ssPanel()
    }
}

/// Kiln's menu-bar item, shown only while "Show Kiln in the menu bar" is on. It opens `QuickAskPanel` in a popover.
@MainActor
final class MenuBarController: NSObject {
    private let appModel: AppModel
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var observer: NSObjectProtocol?

    init(appModel: AppModel) { self.appModel = appModel }

    func start() {
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private var wanted: Bool { UserDefaults.standard.bool(forKey: QuickAskSettings.menuBarKey) }

    /// Creating a status item makes AppKit write its position to UserDefaults, which posts `didChangeNotification`
    /// while `item` is still nil. Without this guard that re-entered `apply()` until the stack overflowed.
    private var isApplying = false

    private func apply() {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if wanted, item == nil {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "flame", accessibilityDescription: "Ask Kiln")
            statusItem.button?.target = self
            statusItem.button?.action = #selector(toggle)
            item = statusItem
        } else if !wanted, let existing = item {
            popover?.close(); popover = nil
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if let popover, popover.isShown { popover.close(); return }
        let fresh = NSPopover()
        fresh.behavior = .transient
        fresh.contentViewController = NSHostingController(rootView: QuickAskPanel().environment(appModel))
        fresh.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = fresh
    }

}
