import Foundation
import SQLite3
import Testing
@testable import Kiln

private func makeFixtureDB() throws -> String {
    let path = NSTemporaryDirectory() + "kiln-chatdb-\(UUID().uuidString).db"
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
    run("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, style INTEGER)")
    run("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
    run("CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER, date INTEGER, cache_has_attachments INTEGER)")
    run("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
    run("INSERT INTO handle VALUES (1, '+15550100199'), (2, 'ada@example.com')")
    run("INSERT INTO chat VALUES (1, 'iMessage;-;+15550100199', '+15550100199', '', 45), (2, 'iMessage;+;chat777', 'chat777', 'Book club', 43), (3, 'SMS;-;+1999', '+1999', '', 45)")
    let t0: Int64 = 600_000_000 * 1_000_000_000   // nanoseconds since 2001
    run("INSERT INTO message VALUES (1, 'hello there', NULL, 0, 1, \(t0), 0), (2, 'hi back', NULL, 1, 0, \(t0 + 1_000_000_000), 0), (3, 'club tonight?', NULL, 0, 2, \(t0 + 5_000_000_000), 1)")
    run("INSERT INTO chat_message_join VALUES (1,1),(1,2),(2,3)")
    // A message whose text lives only in attributedBody.
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO message VALUES (4, NULL, ?1, 0, 1, \(t0 + 9_000_000_000), 0)", -1, &stmt, nil)
    let blob = AttributedBodyFixtures.archive("typed in a new Mac")
    _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    sqlite3_step(stmt); sqlite3_finalize(stmt)
    run("INSERT INTO chat_message_join VALUES (1,4)")
    return path
}

enum AttributedBodyFixtures {
    /// A minimal imitation of the typedstream archive Messages writes: class names, then 0x2B and a length-prefixed UTF-8 string.
    static func archive(_ text: String) -> Data {
        var d = Data([0x04, 0x0B]) + Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84])
        d += Data("NSAttributedString".utf8) + Data([0x00, 0x84, 0x84]) + Data("NSObject".utf8) + Data([0x00, 0x85, 0x92, 0x84, 0x84, 0x84])
        d += Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B])
        let utf8 = Array(text.utf8)
        if utf8.count < 0x80 { d.append(UInt8(utf8.count)) }
        else if utf8.count < 0x10000 { d += Data([0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]) }
        else { d += Data([0x82] + (0..<4).map { UInt8((utf8.count >> (8 * $0)) & 0xFF) }) }
        return d + Data(utf8) + Data([0x86, 0x84, 0x02]) + Data("iI".utf8)
    }
}

private final class FakeSender: MessagesSending, @unchecked Sendable {
    var sent: [(dest: String, body: String, isChat: Bool)] = []
    func send(body: String, toHandle handle: String) async throws { sent.append((handle, body, false)) }
    func send(body: String, toChatGUID guid: String) async throws { sent.append((guid, body, true)) }
}

