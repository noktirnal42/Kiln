import SwiftUI
import AppKit
import AppIntents
import CoreSpotlight

@main
struct KilnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        let model = AppModel()
        AppDependencyManager.shared.add(dependency: model)
        _appModel = State(initialValue: model)
        appDelegate.appModel = model
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .id(appModel.themeManager.themes.revision)   // redraws with the new colours when the theme changes
                .tint(SSColor.accent)
                .environment(appModel)
                .onOpenURL { appModel.open($0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // A Spotlight result for one of our conversations: open it in the Agent.
                    guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let id = ConversationSpotlight.conversationID(from: identifier), let session = appModel.chatSession else { return }
                    appModel.requestedActivity = .agent
                    Task { await session.loadConversation(id) }
                }
                .task {
                    await appModel.bootstrap()
                }
        }
        .windowStyle(.automatic)
        // A kiln:// or http link is handled by the window that exists instead of opening a second one.
        .handlesExternalEvents(matching: Set(["*"]))

        Settings {
            ProviderSettingsView()
                .environment(appModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Services menu entry "Ask Kiln" (selected text in any app) calls `askKiln(_:userData:error:)`.
        NSApp.servicesProvider = self
        // The menu-bar item is an NSStatusItem, not a SwiftUI MenuBarExtra: a MenuBarExtra whose presence came from a stored setting made the
        // app's scene graph re-evaluate without end and hung the launch.
        if let appModel { MainActor.assumeIsolated { menuBar = MenuBarController(appModel: appModel); menuBar?.start() } }
    }

    /// Services: the selected text goes to Kiln's message box, after whatever is already there. It is never sent by itself.
    @objc func askKiln(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string).map(QuickAskLink.sanitize), !text.isEmpty else {
            error.pointee = "Kiln found no text to ask about." as NSString
            return
        }
        let model = appModel
        Task { @MainActor in await model?.quickAsk(QuickAskRequest(text: text, source: .share)) }
    }

    /// Quitting with unsaved editor changes asks first. Recovery copies are kept for Cancel and Save failures.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel else { return .terminateNow }
        let dirty = MainActor.assumeIsolated { appModel.editor.dirtyDocuments.map(\.name) }
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? "Save changes to \(dirty[0])?" : "Save changes to \(dirty.count) files?"
        alert.informativeText = dirty.prefix(6).joined(separator: ", ") + (dirty.count > 6 ? "…" : "")
            + "\nYour changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let saved = MainActor.assumeIsolated { () -> Bool in
                appModel.editor.saveAll()
                return !appModel.editor.hasUnsavedChanges
            }
            return saved ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            MainActor.assumeIsolated { appModel.editor.discardAllUnsaved() }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let appModel else { return }
        let model = appModel
        MainActor.assumeIsolated { model.editor.debug.reset() }
        Task { @MainActor in
            await model.shutdown()
        }
    }
}
