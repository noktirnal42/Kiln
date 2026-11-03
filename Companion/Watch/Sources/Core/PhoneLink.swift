import Foundation
import KilnRemoteKit
import WatchConnectivity

/// Receives the pairing link from the iPhone. Contract for the iOS app: `updateApplicationContext(["kilnPairing": url])`
/// with the `kiln-remote://pair?...` string; an empty string or missing key revokes the pairing.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let contextKey = "kilnPairing"

    /// Called on the main actor with a new payload, or nil when the phone revoked it.
    private let onChange: @Sendable @MainActor (PairingPayload?) -> Void

    init(onChange: @escaping @Sendable @MainActor (PairingPayload?) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Parses a received context; exposed for tests.
    static func payload(from context: [String: Any]) -> PairingPayload?? {
        guard let value = context[contextKey] as? String else { return .some(nil) }
        if value.isEmpty { return .some(nil) }
        guard let url = URL(string: value), let payload = PairingPayload(url: url) else { return nil }
        return .some(payload)
    }

    private func apply(_ context: [String: Any]) {
        guard let change = Self.payload(from: context) else { return }   // malformed: ignore, keep what we have
        let onChange = onChange
        Task { @MainActor in onChange(change) }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        if activationState == .activated, !context.isEmpty { apply(context) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }
}
