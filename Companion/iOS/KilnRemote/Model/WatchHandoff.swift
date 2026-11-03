import Foundation
import KilnRemoteKit
import Observation
import WatchConnectivity

/// Hands the pairing link to the Kiln Remote watch app over WatchConnectivity (the key never touches a network the
/// Mac listens on). An empty string revokes it. Sent as an application context (latest value wins, delivered when
/// the watch next wakes) and as a queued user-info transfer (a second route if the context is missed). Resent on
/// launch, when pairing changes, and whenever the watch's state or reachability changes.
@MainActor
@Observable
final class WatchHandoff: NSObject {
    static let shared = WatchHandoff()

    private(set) var supported = WCSession.isSupported()
    private(set) var activated = false
    private(set) var watchPaired = false
    private(set) var watchAppInstalled = false
    private(set) var reachable = false
    private(set) var lastSent: Date?
    /// Why the last send was skipped, for the Apple Watch row (never contains the key).
    private(set) var blocked: String?

    @ObservationIgnored private var link = ""
    @ObservationIgnored private var hasPairing = false

    func activate() {
        guard supported else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// `nil` revokes the watch's pairing.
    func publish(_ mac: PairedMac?) {
        hasPairing = mac != nil
        link = mac.map { PairingPayload(hostName: $0.hostName, serviceName: $0.serviceName, key: $0.key, relay: $0.relay, direct: $0.direct).url.absoluteString } ?? ""
        send()
    }

    /// The "Send pairing to watch" button.
    func resend() { send() }

    private func refreshState() {
        let session = WCSession.default
        activated = session.activationState == .activated
        watchPaired = session.isPaired
        watchAppInstalled = session.isWatchAppInstalled
        reachable = session.isReachable
    }

    private func send() {
        guard supported else { blocked = "WatchConnectivity is not available on this device."; return }
        refreshState()
        let session = WCSession.default
        guard activated else { blocked = "Waiting for the watch link to activate."; NSLog("KilnRemote watch: send skipped, session not activated"); return }
        guard watchPaired else { blocked = "No Apple Watch is paired with this iPhone."; NSLog("KilnRemote watch: send skipped, no watch paired"); return }
        // isWatchAppInstalled can stay false for a watch app installed from Xcode, so it is shown but not required.
        let payload = ["kilnPairing": link]
        do { try session.updateApplicationContext(payload) } catch { NSLog("KilnRemote watch: context failed: %@", error.localizedDescription) }
        // Replace any earlier queued transfer so the watch never replays an old (revoked) pairing after a newer one.
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo["kilnPairing"] != nil { transfer.cancel() }
        session.transferUserInfo(payload)
        blocked = hasPairing ? nil : "Pairing removed from the watch."
        lastSent = Date()
        NSLog("KilnRemote watch: sent %@ (reachable=%d)", hasPairing ? "pairing" : "revoke", reachable ? 1 : 0)
    }
}

extension WatchHandoff: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.send() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.send() }
    }
    /// The watch asks for the pairing ("kilnPairingRequest"); answer with it (empty if not paired) and push again.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message["kilnBridge"] as? String == "open" {
            let reply = ReplyBox(replyHandler)
            Task { @MainActor in
                if let host = WatchBridge.shared.connectedHost { reply.send(["kilnBridge": "ready", "host": host]) }
                else { reply.send(["kilnBridge": "error", "reason": "Open Kiln Remote and connect to your Mac"]) }
            }
            return
        }
        guard message["kilnPairingRequest"] != nil else { replyHandler([:]); return }
        let reply = ReplyBox(replyHandler)
        Task { @MainActor in
            reply.send(["kilnPairing": self.link])
            self.send()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let json = message["kilnBridgeCommand"] as? String else { return }
        Task { @MainActor in WatchBridge.shared.receive(Data(json.utf8)) }
    }
    /// Watch commands for the bridge (`RemoteCoding`-encoded `RemoteCommand`).
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in WatchBridge.shared.receive(messageData) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let reply = DataReplyBox(replyHandler)
        Task { @MainActor in
            reply.send(Data())
            WatchBridge.shared.receive(messageData)
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let json = userInfo["kilnBridgeCommand"] as? String else { return }
        let data = Data(json.utf8)
        Task { @MainActor in WatchBridge.shared.receive(data) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.send()
            if WCSession.default.isReachable { WatchBridge.shared.sendSnapshot() }
        }
    }
}

/// WatchConnectivity hands over a non-Sendable reply closure; it is only ever called once, from the main actor.
private final class ReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: [String: Any]) { handler(reply) }
}

private final class DataReplyBox: @unchecked Sendable {
    private let handler: (Data) -> Void
    init(_ handler: @escaping (Data) -> Void) { self.handler = handler }
    func send(_ data: Data) { handler(data) }
}
