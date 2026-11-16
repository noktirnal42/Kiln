import Foundation

/// Groups messages into conversations the way mail clients do: by References and In-Reply-To, falling back to the normalised subject.
public enum MailThreading {
    public struct Thread: Equatable, Sendable {
        public var subject: String
        public var messages: [MailMessage]
        public var latest: Date? { messages.compactMap(\.date).max() }
    }

    /// "Re: Fwd: Hello" -> "hello"
    public static func normalizedSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        let regex = try! NSRegularExpression(pattern: #"^\s*((re|fwd?|aw|sv)\s*(\[\d+\])?\s*:\s*)+"#, options: .caseInsensitive)
        s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func threads(_ messages: [MailMessage]) -> [Thread] {
        var parent = Array(0..<messages.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        var byID: [String: Int] = [:]
        for (i, m) in messages.enumerated() { if let id = m.messageID { byID[id] = i } }
        var bySubject: [String: Int] = [:]
        for (i, m) in messages.enumerated() {
            for ref in m.references + (m.inReplyTo.map { [$0] } ?? []) { if let j = byID[ref] { union(i, j) } }
        }
        // Subject fallback only joins messages that carry no reference headers of their own and are replies or the original.
        for (i, m) in messages.enumerated() where m.references.isEmpty && m.inReplyTo == nil {
            let key = normalizedSubject(m.subject)
            guard !key.isEmpty else { continue }
            if let j = bySubject[key] { union(i, j) } else { bySubject[key] = i }
        }
        for (i, m) in messages.enumerated() where !(m.references.isEmpty && m.inReplyTo == nil) && byID[m.references.last ?? m.inReplyTo ?? ""] == nil {
            if let j = bySubject[normalizedSubject(m.subject)] { union(i, j) }
        }
        var groups: [Int: [Int]] = [:]
        for i in messages.indices { groups[find(i), default: []].append(i) }
        return groups.values.map { indices in
            let sorted = indices.map { messages[$0] }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            return Thread(subject: sorted.first.map { stripPrefixes($0.subject) } ?? "", messages: sorted)
        }.sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
    }

    private static func stripPrefixes(_ subject: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"^\s*((re|fwd?|aw|sv)\s*(\[\d+\])?\s*:\s*)+"#, options: .caseInsensitive)
        return regex.stringByReplacingMatches(in: subject, range: NSRange(location: 0, length: (subject as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
}
