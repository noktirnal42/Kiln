import Foundation

/// Detects and redacts likely secrets before text is sent to any model.
///
/// This is heuristic, not cryptographic. It exists to keep obvious keys and
/// tokens out of a prompt by default; it is not a guarantee that no secret
/// can ever leak, and any UI built on it must say so.
public enum SecretRedactor {
    public struct Match: Equatable, Sendable {
        public let kind: String
        public let text: String

        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    static let patterns: [(kind: String, regex: NSRegularExpression)] = {
        let specs: [(String, String)] = [
            ("AWS Access Key", #"AKIA[0-9A-Z]{16}"#),
            ("AWS Secret Key", #"(?i)aws_secret_access_key\s*[:=]\s*['\"]?[A-Za-z0-9/+=]{40}['\"]?"#),
            ("GitHub Token", #"gh[pousr]_[A-Za-z0-9]{36,255}"#),
            ("OpenAI-style Key", #"sk-[A-Za-z0-9]{20,}"#),
            ("Anthropic-style Key", #"sk-ant-[A-Za-z0-9\-_]{20,}"#),
            ("Slack Token", #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
            ("Private Key Block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            ("Generic Bearer Token", #"(?i)bearer\s+[A-Za-z0-9\-_.]{20,}"#),
            ("Generic API Key Assignment", #"(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*['\"][^'\"]{8,}['\"]"#),
            ("JWT", #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#),
        ]
        return specs.compactMap { kind, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (kind, regex)
        }
    }()

    /// Filenames whose contents should never be sent to a model without
    /// explicit, per-file approval.
    public static func isSensitiveFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        let exactNames: Set<String> = [".env", ".npmrc", ".pypirc", "credentials", "id_rsa", "id_ed25519"]
        if exactNames.contains(lower) { return true }
        if lower.hasPrefix(".env.") { return true }
        if lower.hasSuffix(".pem") || lower.hasSuffix(".key") || lower.hasSuffix(".p12") || lower.hasSuffix(".pfx") { return true }
        if lower.contains("secret") || lower.contains("credential") { return true }
        return false
    }

    public static func findMatches(in text: String) -> [Match] {
        var results: [Match] = []
        let range = NSRange(location: 0, length: (text as NSString).length)
        for (kind, regex) in patterns {
            for m in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(m.range, in: text) else { continue }
                results.append(Match(kind: kind, text: String(text[swiftRange])))
            }
        }
        return results
    }

    /// Replaces every match with a placeholder, and returns the redacted
    /// text plus how many replacements were made.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        let matches = findMatches(in: text)
        guard !matches.isEmpty else { return (text, 0) }
        // Replace longest-first so a specific pattern is not partially
        // consumed by a generic one.
        let sorted = matches.sorted { $0.text.count > $1.text.count }
        var result = text
        var count = 0
        for match in sorted {
            guard let range = result.range(of: match.text) else { continue }
            result.replaceSubrange(range, with: "[REDACTED:\(match.kind)]")
            count += 1
        }
        return (result, count)
    }

    public static func containsSecret(_ text: String) -> Bool {
        !findMatches(in: text).isEmpty
    }
}
