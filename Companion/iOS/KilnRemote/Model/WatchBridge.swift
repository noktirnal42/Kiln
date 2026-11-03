import Foundation
import KilnRemoteKit
import Observation
import WatchConnectivity

/// Relays watch commands through the iPhone's Mac connection using WatchConnectivity.
/// Commands received while the Mac is disconnected are rejected so they cannot execute later unexpectedly.
/// Events use the kilnBridgeEvent message key; selected events may also be delivered as queued user info.
@MainActor
@Observable
final class WatchBridge {
    static let shared = WatchBridge()
    init() {}

    private(set) var lastWatchActivity: Date?
    private(set) var commandsForwarded = 0

    @ObservationIgnored private var session: RemoteSession?
    @ObservationIgnored private var sendData: @MainActor (Data) -> Void = { WatchBridge.transmit($0) }

    func attach(_ session: RemoteSession) {
        self.session = session
        session.onEvent = { [weak self] event in self?.forward(event) }
    }

    var connectedHost: String? { guard let session, session.isConnected else { return nil }; return session.hostName ?? "Mac" }

    // MARK: watch → phone

    func receive(_ data: Data) {
        guard let command = try? RemoteCoding.decode(RemoteCommand.self, from: data) else { return }
        lastWatchActivity = Date()
        guard let session else { return }
        switch command {
        case .hello:
            sendSnapshot()
        case .ping:
            emit(.pong)
        default:
            if session.isConnected {
                apply(command, on: session)
            } else {
                session.resume()
                emit(.error("Your iPhone is reconnecting to your Mac. Please try again."))
            }
        }
    }

    private func apply(_ command: RemoteCommand, on session: RemoteSession) {
        commandsForwarded += 1
        switch command {
        case .listConversations: session.refreshConversations()
        case .openConversation(let id): session.open(id)
        case .newConversation: session.newConversation()
        case .send(let text, let spoken): session.send(text, spoken: spoken)
        case .stop: session.stopReply()
        case .sendAudio(let data, let format): session.sendAudio(data, format: format)
        case .decide(let approvalID, let decision):
            if let approval = session.approvals.first(where: { $0.id == approvalID }) { session.decide(approval, decision) }
            else { emit(.approvalResolved(approvalID: approvalID)) }
        case .registerPush: break   // push alerts are for the phone; the watch gets them mirrored
        case .hello, .ping: break
        }
    }

    // MARK: phone → watch

    private func forward(_ event: RemoteEvent) {
        emit(event)
    }

    /// Lets tests observe what would go to the watch (WatchConnectivity is not available in unit tests).
    @ObservationIgnored var sink: (@MainActor (RemoteEvent) -> Void)?

    private func emit(_ event: RemoteEvent) {
        sink?(event)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired,
              let data = try? RemoteCoding.encode(event) else { return }
        sendData(data)
        if !WCSession.default.isReachable {
            switch event {
            case .approvalRequested, .approvalResolved, .message:
                WCSession.default.transferUserInfo(["kilnBridgeEvent": String(decoding: data, as: UTF8.self)])
            default: break
            }
        }
    }

    func sendSnapshot() {
        guard let session else { return }
        guard session.isConnected else {
            emit(.error("Your iPhone is not connected to your Mac yet. Open Kiln Remote on the iPhone."))
            session.resume()
            return
        }
        emit(.welcome(hostName: session.hostName ?? "Mac", protocolVersion: kilnRemoteProtocolVersion))
        emit(.conversations(session.conversations))
        if let open = session.openConversation {
            emit(.opened(conversation: open, messages: session.messages, isStreaming: session.isStreaming))
        }
        for approval in session.approvals { emit(.approvalRequested(approval)) }
    }

    nonisolated private static func transmit(_ data: Data) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["kilnBridgeEvent": String(decoding: data, as: UTF8.self)], replyHandler: nil, errorHandler: nil)
    }
}
