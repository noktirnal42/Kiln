import Foundation
import KilnRemoteKit

/// The real backend: the app's chat session and approval queue.
@MainActor
public final class ChatRemoteBackend: RemoteBackend {
    private let session: ChatSession
    private let approvals: ApprovalCenter

    public init(session: ChatSession, approvals: ApprovalCenter = .shared) {
        self.session = session
        self.approvals = approvals
    }

    public var hostName: String { Host.current().localizedName ?? "Mac" }

    public func conversations() async -> [RemoteConversation] {
        await session.conversations().prefix(100).map { RemoteConversation(id: $0.id.uuidString, title: $0.title, updatedAt: $0.updatedAt) }
    }

    public func open(_ id: String?) async -> RemoteConversation? {
        if let id {
            guard let uuid = UUID(uuidString: id) else { return nil }
            await session.loadConversation(uuid)
        } else {
            await session.newConversation()
        }
        return current
    }

    public func send(_ text: String) { Task { await session.send(text) } }
    public func transcribe(audio: Data, format: String) async -> String? { await AudioTranscriber.transcribe(audio, format: format) }
    public func stop() { session.stopStreaming() }

    public var current: RemoteConversation? {
        session.conversationID.map { RemoteConversation(id: $0.uuidString, title: session.conversationTitle, updatedAt: Date()) }
    }

    public var messages: [RemoteMessage] {
        session.messages.compactMap { message in
            guard message.role == .user || message.role == .assistant, !message.content.isEmpty else { return nil }
            return RemoteMessage(id: message.id.uuidString, role: message.role == .user ? .user : .assistant,
                                 text: message.content, createdAt: message.createdAt)
        }
    }

    public var isStreaming: Bool { session.isStreaming }
    public var streamingText: String { session.streamingText }

    public var pendingApprovals: [RemoteApproval] {
        approvals.pending.map {
            RemoteApproval(id: $0.id.uuidString, tool: $0.toolName, permission: "\($0.permission)",
                           preview: String(($0.preview.isEmpty ? $0.toolSummary : $0.preview).prefix(600)))
        }
    }

    public func decide(_ approvalID: String, _ decision: RemoteApprovalDecision) {
        guard let id = UUID(uuidString: approvalID) else { return }
        approvals.resolve(id, decision: decision == .allowOnce ? .approveOnce : .deny, via: "remote")
    }
}