@Suite("Messages integration")
struct MessagesIntegrationTests {
    private let ctx = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())

    @Test func decoderReadsShortMediumAndLongStringsAndRejectsGarbage() {
        #expect(AttributedBodyDecoder.text(from: AttributedBodyFixtures.archive("hi")) == "hi")
        let medium = String(repeating: "é", count: 200)
        #expect(AttributedBodyDecoder.text(from: AttributedBodyFixtures.archive(medium)) == medium)
        let long = String(repeating: "a", count: 70_000)
        #expect(AttributedBodyDecoder.text(from: AttributedBodyFixtures.archive(long))?.count == 70_000)
        #expect(AttributedBodyDecoder.text(from: Data([1, 2, 3])) == nil)
        #expect(AttributedBodyDecoder.text(from: Data("NSString".utf8)) == nil)
        // A length that runs past the end of the data is refused rather than read out of bounds.
        var cut = AttributedBodyFixtures.archive("hello world")
        cut.removeLast(cut.count - (cut.firstIndex(of: 0x2B)! + 5))
        #expect(AttributedBodyDecoder.text(from: cut) == nil)
    }

    @Test func databaseListsChatsReadsThreadsAndFindsNewMessages() throws {
        let path = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = MessagesDatabase(path: path)
        let chats = try db.chats()
        #expect(chats.map(\.id) == [1, 2])                      // chat 3 has no messages; newest conversation first would be chat 1 (attributedBody message is latest)
        #expect(chats[0].lastText == "typed in a new Mac" && chats[0].title == "+15550100199" && !chats[0].isGroup)
        #expect(chats[1].title == "Book club" && chats[1].isGroup)
        let thread = try db.messages(inChat: 1)
        #expect(thread.map(\.text) == ["hello there", "hi back", "typed in a new Mac"])
        #expect(thread[0].sender == "+15550100199" && !thread[0].isFromMe && thread[1].isFromMe && thread[1].sender.isEmpty)
        #expect(try db.messages(inChat: 2).first?.hasAttachment == true)
        #expect(try db.latestRowID() == 4)
        #expect(try db.messages(after: 2).map(\.id) == [3, 4])
        #expect(try db.messages(after: 4).isEmpty)
        #expect(thread[0].date != nil && thread[0].date! < thread[1].date!)
    }

    @Test func missingOrUnreadableDatabasesGiveTheRightExplanation() throws {
        #expect(throws: MessagesDatabaseError.missing) { try MessagesDatabase(path: "/no/such/chat.db").chats() }
        let junk = NSTemporaryDirectory() + "kiln-not-a-db-\(UUID().uuidString)"
        try Data("not sqlite".utf8).write(to: URL(fileURLWithPath: junk))
        defer { try? FileManager.default.removeItem(atPath: junk) }
        #expect(throws: MessagesDatabaseError.self) { try MessagesDatabase(path: junk).chats() }
    }

    @Test func appleScriptTextCannotBeBrokenOutOf() {
        #expect(AppleScriptText.literal("hi") == "\"hi\"")
        #expect(AppleScriptText.literal("a\"b\\c") == "\"a\\\"b\\\\c\"")
        #expect(AppleScriptText.literal("one\ntwo") == "\"one\" & linefeed & \"two\"")
        let evil = AppleScriptText.literal("x\" & (do shell script \"id\") & \"")
        #expect(evil == "\"x\\\" & (do shell script \\\"id\\\") & \\\"\"")
        let script = SystemMessagesSender.script(body: "yo\" & (do shell script \"id\")", handle: "+15550100199")
        #expect(script.contains("send \"yo\\\" & (do shell script \\\"id\\\")\" to theBuddy"))
    }

    @Test func sendingNeedsAMatchingApprovalAndRoutesGroupsByChatID() async throws {
        let path = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fake = FakeSender()
        let service = MessagesService(database: MessagesDatabase(path: path), sender: fake)
        let chats = try await service.chats()
        let direct = try #require(chats.first { $0.id == 1 }), group = try #require(chats.first { $0.id == 2 })
        await #expect(throws: MessagesService.ServiceError.notApproved) { try await service.send(body: "hi", toChat: direct, approval: .init(destination: direct.guid, body: "different")) }
        await #expect(throws: MessagesService.ServiceError.notApproved) { try await service.send(body: "hi", toChat: direct, approval: .init(destination: group.guid, body: "hi")) }
        await #expect(throws: MessagesService.ServiceError.empty) { try await service.send(body: "  ", toChat: direct, approval: .init(destination: direct.guid, body: "  ")) }
        await #expect(throws: MessagesService.ServiceError.tooLong) { let b = String(repeating: "x", count: 4001); try await service.send(body: b, toChat: direct, approval: .init(destination: direct.guid, body: b)) }
        #expect(fake.sent.isEmpty)
        try await service.send(body: "hi", toChat: direct, approval: .init(destination: direct.guid, body: "hi"))
        try await service.send(body: "yo", toChat: group, approval: .init(destination: group.guid, body: "yo"))
        #expect(fake.sent[0] == (direct.guid, "hi", true) && fake.sent[1] == ("iMessage;+;chat777", "yo", true), "every existing chat is sent to by its own id")
    }

    private final class ChatRouteFails: MessagesSending, @unchecked Sendable {
        var sent: [(dest: String, isChat: Bool)] = []
        let error: MessagesSendError
        init(_ error: MessagesSendError) { self.error = error }
        func send(body: String, toHandle handle: String) async throws { sent.append((handle, false)) }
        func send(body: String, toChatGUID guid: String) async throws { throw error }
    }

    private func chat(_ guid: String, group: Bool = false) -> MessageChat {
        MessageChat(id: 9, guid: guid, title: "x", isGroup: group, lastDate: nil, lastText: "")
    }

    @Test func aOneToOneIMessageChatFallsBackToTheHandleButSMSAndGroupsDoNot() async throws {
        let path = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        func service(_ sender: ChatRouteFails) -> MessagesService { MessagesService(database: MessagesDatabase(path: path), sender: sender) }
        let iMessage = chat("iMessage;-;+15550100199")
        let failing = ChatRouteFails(.failed("no chat"))
        try await service(failing).send(body: "hi", toChat: iMessage, approval: .init(destination: iMessage.guid, body: "hi"))
        #expect(failing.sent.count == 1 && failing.sent[0] == ("+15550100199", false))

        let sms = chat("SMS;-;+15550100199")
        let smsSender = ChatRouteFails(.failed("no chat"))
        await #expect(throws: MessagesSendError.failed("no chat")) { try await service(smsSender).send(body: "hi", toChat: sms, approval: .init(destination: sms.guid, body: "hi")) }
        #expect(smsSender.sent.isEmpty, "an SMS chat is never sent through the iMessage service")

        let group = chat("iMessage;+;chat777", group: true)
        let groupSender = ChatRouteFails(.failed("no chat"))
        await #expect(throws: MessagesSendError.failed("no chat")) { try await service(groupSender).send(body: "hi", toChat: group, approval: .init(destination: group.guid, body: "hi")) }
        #expect(groupSender.sent.isEmpty)

        let denied = ChatRouteFails(.automationDenied)
        await #expect(throws: MessagesSendError.automationDenied) { try await service(denied).send(body: "hi", toChat: iMessage, approval: .init(destination: iMessage.guid, body: "hi")) }
        #expect(denied.sent.isEmpty, "a permission refusal is reported, not retried another way")
    }

    @Test func toolsLabelUntrustedTextAndGateSending() async throws {
        let path = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fake = FakeSender()
        let service = MessagesService(database: MessagesDatabase(path: path), sender: fake)
        let list = try await MessagesChatTool(kind: .conversations, service: service).execute(argumentsJSON: "{}", context: ctx)
        #expect(list.hasPrefix(MessagesChatTool.untrusted) && list.contains("Book club (group)"))
        let read = try await MessagesChatTool(kind: .read, service: service).execute(argumentsJSON: #"{"chat_id":1}"#, context: ctx)
        #expect(read.contains("| me | hi back") && read.contains("typed in a new Mac"))
        #expect(try await MessagesChatTool(kind: .send, service: service).execute(argumentsJSON: #"{"chat_id":1,"body":"on my way"}"#, context: ctx).contains("Delivery is not confirmed"))
        #expect(try await MessagesChatTool(kind: .send, service: service).execute(argumentsJSON: #"{"to":"ada@example.com","body":"hey"}"#, context: ctx).contains("ada@example.com"))
        #expect(fake.sent.count == 2 && fake.sent[1].dest == "ada@example.com")
        for bad in [#"{"chat_id":99,"body":"x"}"#, #"{"to":"junk","body":"x"}"#, #"{"body":"x"}"#, #"{"chat_id":1,"body":" "}"#] {
            await #expect(throws: (any Error).self) { _ = try await MessagesChatTool(kind: .send, service: service).execute(argumentsJSON: bad, context: ctx) }
        }
        let tiers = Dictionary(uniqueKeysWithValues: MessagesChatTool.Kind.allCases.map { ($0, MessagesChatTool(kind: $0, service: service).spec.permission) })
        #expect(tiers[.conversations] == .execute && tiers[.read] == .execute && tiers[.send] == .admin)
    }
}
