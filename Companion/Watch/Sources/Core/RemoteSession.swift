import Foundation
import KilnRemoteKit
import Observation

/// Everything the watch screens show, and the connection behind it.
@MainActor
@Observable
final class RemoteSession {
    enum Link: Equatable {
        case unpaired, connecting, connected(host: String), offline(String)
    }
    enum Talk: Equatable {
        case idle, listening, thinking, speaking
    }

    /// The second argument reports which step is running ("Looking for Mac…").
    typealias Connector = @Sendable (PairingPayload, @Sendable @MainActor (String) -> Void) async throws -> RemoteChannel

    private(set) var link = Link.unpaired
    /// What the watch is doing or waiting for, in words.
    private(set) var stage = ""
    /// How the connection is carried, once connected ("via iPhone", "on Wi-Fi").
    private(set) var route = ""
    /// State of the link to the iPhone, shown while unpaired.
    var phoneStatus = "Starting phone link"
    private(set) var talk = Talk.idle
    private(set) var latestReply = ""
    private(set) var lastHeard = ""
    private(set) var activity: String?
    private(set) var pendingApprovals: [RemoteApproval] = []
    /// The approval currently shown full screen; cleared when the sheet is dismissed (it stays pending).
    var reviewing: RemoteApproval?

    private let store: PairingStoring
    private let connector: Connector
    private let transcriber: SpeechTranscribing
    private let speaker: Speaking
    private let haptics: Haptics
    private let deviceName: String
    private var client: RemoteChannel?
    private var eventsTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var awaitingSpokenReply = false
    private var conversationOpen = false
    private var buffer = ""

    init(store: PairingStoring, connector: @escaping Connector, transcriber: SpeechTranscribing, speaker: Speaking, haptics: Haptics, deviceName: String = "Apple Watch") {
        self.store = store
        self.connector = connector
        self.transcriber = transcriber
        self.speaker = speaker
        self.haptics = haptics
        self.deviceName = deviceName
        if store.load() == nil { link = .unpaired } else { link = .offline("Not connected") }
    }

    var isConnected: Bool { if case .connected = link { true } else { false } }

    // MARK: Pairing

    /// New payload from the iPhone (or nil when it revoked the pairing).
    func pairingChanged(_ payload: PairingPayload?) {
        if let payload {
            if store.load() == payload { return }
            store.save(payload)
            pairingLog.notice("pairing stored")
            disconnect()
            connect()
        } else {
            store.clear()
            disconnect()
            link = .unpaired
            latestReply = ""
        }
    }

    // MARK: Connection

    func connect() {
        guard let pairing = store.load() else { link = .unpaired; return }
        guard eventsTask == nil else { return }
        link = .connecting
        stage = "Paired. Looking for your Mac…"
        pairingLog.notice("connect: paired, looking for Mac")
        connectionGeneration += 1
        let generation = connectionGeneration
        eventsTask = Task { [weak self] in
            guard let self else { return }
            await self.run(pairing, generation: generation)
            if self.connectionGeneration == generation { self.eventsTask = nil }
        }
    }

    /// Prefer the phone as soon as it becomes reachable, even during a direct-network attempt.
    func phoneBecameReachable() {
        guard !isConnected, store.load() != nil else { return }
        disconnect()
        connect()
    }

    func phoneBecameUnreachable() {
        guard route == "via iPhone", isConnected else { return }
        disconnect()
        link = .offline("iPhone not reachable. Open Kiln Remote on your iPhone.")
    }

    func disconnect() {
        connectionGeneration += 1
        eventsTask?.cancel()
        eventsTask = nil
        let old = client
        client = nil
        conversationOpen = false
        Task { await old?.close() }
        if store.load() != nil { link = .offline("Not connected") }
    }

