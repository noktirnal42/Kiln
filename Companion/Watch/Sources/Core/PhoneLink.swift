import Foundation
import KilnRemoteKit
import OSLog
import WatchConnectivity

/// Milestones go to the unified log and to stdout (visible with `devicectl ... launch --console`). Never the key.
struct PairingLog: Sendable {
    private let logger = Logger(subsystem: "com.kiln.remote.watchkitapp", category: "pairing")
    func notice(_ message: String) { logger.notice("\(message, privacy: .public)"); print("[pairing] \(message)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)"); print("[pairing] ERROR \(message)") }
}
let pairingLog = PairingLog()

/// Receives the pairing link from the iPhone. Contract for the iOS app: `updateApplicationContext(["kilnPairing": url])`
/// (also accepted through `transferUserInfo`) with the `kiln-remote://pair?...` string; an empty string revokes it.
/// The watch asks for it with `sendMessage(["kilnPairingRequest": true])` when the phone is reachable.
/// Logs milestones only, never the link or key.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let contextKey = "kilnPairing"
    static let requestKey = "kilnPairingRequest"

    /// Called on the main actor with a new payload, or nil when the phone revoked it.
    private let onChange: @Sendable @MainActor (PairingPayload?) -> Void
    /// Plain-language state of the phone link, for the screen.
    private let onStatus: @Sendable @MainActor (String) -> Void

    init(onChange: @escaping @Sendable @MainActor (PairingPayload?) -> Void, onStatus: @escaping @Sendable @MainActor (String) -> Void) {
        self.onChange = onChange
        self.onStatus = onStatus
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { report("Phone link not supported"); return }
        pairingLog.notice("WCSession activating")
        report("Starting phone link")
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The Pair button: re-read what the phone already sent and ask it to send again.
    func refresh() {
        let session = WCSession.default
        pairingLog.notice("refresh: state \(session.activationState.rawValue) reachable \(session.isReachable) companionInstalled \(session.isCompanionAppInstalled)")
        guard session.activationState == .activated else { activate(); return }
        apply(session.receivedApplicationContext, source: "context")
        if session.isReachable {
            report("Asking iPhone for pairing")
            session.sendMessage([Self.requestKey: true], replyHandler: { [weak self] reply in self?.apply(reply, source: "reply") }, errorHandler: { error in
                pairingLog.error("pairing request failed: \(error.localizedDescription)")
            })
        } else {
            report(session.isCompanionAppInstalled ? "iPhone not reachable. Open Kiln Remote on it." : "Kiln Remote is not installed on the paired iPhone")
        }
    }

    /// Parses a received context; exposed for tests. Outer nil: not a pairing message at all.
    static func payload(from context: [String: Any]) -> PairingPayload?? {
        guard let value = context[contextKey] as? String else { return .some(nil) }
        if value.isEmpty { return .some(nil) }
        guard let url = URL(string: value), let payload = PairingPayload(url: url) else { return nil }
        return .some(payload)
    }

    private func report(_ text: String) {
        let onStatus = onStatus
        Task { @MainActor in onStatus(text) }
    }

    private func apply(_ message: [String: Any], source: String) {
        guard message[Self.contextKey] != nil else {
            pairingLog.notice("\(source): no pairing yet")
            report("iPhone has not sent pairing yet. Open Kiln Remote and pair it with your Mac.")
            return
        }
        guard let change = Self.payload(from: message) else {
            pairingLog.error("\(source): malformed pairing ignored")
            report("iPhone sent a pairing the watch could not read")
            return
        }
        pairingLog.notice("\(source): pairing \(change == nil ? "revoked" : "received")")
        let onChange = onChange
        Task { @MainActor in onChange(change) }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        pairingLog.notice("activated: state \(activationState.rawValue) error \(error?.localizedDescription ?? "none") companionInstalled \(session.isCompanionAppInstalled)")
        guard activationState == .activated else { report("Phone link failed to start"); return }
        refresh()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        pairingLog.notice("reachability: \(session.isReachable)")
        if session.isReachable { refresh() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext, source: "context")
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        apply(userInfo, source: "userInfo")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        apply(message, source: "message")
    }
}
