import Foundation

/// Reads and sends in the Slack workspace the person connected with their own token. Sending needs an approval that names the exact
/// conversation and text, so an agent cannot post on a person's behalf without them seeing both.
public struct SlackService: Sendable {
    public struct SendApproval: Equatable, Sendable {
        public var channel: String
        public var text: String
        public init(channel: String, text: String) { self.channel = channel; self.text = text }
    }

    let store: SlackTokenStore
    let baseURL: URL
    let session: URLSession
    private let names = NameCache()

    public init(store: SlackTokenStore = SlackTokenStore(), baseURL: URL = URL(string: "https://slack.com/api/")!, session: URLSession = .shared) {
        self.store = store; self.baseURL = baseURL; self.session = session
    }

    private func client() throws -> SlackClient {
        guard let token = store.token(), !token.isEmpty else { throw SlackError.notConnected }
        return SlackClient(token: token, baseURL: baseURL, session: session)
    }

    public var isConnected: Bool { store.token() != nil }

    // MARK: Connecting

    /// Checks the token with Slack before saving it, so a typo is never stored.
    public func connect(token raw: String) async throws -> SlackIdentity {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = SlackTokenStore.shapeProblem(token) { throw SlackError.badToken(problem) }
        let identity = SlackClient.identity(try await SlackClient(token: token, baseURL: baseURL, session: session).call("auth.test"))
        try store.save(token)
        return identity
    }

    public func identity() async throws -> SlackIdentity { SlackClient.identity(try await client().call("auth.test")) }
    public func disconnect() throws { try store.remove() }

    // MARK: Reading

    public func conversations(limit: Int = 200) async throws -> [SlackConversation] {
        let client = try client()
        var found: [SlackConversation] = []
        var cursor: String?
        for _ in 0..<3 {
            var query = ["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": String(min(max(limit, 1), 200))]
            if let cursor { query["cursor"] = cursor }
            let object = try await client.call("conversations.list", query: query)
            found += (object["channels"] as? [[String: Any]] ?? []).compactMap(SlackClient.conversation)
            cursor = (object["response_metadata"] as? [String: Any])?["next_cursor"] as? String
            if cursor?.isEmpty != false || found.count >= limit { break }
        }
        var out: [SlackConversation] = []
        for var conversation in found.prefix(limit) {
            if conversation.kind == .directMessage, let user = conversation.userID { conversation.name = await name(forUser: user, client: client) }
            out.append(conversation)
        }
        return out.sorted { lhs, rhs in
            if (lhs.kind == .directMessage) != (rhs.kind == .directMessage) { return lhs.kind != .directMessage }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// An id (C…, G…, D…) or a channel name with or without the leading `#`.
    public func conversation(matching idOrName: String) async throws -> SlackConversation {
        let wanted = idOrName.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
        guard !wanted.isEmpty else { throw SlackError.noSuchChannel(idOrName) }
        let all = try await conversations()
        if let hit = all.first(where: { $0.id == wanted }) ?? all.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return hit }
        throw SlackError.noSuchChannel(idOrName)
    }

    /// The newest messages of a conversation, oldest first.
    public func messages(inChannel id: String, limit: Int = 30) async throws -> [SlackMessage] {
        let client = try client()
        let object = try await client.call("conversations.history", query: ["channel": id, "limit": String(min(max(limit, 1), 100))])
        let raw = object["messages"] as? [[String: Any]] ?? []
        var table: [String: String] = [:]
        for user in Set(raw.compactMap { $0["user"] as? String }).prefix(40) { table[user] = await name(forUser: user, client: client) }
        return raw.compactMap { SlackClient.message($0, names: table) }.sorted { $0.date < $1.date }
    }

    func name(forUser id: String, client: SlackClient) async -> String {
        if let cached = names.get(id) { return cached }
        let resolved: String
        if let object = try? await client.call("users.info", query: ["user": id]), let user = object["user"] as? [String: Any] {
            let profile = user["profile"] as? [String: Any]
            let display = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            resolved = display ?? (user["real_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (user["name"] as? String) ?? id
        } else { resolved = id }
        names.set(id, resolved)
        return resolved
    }

    // MARK: Sending

    /// Posts to a conversation by id. Returns the new message's timestamp.
    @discardableResult
    public func send(text raw: String, toChannel channel: String, threadTS: String? = nil, approval: SendApproval) async throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SlackError.empty }
        guard text.count <= 4000 else { throw SlackError.tooLong }
        guard !SlackText.hasBroadcastMention(text) else { throw SlackError.broadcastMention }
        guard approval.channel == channel, approval.text == raw else { throw SlackError.notApproved }
        var body: [String: Any] = ["channel": channel, "text": text, "link_names": false, "unfurl_links": false, "unfurl_media": false]
        if let threadTS, !threadTS.isEmpty { body["thread_ts"] = threadTS }
        let object = try await client().call("chat.postMessage", json: body)
        return object["ts"] as? String ?? ""
    }
}

/// Names looked up in one session, so reading a busy channel does not ask Slack about the same person twice.
final class NameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: String] = [:]
    func get(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return table[id] }
    func set(_ id: String, _ name: String) { lock.lock(); defer { lock.unlock() }; table[id] = name }
}
