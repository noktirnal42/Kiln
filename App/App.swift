import SwiftUI
import AppKit

@main
struct SuperMetaAppApp: App {
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let appModel else { return }
        let model = appModel
        Task { @MainActor in
            await model.shutdown()
        }
    }
}
