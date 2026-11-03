import KilnRemoteKit
import SwiftUI

@main
struct KilnWatchApp: App {
    @State private var session: RemoteSession
    private let phoneLink: PhoneLink
    private let bridge: PhoneBridge
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let bridge = PhoneBridge(messenger: WCMessenger())
        self.bridge = bridge
        let session = RemoteSession(
            store: KeychainPairingStore(),
            connector: { pairing, progress in try await MacConnector.channel(pairing, bridge: bridge, progress: progress) },
            transcriber: DictationTranscriber(),
            speaker: SystemSpeaker(),
            haptics: WatchHaptics()
        )
        Demo.applyIfRequested(to: session)
        #if DEBUG
        // `-pair <kiln-remote://pair?...>` stands in for the iPhone hand-off while testing on a device.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-pair"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]), let payload = PairingPayload(url: url) {
            KeychainPairingStore().save(payload)
            session.pairingChanged(payload)
        }
        #endif
        _session = State(initialValue: session)
        phoneLink = PhoneLink(onChange: { [session] payload in session.pairingChanged(payload) }, onStatus: { [session] text in session.phoneStatus = text }, bridge: bridge, onReachable: { [session] in session.phoneBecameReachable() }, onUnreachable: { [session] in session.phoneBecameUnreachable() })
        phoneLink.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView(session: session, pair: { phoneLink.refresh() })
                .task { if !Demo.isActive { session.connect() } }
                .onChange(of: scenePhase) { _, phase in
                    guard !Demo.isActive else { return }
                    if phase == .active { session.connect() }
                    if phase == .background { session.disconnect() }
                }
        }
    }
}

/// `-demo reply|approval|unpaired|offline` seeds the screens for screenshots; it never touches the network.
enum Demo {
    static var scenario: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demo"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    static var isActive: Bool { scenario != nil }

    @MainActor
    static func applyIfRequested(to session: RemoteSession) {
        let approval = RemoteApproval(id: "demo", tool: "run_command", permission: "execute", preview: "swift test --filter KilnRemoteKitTests")
        switch scenario {
        case "reply":
            session.seedDemo(link: .connected(host: "Studio Mac"), reply: "Done. The build passes and all 42 tests are green. I left the Keychain change uncommitted for you to look at.", heard: "Run the tests and tell me how it went", approval: nil)
        case "approval":
            session.seedDemo(link: .connected(host: "Studio Mac"), reply: "I need to run the test suite.", heard: "Run the tests", approval: approval)
            session.reviewing = approval
        case "unpaired":
            session.seedDemo(link: .unpaired, reply: "", heard: "", approval: nil)
        case "offline":
            session.seedDemo(link: .offline("Can't find your Mac"), reply: "", heard: "", approval: nil)
        default:
            break
        }
    }
}
