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
    private(set) var hostName: String?

    /// A live assistant message arrived (not history loaded by opening a conversation).
    @ObservationIgnored var onAssistantMessage: (@MainActor (RemoteMessage) -> Void)?
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
        status = mac == nil ? .unpaired : .connecting
    }

    var isConnected: Bool { status == .connected }

    // MARK: pairing and lifecycle

    func pair(with payload: PairingPayload) {
        let paired = PairedMac(hostName: payload.hostName, serviceName: payload.serviceName, key: payload.key)
        do { try store.save(paired) } catch { lastError = error.localizedDescription; return }
        stop()
        resetConversationState()
        mac = paired
        hostName = paired.hostName
        lastError = nil
        start()
    }

    func unpair() {
        stop()
        store.clear()
        mac = nil; hostName = nil
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
        if status != .connected, status != .connecting { stop(); start() }
    }

    // MARK: commands

    func refreshConversations() { link?.send(.listConversations) }
    func open(_ id: String) { link?.send(.openConversation(id: id)) }
    func newConversation() { link?.send(.newConversation) }
    func stopReply() { link?.send(.stop) }

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
            if case .rejected = outcome { keyRejections += 1 } else { keyRejections = 0 }
            if case .welcomed = outcome { attempt = 0 }
            if keyRejections >= 2 { status = .needsRepairing; loop = nil; return }
            let delay = backoff[min(attempt, backoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private enum Outcome { case welcomed, rejected, failed }

    private func connectOnce(_ mac: PairedMac) async -> Outcome {
        do {
            let (host, port) = try await address(for: mac)
            NSLog("KilnRemote: connecting to %@:%d", host, Int(port))
            let link = RemoteLink(pairingKey: mac.key, deviceName: deviceName)
            self.link = link
            try link.connect(host: host, port: port)
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
                    if !welcomed { lastError = reason }
                    resetLiveState()
                    if handshook, !sawFrames { return .rejected }
                    return welcomed ? .welcomed : .failed
                }
            }
            return .failed
        } catch {
            cachedAddress = nil
            NSLog("KilnRemote: connect failed: %@", error.localizedDescription)
            lastError = error.localizedDescription
            return .failed
        }
    }

    private func address(for mac: PairedMac) async throws -> (String, UInt16) {
        if let endpointOverride {
            switch endpointOverride {
            case .hostPort(let host, let port): return (host, port)
            case .bonjour(let name): return try await BonjourResolver.resolve(serviceName: name)
            }
        }
        if let cachedAddress { return cachedAddress }
        let found = try await BonjourResolver.resolve(serviceName: mac.serviceName)
        cachedAddress = found
        return found
    }

    // MARK: events

    func handle(_ event: RemoteEvent) {
        switch event {
        case .welcome(let host, let version):
            hostName = host
            lastError = nil
            if version != kilnRemoteProtocolVersion { lastError = "This Kiln speaks protocol \(version); update Kiln Remote." }
            status = .connected
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
        case .pong:
            break
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
