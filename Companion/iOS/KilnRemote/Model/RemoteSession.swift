import Foundation
import KilnRemoteKit
import Observation

/// Everything the screens show, kept in step with the Mac: connection state, conversations, the open
/// conversation with its streaming reply, and approvals waiting for a decision. Reconnects on its own.
@MainActor
@Observable
final class RemoteSession {
    enum Status: Equatable {
        case unpaired
        case connecting
        case connected
        case reconnecting(String)
        /// The Mac refused our key twice in a row: it was unpaired or its key rotated.
        case needsRepairing
    }

    private(set) var status: Status = .unpaired
    private(set) var mac: PairedMac?
    private(set) var conversations: [RemoteConversation] = []
    private(set) var openConversation: RemoteConversation?
    private(set) var messages: [RemoteMessage] = []
    private(set) var streamingText = ""
    private(set) var isStreaming = false
    private(set) var activity: String?
    private(set) var approvals: [RemoteApproval] = []
    private(set) var lastError: String?
    /// What the connection loop is doing right now ("Trying 192.168.1.5:47900…"), nil when connected or idle.
    private(set) var attemptStatus: String?
    private(set) var hostName: String?

    /// A live assistant message arrived (not history loaded by opening a conversation).
    @ObservationIgnored var onAssistantMessage: (@MainActor (RemoteMessage) -> Void)?
    /// Called when the pairing is saved or removed (the watch hand-off listens).
    @ObservationIgnored var onPairingChanged: (@MainActor (PairedMac?) -> Void)?
    /// Every event from the Mac, before the session applies it (the watch bridge forwards these).
    @ObservationIgnored var onEvent: (@MainActor (RemoteEvent) -> Void)?
    @ObservationIgnored var onApprovalRequested: (@MainActor (RemoteApproval) -> Void)?

    @ObservationIgnored private let store: PairingStoring
    @ObservationIgnored private let endpointOverride: RemoteEndpoint?
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var link: RemoteLink?
    @ObservationIgnored private var cachedAddress: (String, UInt16)?
    @ObservationIgnored private let backoff: [Duration]

