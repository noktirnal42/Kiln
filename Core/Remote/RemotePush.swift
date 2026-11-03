import Foundation
import KilnRemoteKit
import Observation

/// A phone that asked for approval alerts, as the relay needs to address it.
public struct PushDevice: Codable, Equatable, Sendable {
    public var token: String
    public var environment: String
    public var topic: String
    public var addedAt: Date
}

/// Registered phones, kept next to the pairing key (owner-only). Unpairing clears them.
public struct RemotePushStore: Sendable {
    private let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("remote-push.json") }

    public func load() -> [PushDevice] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([PushDevice].self, from: data) else { return [] }
        return list
    }

    public func save(_ devices: [PushDevice]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Raises an Apple push alert for an approval nobody answered quickly, so a phone (and the watch it mirrors to) can be told
/// while its app is closed. The relay holds the push key; this Mac only says which phones to alert. Only a short alert goes
/// through Apple: the tool, its access level and, unless switched off, the start of the command.
@MainActor
@Observable
public final class RemotePushNotifier {
    public private(set) var devices: [PushDevice]
    /// What the last attempt did, for the Remote control card.
    public private(set) var status = ""
    public static let includePreviewKey = "remote.pushIncludesPreview"

    @ObservationIgnored private let store: RemotePushStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let relay: () -> URL?
    @ObservationIgnored private let pairingKey: () -> Data
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var waiting: [String: Task<Void, Never>] = [:]
    /// How long an approval can sit unanswered before the phone is alerted (a connected, open app answers faster).
    @ObservationIgnored public var delay: Duration = .seconds(4)

    public init(store: RemotePushStore, defaults: UserDefaults = .standard, session: URLSession = .shared,
                relay: @escaping () -> URL?, pairingKey: @escaping () -> Data) {
        self.store = store; self.defaults = defaults; self.session = session; self.relay = relay; self.pairingKey = pairingKey
        devices = store.load()
        if !devices.isEmpty { status = "\(devices.count) phone\(devices.count == 1 ? "" : "s") registered for alerts" }
    }

    public var includesPreview: Bool {
        get { defaults.object(forKey: Self.includePreviewKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.includePreviewKey) }
    }

    public func register(token: String, environment: String, topic: String) {
        guard token.range(of: "^[0-9a-fA-F]{32,200}$", options: .regularExpression) != nil, !topic.isEmpty,
              ["sandbox", "production"].contains(environment) else { return }
        devices.removeAll { $0.token == token }
        devices.append(PushDevice(token: token, environment: environment, topic: topic, addedAt: Date()))
        if devices.count > 6 { devices.removeFirst(devices.count - 6) }
        store.save(devices)
        status = "\(devices.count) phone\(devices.count == 1 ? "" : "s") registered for alerts"
    }

    public func forgetAll() { devices = []; store.clear(); status = "" }

    /// An approval appeared. If it is still waiting after `delay`, alert the registered phones.
    public func approvalRaised(_ approval: RemoteApproval, isStillPending: @escaping @MainActor () -> Bool) {
        guard !devices.isEmpty, waiting[approval.id] == nil else { return }
        waiting[approval.id] = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.waiting[approval.id] = nil
            if isStillPending() { await self.send(approval) }
        }
    }

    public func approvalResolved(_ id: String) { waiting.removeValue(forKey: id)?.cancel() }

    /// The request the relay receives. Pure, so it can be tested.
    static func request(relay: URL, pairingKey: Data, devices: [PushDevice], approval: RemoteApproval, includePreview: Bool) -> URLRequest? {
        guard var components = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "ws" ? "http" : "https"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/v1/push/" + RelayAddress.roomID(pairingKey: pairingKey)
        components.query = nil
        guard let url = components.url else { return nil }
        var body = "\(approval.tool) (\(approval.permission))"
        if includePreview, !approval.preview.isEmpty {
            let flat = approval.preview.replacingOccurrences(of: "\n", with: " ")
            body += ": " + String(flat.prefix(80))
        }
        let payload: [String: Any] = [
            "title": "Kiln needs approval", "body": body, "approvalID": approval.id,
            "devices": devices.map { ["token": $0.token, "environment": $0.environment, "topic": $0.topic] },
        ]
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(RelayAddress.authorizationHeader(pairingKey: pairingKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Reasons after which Apple will never deliver to that token again.
    static let deadReasons: Set<String> = ["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic", "TopicDisallowed"]

    private func send(_ approval: RemoteApproval) async {
        guard let relayURL = relay() else { status = "No relay set: alerts need the internet relay"; return }
        guard let request = Self.request(relay: relayURL, pairingKey: pairingKey(), devices: devices, approval: approval, includePreview: includesPreview) else { return }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                struct Result: Decodable { let token: String; let ok: Bool; let reason: String? }
                struct Reply: Decodable { let results: [Result] }
                let results = (try? JSONDecoder().decode(Reply.self, from: data))?.results ?? []
                let dead = Set(results.filter { !$0.ok && Self.deadReasons.contains($0.reason ?? "") }.map(\.token))
                if !dead.isEmpty { devices.removeAll { dead.contains($0.token) }; store.save(devices) }
                let sent = results.filter(\.ok).count
                status = sent > 0 ? "Alert sent to \(sent) phone\(sent == 1 ? "" : "s")" : "Apple refused the alert: " + (results.compactMap(\.reason).first ?? "unknown")
            case 501: status = "The relay has no Apple push key set up"
            case 401: status = "The relay refused the alert request (wrong pairing key?)"
            default: status = "Alert failed (relay answered \(code))"
            }
        } catch {
            status = "Alert failed: \(error.localizedDescription)"
        }
    }
}
