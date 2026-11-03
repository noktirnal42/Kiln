import Foundation
import KilnRemoteKit

/// Remembered "host:port" typed on the watch, tried before anything else.
enum ManualAddress {
    private static let key = "manualMacAddress"
    static var value: String? {
        get { UserDefaults.standard.string(forKey: key).flatMap { isHostPort($0) ? $0 : nil } }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func isHostPort(_ text: String) -> Bool {
        guard let colon = text.lastIndex(of: ":"), colon != text.startIndex, let port = UInt16(text[text.index(after: colon)...]), port > 0 else { return false }
        return !text.contains("/") && !text.contains(" ")
    }
}

/// Finds the Mac, in order: addresses from the pairing link (and a manual one), Bonjour, then the relay. Each attempt
/// reports itself, and a failure is kept so the screen can say exactly what was tried.
enum MacConnector {
    typealias Progress = @Sendable @MainActor (String) -> Void

    /// The relay first when there is one (over URLSession, which watchOS routes through the iPhone even while it is locked,
    /// and which works from any network), then the iPhone bridge, then the Mac directly.
    static func channel(_ pairing: PairingPayload, bridge: PhoneBridge?, manual: String? = ManualAddress.value, progress: Progress) async throws -> RemoteChannel {
        var failures: [String] = []
        if let relay = pairing.relay, let url = RelayAddress.url(relay: relay, pairingKey: pairing.key, role: .device) {
            await progress("Connecting through the relay…")
            let transport = URLSessionTransport(url: url, headers: ["Authorization": RelayAddress.authorizationHeader(pairingKey: pairing.key)])
            do {
                try await transport.start(timeout: 10)
                return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Apple Watch")
            } catch {
                transport.close()
                failures.append("Relay: " + describe(error))
            }
        }
        if let bridge {
            if bridge.isReachable {
                await progress("Connecting via iPhone…")
                do {
                    _ = try await bridge.open()
                    return bridge
                } catch {
                    failures.append("iPhone: " + describe(error))
                }
            } else {
                failures.append("iPhone not reachable")
            }
        }
        do {
            let transport = try await connect(pairing, manual: manual, progress: progress)
            return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Apple Watch")
        } catch RemoteError.attemptsFailed(let direct) {
            throw RemoteError.attemptsFailed(failures + direct)
        }
    }

    static func connect(_ pairing: PairingPayload, manual: String? = ManualAddress.value, progress: Progress) async throws -> RemoteTransport {
        var failures: [String] = []
        var addresses = manual.map { [$0] } ?? []
        for address in pairing.direct where !addresses.contains(address) { addresses.append(address) }

        for address in addresses {
            await progress("Trying \(address)…")
            guard let url = URL(string: "ws://\(address)") else { continue }
            do { return try await open(url, timeout: 4) } catch { failures.append("\(address): \(describe(error))") }
        }

        await progress("Looking for your Mac on Wi-Fi…")
        do {
            let url = try await BonjourResolver.resolve(serviceName: pairing.serviceName, timeout: 6)
            await progress("Found your Mac. Connecting…")
            return try await open(url, timeout: 6)
        } catch { failures.append("Bonjour: \(describe(error))") }

        throw RemoteError.attemptsFailed(failures)
    }

    private static func open(_ url: URL, headers: [String: String] = [:], timeout: Double) async throws -> RemoteTransport {
        let transport = NWTransport(url: url, headers: headers)
        do {
            try await transport.start(timeout: timeout)
            return transport
        } catch {
            transport.close()
            throw error
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case RemoteError.timeout: "timed out"
        case RemoteError.notFound: "not found"
        case RemoteError.closed: "closed"
        case RemoteError.bridge(let reason): reason
        default: (error as NSError).localizedDescription.lowercased()
        }
    }
}
