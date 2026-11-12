import Foundation
import AppKit

/// A person or number to text. Kiln only normalises and checks it; Messages decides whether it can deliver (iMessage or SMS).
public struct MessageRecipient: Equatable, Sendable {
    public enum Kind: Sendable { case phone, email }
    public var original: String
    public var value: String
    public var kind: Kind

    /// Phone numbers keep a leading "+" and digits only; emails are lower-cased. Anything else is refused.
    public static func parse(_ raw: String) -> MessageRecipient? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "&" || $0 == "?" || $0 == "#" || $0 == "," }) else { return nil }
        if text.contains("@") {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !text.contains(" ") else { return nil }
            return MessageRecipient(original: raw, value: text.lowercased(), kind: .email)
        }
        let allowed = Set("0123456789+()-. ")
        guard text.allSatisfy({ allowed.contains($0) }) else { return nil }
        let digits = text.filter(\.isNumber)
        guard (7...15).contains(digits.count), text.dropFirst().allSatisfy({ $0 != "+" }) else { return nil }
        return MessageRecipient(original: raw, value: (text.hasPrefix("+") ? "+" : "") + digits, kind: .phone)
    }

    public static func parseList(_ raw: String) -> (valid: [MessageRecipient], invalid: [String]) {
        var valid: [MessageRecipient] = [], invalid: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let item = String(piece).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if let r = parse(item) { if !valid.contains(where: { $0.value == r.value }) { valid.append(r) } } else { invalid.append(item) }
        }
        return (valid, invalid)
    }
}

/// Opens a prefilled message for the person to review and send. Nothing is sent by Kiln.
public protocol MessageComposer: Sendable {
    func open(recipients: [MessageRecipient], body: String, attachments: [URL]) async -> Bool
}

public struct SystemMessageComposer: MessageComposer {
    public init() {}

    @MainActor private static func present(recipients: [MessageRecipient], body: String, attachments: [URL]) -> Bool {
        guard let service = NSSharingService(named: .composeMessage) else { return false }
        service.recipients = recipients.map(\.value)
        let items: [Any] = [body] + attachments
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }

    public func open(recipients: [MessageRecipient], body: String, attachments: [URL]) async -> Bool {
        await Self.present(recipients: recipients, body: body, attachments: attachments)
    }
}

/// What Kiln can and cannot do with Messages, in words the app and the agent both use.
public enum MessagesCapability {
    public static let statement = """
    Kiln can open a prefilled message in the Messages app for the person to review and send. \
    It cannot read conversations, see replies, send silently, or confirm delivery: macOS has no public API for any of that. \
    Whether a message goes as iMessage or SMS is decided by Messages (SMS needs an iPhone set up for text forwarding).
    """
}
