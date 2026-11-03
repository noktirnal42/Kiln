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
        link = mac.map { PairingPayload(hostName: $0.hostName, serviceName: $0.serviceName, key: $0.key).url.absoluteString } ?? ""
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
        guard watchAppInstalled else { blocked = "Kiln Remote is not installed on the watch yet."; NSLog("KilnRemote watch: send skipped, watch app not installed"); return }
        let payload = ["kilnPairing": link]
        do { try session.updateApplicationContext(payload) } catch { NSLog("KilnRemote watch: context failed: %@", error.localizedDescription) }
        // Replace any earlier queued transfer so the watch never replays an old (revoked) pairing after a newer one.
        for transfer in session.outstandingUserInfoTransfers { transfer.cancel() }
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
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.send() }
    }
}
