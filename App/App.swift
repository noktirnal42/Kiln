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
                .environment(appModel)
                .onOpenURL { appModel.openWebURL($0) }
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

        Settings {
            ProviderSettingsView()
                .environment(appModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

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
