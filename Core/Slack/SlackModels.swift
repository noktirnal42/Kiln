import Foundation

public struct SlackIdentity: Equatable, Sendable {
    public var team: String
    public var user: String
    public var url: String
}

public struct SlackConversation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case channel, privateChannel, directMessage, groupMessage }
    public var id: String
    public var name: String
    public var kind: Kind
    public var isMember: Bool
    /// For a direct message, the other person's user id.
    public var userID: String?
}

public struct SlackMessage: Identifiable, Equatable, Sendable {
    public var ts: String
    public var userID: String?
    /// The author's name when it could be looked up, otherwise the id (or "bot").
    public var author: String
    /// Slack's markup turned into plain text.
    public var text: String
    public var date: Date
    public var threadTS: String?
    public var replyCount: Int
    public var id: String { ts }
    public var isReply: Bool { threadTS != nil && threadTS != ts }
}

public enum SlackError: Error, Equatable, LocalizedError {
    case notConnected
    case badToken(String)
    case api(String)
    case rateLimited(retryAfter: Int)
    case network(String)
    case noSuchChannel(String)
    case notApproved, empty, tooLong, broadcastMention

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Slack is not connected. Open the Slack activity and paste a token."
        case .badToken(let m): m
        case .api(let code): Self.explain(code)
        case .rateLimited(let s): "Slack asked Kiln to wait \(s) seconds before trying again."
        case .network(let m): "Could not reach Slack: \(m)"
        case .noSuchChannel(let n): "No Slack conversation matches \"\(n)\"."
        case .notApproved: "The send was not approved for this conversation and text."
        case .empty: "The message is empty."
        case .tooLong: "The message is too long (limit 4000 characters)."
        case .broadcastMention: "Kiln does not send messages that notify a whole channel (@channel, @here, @everyone or a user group). Remove the mention."
        }
    }

    static func explain(_ code: String) -> String {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "account_inactive", "token_expired": "Slack rejected the token (\(code)). Paste a fresh one."
        case "missing_scope": "The Slack token lacks a permission this needs. Add the scope in the Slack app settings and reinstall it."
        case "not_in_channel": "The Slack app is not in that channel. Invite it there (/invite) or use a user token."
        case "channel_not_found": "Slack cannot find that conversation, or the token cannot see it."
        case "is_archived": "That channel is archived."
        case "msg_too_long": "Slack says the message is too long."
        case "restricted_action", "no_permission": "Slack does not allow this token to do that here."
        case "ratelimited": "Slack is rate limiting Kiln. Try again in a minute."
        default: "Slack answered with an error: \(code)."
        }
    }
}
