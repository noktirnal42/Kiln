import SwiftUI
import AppKit

@main
struct KilnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        let model = AppModel()
        _appModel = State(initialValue: model)
        appDelegate.appModel = model
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appModel)
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
        Task { @MainActor in
            await model.shutdown()
        }
    }
}
