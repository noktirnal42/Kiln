import Foundation
import KilnRemoteKit

/// What the remote needs from the app: conversations, the open conversation's state, and pending approvals.
/// `ChatSession` and `ApprovalCenter` sit behind it so the bridge is tested without a model.
@MainActor
public protocol RemoteBackend: AnyObject {
    var hostName: String { get }
    func conversations() async -> [RemoteConversation]
    /// Opens a conversation (a new one when `id` is nil) and returns it.
    func open(_ id: String?) async -> RemoteConversation?
    func send(_ text: String)
    /// Text heard in a short recording, or nil when nothing could be made out (or speech permission is missing).
    func transcribe(audio: Data, format: String) async -> String?
    func stop()
    var current: RemoteConversation? { get }
    /// Saved messages of the open conversation, oldest first.
    var messages: [RemoteMessage] { get }
    var isStreaming: Bool { get }
    var streamingText: String { get }
    var pendingApprovals: [RemoteApproval] { get }
    func decide(_ approvalID: String, _ decision: RemoteApprovalDecision)
}

/// Turns commands into events and watches the backend for changes worth pushing: reply text as it streams,
/// finished messages, approvals appearing and resolving. One bridge serves every connected device.
@MainActor
public final class RemoteBridge {
    private let backend: any RemoteBackend
    private var seenMessageIDs: Set<String> = []
    private var openID: String?
    private var streamedCount = 0
    private var wasStreaming = false
    private var announcedApprovals: Set<String> = []
    private var pollTask: Task<Void, Never>?
    /// Receives every pushed event; the server fans it out to connected devices.
    public var emit: (RemoteEvent) -> Void = { _ in }

    public init(backend: any RemoteBackend) { self.backend = backend }

    public func start(interval: Duration = .milliseconds(150)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                for event in self.poll() { self.emit(event) }
            }
        }
    }

    public func stop() { pollTask?.cancel(); pollTask = nil }

    /// Answers one command. Pushes that follow (streaming, approvals) come from `poll`.
    public func handle(_ command: RemoteCommand) async -> [RemoteEvent] {
        switch command {
        case .hello(_, let version):
            guard version == kilnRemoteProtocolVersion else {
                return [.error("This Kiln speaks remote protocol \(kilnRemoteProtocolVersion); update the companion app (it sent \(version)).")]
            }
            var events: [RemoteEvent] = [.welcome(hostName: backend.hostName, protocolVersion: kilnRemoteProtocolVersion),
                                         .conversations(await backend.conversations())]
            events += openedEvents()
            events += backend.pendingApprovals.map { announce($0) }
            return events
        case .listConversations:
            return [.conversations(await backend.conversations())]
        case .openConversation(let id):
            guard await backend.open(id) != nil else { return [.error("That conversation could not be opened.")] }
            resetTracking()
            return openedEvents()
        case .newConversation:
            guard await backend.open(nil) != nil else { return [.error("A new conversation could not be started.")] }
            resetTracking()
            return openedEvents() + [.conversations(await backend.conversations())]
        case .send(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            guard !backend.isStreaming else { return [.error("Kiln is still answering. Stop it first or wait.")] }
            backend.send(trimmed)
            return []
        case .sendAudio(let data, let format):
            guard !backend.isStreaming else { return [.error("Kiln is still answering. Stop it first or wait.")] }
            guard let text = await backend.transcribe(audio: data, format: format), !text.isEmpty else {
                return [.error("I didn't catch that. Try again, or allow Speech Recognition for Kiln on the Mac.")]
            }
            backend.send(text)
            return [.transcript(text)]
        case .stop:
            backend.stop()
            return []
        case .decide(let approvalID, let decision):
            guard backend.pendingApprovals.contains(where: { $0.id == approvalID }) else { return [.approvalResolved(approvalID: approvalID)] }
            backend.decide(approvalID, decision)
            announcedApprovals.remove(approvalID)
            return [.approvalResolved(approvalID: approvalID)]
        case .ping:
            return [.pong]
        }
    }

    /// Differences since the last call, as events to push.
    public func poll() -> [RemoteEvent] {
        var events: [RemoteEvent] = []
        if backend.current?.id != openID {
            resetTracking()
            events += openedEvents()
        }
        let streaming = backend.isStreaming
        if streaming != wasStreaming { events.append(.streaming(streaming)); wasStreaming = streaming }
        let text = backend.streamingText
        if streaming, text.count > streamedCount {
            events.append(.delta(text: String(text.dropFirst(streamedCount))))
            streamedCount = text.count
        }
        if !streaming { streamedCount = 0 }
        for message in backend.messages where !seenMessageIDs.contains(message.id) {
            seenMessageIDs.insert(message.id)
            events.append(.message(message))
        }
        let pending = backend.pendingApprovals
        for request in pending where !announcedApprovals.contains(request.id) { events.append(announce(request)) }
        for id in announcedApprovals where !pending.contains(where: { $0.id == id }) {
            announcedApprovals.remove(id)
            events.append(.approvalResolved(approvalID: id))
        }
        return events
    }

    private func announce(_ request: RemoteApproval) -> RemoteEvent {
        announcedApprovals.insert(request.id)
        return .approvalRequested(request)
    }

    private func resetTracking() {
        openID = backend.current?.id
        seenMessageIDs = Set(backend.messages.map(\.id))
        streamedCount = 0
        wasStreaming = backend.isStreaming
    }

    private func openedEvents() -> [RemoteEvent] {
        guard let conversation = backend.current else { return [] }
        resetTracking()
        return [.opened(conversation: conversation, messages: backend.messages, isStreaming: backend.isStreaming)]
    }
}
