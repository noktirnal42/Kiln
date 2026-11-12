import Foundation
import AppKit

/// Sends through the Messages app with Apple Events (Automation). macOS asks the person once to let Kiln control Messages.
/// Apple documents no other way to send. Delivery cannot be confirmed here: a successful call means Messages accepted the message.
public protocol MessagesSending: Sendable {
    func send(body: String, toHandle handle: String) async throws
    func send(body: String, toChatGUID guid: String) async throws
}

public enum MessagesSendError: Error, Equatable, LocalizedError {
    case automationDenied, failed(String), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .automationDenied: "Kiln is not allowed to control Messages. Turn it on in System Settings, Privacy & Security, Automation."
        case .failed(let m): "Messages could not send: \(m)"
        case .invalid(let m): m
        }
    }
}

public enum AppleScriptText {
    /// A double-quoted AppleScript string literal that cannot be broken out of: backslash and quote are escaped and line breaks become `linefeed`.
    public static func literal(_ value: String) -> String {
        var parts: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": current += "\\\\"
            case "\"": current += "\\\""
            case "\n", "\r": parts.append("\"" + current + "\""); current = ""; parts.append("linefeed")
            default: current.unicodeScalars.append(scalar)
            }
        }
        parts.append("\"" + current + "\"")
        return parts.joined(separator: " & ")
    }
}

public struct SystemMessagesSender: MessagesSending {
    public init() {}

    static func script(body: String, handle: String) -> String {
        """
        tell application "Messages"
            set theService to 1st service whose service type = iMessage
            set theBuddy to buddy \(AppleScriptText.literal(handle)) of theService
            send \(AppleScriptText.literal(body)) to theBuddy
        end tell
        """
    }

    static func script(body: String, chatGUID: String) -> String {
        """
        tell application "Messages"
            send \(AppleScriptText.literal(body)) to chat id \(AppleScriptText.literal(chatGUID))
        end tell
        """
    }

    @MainActor private static func run(_ source: String) throws {
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            if number == -1743 { throw MessagesSendError.automationDenied }
            throw MessagesSendError.failed((error[NSAppleScript.errorMessage] as? String) ?? "unknown error")
        }
    }

    public func send(body: String, toHandle handle: String) async throws {
        guard MessageRecipient.parse(handle) != nil else { throw MessagesSendError.invalid("Not a phone number or email.") }
        let source = Self.script(body: body, handle: MessageRecipient.parse(handle)?.value ?? handle)
        try await MainActor.run { try Self.run(source) }
    }

    public func send(body: String, toChatGUID guid: String) async throws {
        guard !guid.isEmpty, !guid.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { throw MessagesSendError.invalid("Bad conversation id.") }
        let source = Self.script(body: body, chatGUID: guid)
        try await MainActor.run { try Self.run(source) }
    }
}

/// Reading and sending together. Sending needs an approval that names the exact conversation and text, so an agent cannot send on a person's behalf without them seeing both.
public struct MessagesService: Sendable {
    public struct SendApproval: Equatable, Sendable {
        public var destination: String      // handle or chat guid
        public var body: String
        public init(destination: String, body: String) { self.destination = destination; self.body = body }
    }
    public enum ServiceError: Error, Equatable, LocalizedError {
        case notApproved, empty, tooLong
        public var errorDescription: String? {
            switch self {
            case .notApproved: "The send was not approved for this conversation and text."
            case .empty: "The message is empty."
            case .tooLong: "The message is too long (limit 4000 characters)."
            }
        }
    }

    public let database: MessagesDatabase
    let sender: any MessagesSending

    public init(database: MessagesDatabase = MessagesDatabase(), sender: any MessagesSending = SystemMessagesSender()) { self.database = database; self.sender = sender }

    public func chats(limit: Int = 40) async throws -> [MessageChat] { try await Task.detached { [database] in try database.chats(limit: limit) }.value }
    public func messages(inChat id: Int64, limit: Int = 60) async throws -> [ChatMessage2] { try await Task.detached { [database] in try database.messages(inChat: id, limit: limit) }.value }
    public func messages(after rowID: Int64) async throws -> [ChatMessage2] { try await Task.detached { [database] in try database.messages(after: rowID) }.value }
    public func latestRowID() async throws -> Int64 { try await Task.detached { [database] in try database.latestRowID() }.value }

    public func send(body: String, toHandle handle: String, approval: SendApproval) async throws {
        let text = try Self.checked(body)
        guard approval.destination == handle, approval.body == body else { throw ServiceError.notApproved }
        try await sender.send(body: text, toHandle: handle)
    }

    public func send(body: String, toChat chat: MessageChat, approval: SendApproval) async throws {
        let text = try Self.checked(body)
        guard approval.destination == chat.guid, approval.body == body else { throw ServiceError.notApproved }
        if chat.isGroup || !chat.guid.contains(";-;") { try await sender.send(body: text, toChatGUID: chat.guid) }
        else { try await sender.send(body: text, toHandle: String(chat.guid.split(separator: ";").last ?? "")) }
    }

    static func checked(_ body: String) throws -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServiceError.empty }
        guard text.count <= 4000 else { throw ServiceError.tooLong }
        return text
    }
}
