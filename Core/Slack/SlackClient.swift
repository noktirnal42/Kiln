import Foundation

/// A thin client for the Slack Web API (https://slack.com/api). One call per method; the token goes in the Authorization header only.
public struct SlackClient: Sendable {
    let baseURL: URL
    let session: URLSession
    let token: String

    public init(token: String, baseURL: URL = URL(string: "https://slack.com/api/")!, session: URLSession = .shared) {
        self.token = token; self.baseURL = baseURL; self.session = session
    }

    func call(_ method: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Kiln", forHTTPHeaderField: "User-Agent")
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SlackError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw SlackError.rateLimited(retryAfter: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30) }
            if !(200..<300).contains(http.statusCode) { throw SlackError.network("HTTP \(http.statusCode)") }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SlackError.network("Slack sent something that is not JSON.") }
        if object["ok"] as? Bool != true { throw SlackError.api(object["error"] as? String ?? "unknown_error") }
        return object
    }

    // MARK: Parsing

    static func identity(_ o: [String: Any]) -> SlackIdentity {
        SlackIdentity(team: o["team"] as? String ?? "", user: o["user"] as? String ?? "", url: o["url"] as? String ?? "")
    }

    static func conversation(_ c: [String: Any]) -> SlackConversation? {
        guard let id = c["id"] as? String else { return nil }
        let isIM = c["is_im"] as? Bool == true, isMPIM = c["is_mpim"] as? Bool == true, isPrivate = c["is_private"] as? Bool == true
        let kind: SlackConversation.Kind = isIM ? .directMessage : isMPIM ? .groupMessage : isPrivate ? .privateChannel : .channel
        return SlackConversation(id: id, name: c["name"] as? String ?? (c["user"] as? String ?? id), kind: kind, isMember: c["is_member"] as? Bool ?? isIM, userID: isIM ? c["user"] as? String : nil)
    }

    static func message(_ m: [String: Any], names: [String: String]) -> SlackMessage? {
        guard let ts = m["ts"] as? String, let seconds = Double(ts) else { return nil }
        let userID = m["user"] as? String
        let author = userID.flatMap { names[$0] } ?? userID ?? (m["username"] as? String) ?? ((m["bot_id"] as? String) != nil ? "bot" : "unknown")
        return SlackMessage(ts: ts, userID: userID, author: author, text: SlackText.plain(m["text"] as? String ?? "", users: names),
                            date: Date(timeIntervalSince1970: seconds), threadTS: m["thread_ts"] as? String, replyCount: m["reply_count"] as? Int ?? 0)
    }
}