    init(store: PairingStoring, endpointOverride: RemoteEndpoint? = nil, deviceName: String,
         backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]) {
        self.store = store
        self.endpointOverride = endpointOverride
        self.deviceName = deviceName
        self.backoff = backoff
        mac = store.load()
        hostName = mac?.hostName
        onPairingChanged?(mac)
        status = mac == nil ? .unpaired : .connecting
    }

    var isConnected: Bool { status == .connected }

    // MARK: pairing and lifecycle

    func pair(with payload: PairingPayload) {
        let paired = PairedMac(hostName: payload.hostName, serviceName: payload.serviceName, key: payload.key, relay: payload.relay, direct: payload.direct)
        do { try store.save(paired) } catch { lastError = error.localizedDescription; return }
        stop()
        resetConversationState()
        mac = paired
        hostName = paired.hostName
        onPairingChanged?(paired)
        lastError = nil
        start()
    }

    func unpair() {
        stop()
        store.clear()
        mac = nil; hostName = nil
        onPairingChanged?(nil)
        resetConversationState()
        status = .unpaired
    }

    func start() {
        guard loop == nil, let mac else { return }
        status = .connecting
        loop = Task { [weak self] in await self?.run(mac) }
    }

    func stop() {
        loop?.cancel(); loop = nil
        link?.close(); link = nil
    }

    /// The app came to the foreground: if the connection dropped while suspended, don't wait out the backoff.
    func resume() {
        guard mac != nil else { return }
        if status == .connected, let link {
            status = .reconnecting("Checking connection to your Mac")
            link.verifyConnection()
        } else if status != .connecting { stop(); start() }
    }

    /// Saves (or clears) the host:port typed in Settings and reconnects.
    func setManualAddress(_ address: String?) {
        guard var mac else { return }
        let trimmed = address?.trimmingCharacters(in: .whitespaces)
        mac.address = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do { try store.save(mac) } catch { lastError = error.localizedDescription; return }
        self.mac = mac
        cachedAddress = nil
        stop(); start()
    }

    // MARK: commands

    func refreshConversations() { link?.send(.listConversations) }
    func open(_ id: String) { link?.send(.openConversation(id: id)) }
    func newConversation() { link?.send(.newConversation) }
    func stopReply() { link?.send(.stop) }
    /// A recording from the Apple Watch: the Mac transcribes it and sends it as a spoken message.
    func sendAudio(_ data: Data, format: String) { link?.send(.sendAudio(data: data, format: format)) }

    // MARK: Apple push

    /// This phone's push token, once Apple has issued it.
    @ObservationIgnored var pushToken: String? { didSet { sendPushRegistration() } }
    /// Allow/Deny answers from a notification that arrived before the connection was up; sent as soon as it is.
    @ObservationIgnored private(set) var pendingDecisions: [(approvalID: String, decision: RemoteApprovalDecision)] = []

    /// Tells the Mac where to alert this phone. Sent on every connect, so a changed token or a reinstalled Mac is covered.
    func sendPushRegistration() {
        guard isConnected, let pushToken else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        link?.send(.registerPush(token: pushToken, environment: environment, topic: Bundle.main.bundleIdentifier ?? "com.kiln.remote"))
    }

    /// An Allow/Deny tapped on a notification. Works with the connection down: it reconnects, then answers.
    func decideFromNotification(_ approvalID: String, _ decision: RemoteApprovalDecision) {
        if isConnected { link?.send(.decide(approvalID: approvalID, decision: decision)); return }
        pendingDecisions.append((approvalID, decision))
        resume()
    }

    private func flushPendingDecisions() {
        let queued = pendingDecisions
        pendingDecisions = []
        for item in queued { link?.send(.decide(approvalID: item.approvalID, decision: item.decision)) }
    }

    func send(_ text: String, spoken: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        link?.send(.send(text: trimmed, spoken: spoken))
    }

    func decide(_ approval: RemoteApproval, _ decision: RemoteApprovalDecision) {
        link?.send(.decide(approvalID: approval.id, decision: decision))
        // The Mac confirms with approvalResolved; hide it now so a second tap cannot send twice.
        approvals.removeAll { $0.id == approval.id }
    }

    // MARK: connection loop

    private func run(_ mac: PairedMac) async {
        var attempt = 0
        var keyRejections = 0
        while !Task.isCancelled {
            if attempt > 0 { status = .reconnecting(lastError ?? "Waiting for your Mac") }
            let outcome = await connectOnce(mac)
            if Task.isCancelled { return }
            if status == .connected { status = .reconnecting(lastError ?? "Connection lost") }   // not "connected" while waiting to retry
            if case .rejected = outcome { keyRejections += 1 } else { keyRejections = 0 }
            if case .welcomed = outcome { attempt = 0 }
            if keyRejections >= 2 { status = .needsRepairing; loop = nil; return }
            let delay = backoff[min(attempt, backoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private enum Outcome { case welcomed, rejected, failed }

    /// How the Mac can be reached, tried in order: addresses typed in Settings or from the pairing link, Bonjour on
    /// this network, then the relay.
    enum Step: Equatable, Sendable {
        case direct(host: String, port: UInt16)
        case bonjour
        case relay(URL)

        var label: String {
            switch self {
            case .direct(let host, let port): "Trying \(host):\(port)…"
            case .bonjour: "Looking for your Mac on this network…"
            case .relay(let url): "Trying the relay \(url.host ?? "")…"
            }
        }
    }

    enum Target: Equatable, Sendable {
        case lan(host: String, port: UInt16)
        case relay(URL)
    }

    private func steps(for mac: PairedMac) -> [Step] {
        var steps: [Step] = []
        func addDirect(_ host: String, _ port: UInt16) {
            let step = Step.direct(host: host, port: port)
            if !steps.contains(step) { steps.append(step) }
        }
        if let endpointOverride {
            switch endpointOverride {
            case .hostPort(let host, let port): addDirect(host, port)
            case .bonjour: steps.append(.bonjour)
            }
        } else {
            if let manual = mac.manualEndpoint { addDirect(manual.host, manual.port) }
            for text in mac.direct { if let parsed = PairedMac.parse(text) { addDirect(parsed.host, parsed.port) } }
            steps.append(.bonjour)
        }
        if let relay = mac.relay { steps.append(.relay(relay)) }
        return steps
    }

    /// Tries each way of reaching the Mac until one gets a reply from it.
    private func connectOnce(_ mac: PairedMac) async -> Outcome {
        var last = Outcome.failed
        let steps = steps(for: mac)
        for step in steps {
            if Task.isCancelled { return .failed }
            attemptStatus = step.label
            guard let target = await resolve(step, mac) else { continue }
            let timeout: TimeInterval = { if case .direct = step { 4 } else { 10 } }()   // a stale direct address should not hold up the rest
            let outcome = await attempt(target, mac, timeout: timeout)
            if Task.isCancelled { return .failed }
            if case .failed = outcome { last = .failed; continue }
            attemptStatus = nil
            return outcome
        }
        attemptStatus = nil
        return last
    }

    private func resolve(_ step: Step, _ mac: PairedMac) async -> Target? {
        switch step {
        case .direct(let host, let port): return .lan(host: host, port: port)
        case .relay(let url): return .relay(url)
        case .bonjour:
            if let cachedAddress { return .lan(host: cachedAddress.0, port: cachedAddress.1) }
            do {
                if case .bonjour(let name)? = endpointOverride {
                    let found = try await BonjourResolver.resolve(serviceName: name, timeout: .seconds(4))
                    return .lan(host: found.0, port: found.1)
                }
                let found = try await BonjourResolver.resolve(serviceName: mac.serviceName, timeout: mac.relay == nil ? .seconds(10) : .seconds(4))
                cachedAddress = found
                return .lan(host: found.0, port: found.1)
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    private func attempt(_ target: Target, _ mac: PairedMac, timeout: TimeInterval) async -> Outcome {
        do {
            let link = RemoteLink(pairingKey: mac.key, deviceName: deviceName, handshakeTimeout: timeout)
            self.link = link
            switch target {
            case .lan(let host, let port):
                NSLog("KilnRemote: connecting to %@:%d", host, Int(port))
                try link.connect(host: host, port: port)
            case .relay(let base):
                guard let url = RelayAddress.url(relay: base, pairingKey: mac.key, role: .device) else { throw LinkError.badURL }
                NSLog("KilnRemote: connecting through the relay %@", base.host ?? "")
                try link.connect(url: url, headers: [("Authorization", RelayAddress.authorizationHeader(pairingKey: mac.key))])
            }
            var handshook = false, welcomed = false
            for await event in link.events {
                switch event {
                case .connected: handshook = true
                case .event(let event):
                    welcomed = true
                    handle(event)
                case .closed(let reason, let sawFrames):
                    self.link = nil
                    NSLog("KilnRemote: closed (%@) handshook=%d frames=%d", reason, handshook ? 1 : 0, sawFrames ? 1 : 0)
                    if !welcomed { lastError = reason; if case .lan = target { cachedAddress = nil } }
                    resetLiveState()
                    if handshook, !sawFrames { return .rejected }
                    return welcomed ? .welcomed : .failed
                }
            }
            return .failed
        } catch {
            NSLog("KilnRemote: connect failed: %@", error.localizedDescription)
            lastError = error.localizedDescription
            return .failed
        }
    }

    // MARK: events

    func handle(_ event: RemoteEvent) {
        onEvent?(event)
        switch event {
        case .welcome(let host, let version):
            hostName = host
            lastError = nil
            if version != kilnRemoteProtocolVersion { lastError = "This Kiln speaks protocol \(version); update Kiln Remote." }
            status = .connected
            sendPushRegistration()
            flushPendingDecisions()
        case .conversations(let list):
            conversations = list.sorted { $0.updatedAt > $1.updatedAt }
        case .opened(let conversation, let history, let streaming):
            openConversation = conversation
            messages = history
            isStreaming = streaming
            streamingText = ""
            activity = nil
        case .delta(let text):
            streamingText += text
        case .message(let message):
            if message.role == .assistant { streamingText = "" }
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            if message.role == .assistant { onAssistantMessage?(message) }
        case .activity(let tool, let status):
            activity = "\(tool): \(status)"
        case .approvalRequested(let approval):
            guard !approvals.contains(where: { $0.id == approval.id }) else { return }
            approvals.append(approval)
            onApprovalRequested?(approval)
        case .approvalResolved(let id):
            approvals.removeAll { $0.id == id }
        case .streaming(let on):
            isStreaming = on
            if !on { activity = nil }
        case .error(let message):
            lastError = message
        case .transcript:
            break   // shown on the watch that sent the recording
        case .pong:
            if case .reconnecting = status { status = .connected }
        }
    }

    private func resetLiveState() {
        isStreaming = false; streamingText = ""; activity = nil; approvals = []
    }

    private func resetConversationState() {
        conversations = []; openConversation = nil; messages = []; lastError = nil
        resetLiveState()
    }
}