    private func run(_ pairing: PairingPayload, generation: Int) async {
        do {
            let client = try await connector(pairing) { [weak self] text in
                self?.stage = text
                pairingLog.notice("stage: \(text)")
            }
            guard !Task.isCancelled, generation == connectionGeneration else {
                await client.close()
                return
            }
            route = client.route
            self.client = client
            let events = await client.connect()
            for try await event in events { handle(event) }
            if !Task.isCancelled { link = .offline("Mac disconnected") }
        } catch {
            if !Task.isCancelled {
                pairingLog.error("connect failed: \(String(describing: error))")
                link = .offline(Self.describe(error))
            }
        }
        guard generation == connectionGeneration else { return }
        client = nil
        conversationOpen = false
        if talk == .thinking { talk = .idle }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case RemoteError.attemptsFailed(let tried): tried.isEmpty ? "Can't find your Mac" : "Tried " + tried.joined(separator: "; ")
        case RemoteError.timeout, RemoteError.notFound: "Can't find your Mac"
        case SecureChannelError.authenticationFailed, SecureChannelError.outOfOrder: "Pairing key rejected"
        default: "Can't reach your Mac"
        }
    }

    // MARK: Events

    func handle(_ event: RemoteEvent) {
        switch event {
        case .welcome(let host, _):
            link = .connected(host: host)
            stage = "Connected to \(host) \(route)"
            pairingLog.notice("connected")
            send(.listConversations)
        case .conversations(let list):
            guard !conversationOpen else { break }
            if let latest = list.max(by: { $0.updatedAt < $1.updatedAt }) { send(.openConversation(id: latest.id)) } else { send(.newConversation) }
        case .opened(_, let messages, let streaming):
            conversationOpen = true
            if let last = messages.last(where: { $0.role == .assistant }), latestReply.isEmpty { latestReply = last.text }
            if streaming { talk = .thinking }
        case .delta(let text):
            buffer += text
            latestReply = buffer
            if talk != .speaking { talk = .thinking }
        case .message(let message):
            guard message.role == .assistant else { break }
            finishReply(message.text)
        case .streaming(let on):
            if !on, !buffer.isEmpty { finishReply(buffer) }
            if !on, talk == .thinking { talk = .idle }
            if !on { activity = nil }
        case .activity(let tool, let status):
            activity = "\(tool) \(status)"
        case .approvalRequested(let approval):
            guard !pendingApprovals.contains(where: { $0.id == approval.id }) else { break }
            pendingApprovals.append(approval)
            haptics.play(.approval)
            if reviewing == nil { reviewing = approval }
        case .approvalResolved(let id):
            resolve(id)
        case .error(let text):
            latestReply = text
            talk = .idle
            haptics.play(.failure)
        case .pong:
            break
        }
    }

    private func finishReply(_ text: String) {
        buffer = ""
        latestReply = text
        guard awaitingSpokenReply else { if talk == .thinking { talk = .idle }; return }
        awaitingSpokenReply = false
        talk = .speaking
        speaker.speak(text) { [weak self] in
            guard let self, self.talk == .speaking else { return }
            self.talk = .idle
        }
    }

    private func resolve(_ id: String) {
        pendingApprovals.removeAll { $0.id == id }
        if reviewing?.id == id { reviewing = pendingApprovals.first }
    }

    // MARK: Actions

    /// Tap on the big button: dictate and send, or cut the voice off if it is speaking.
    func talkTapped() async {
        switch talk {
        case .speaking:
            speaker.stop()
            talk = .idle
        case .thinking:
            send(.stop)
            talk = .idle
        case .listening:
            break
        case .idle:
            guard isConnected else { connect(); return }
            talk = .listening
            let text = await transcriber.transcribe()
            guard let text else { talk = .idle; return }
            sendSpoken(text)
        }
    }

    func sendSpoken(_ text: String) {
        lastHeard = text
        awaitingSpokenReply = true
        buffer = ""
        latestReply = ""
        talk = .thinking
        send(.send(text: text, spoken: true))
    }

    func decide(_ approval: RemoteApproval, _ decision: RemoteApprovalDecision) {
        send(.decide(approvalID: approval.id, decision: decision))
    }

    private func send(_ command: RemoteCommand) {
        guard let client else { return }
        Task {
            do { try await client.send(command) }
            catch { handle(.error("Could not send to your iPhone or Mac. Please try again.")) }
        }
    }

    // MARK: Demo

    func seedDemo(link: Link, reply: String, heard: String, approval: RemoteApproval?) {
        self.link = link
        latestReply = reply
        lastHeard = heard
        if let approval { pendingApprovals = [approval] }
    }
}
