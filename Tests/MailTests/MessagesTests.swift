import Foundation
import Testing
@testable import Kiln

private final class FakeComposer: MessageComposer, @unchecked Sendable {
    var opened: [(recipients: [MessageRecipient], body: String, attachments: [URL])] = []
    var succeeds = true
    func open(recipients: [MessageRecipient], body: String, attachments: [URL]) async -> Bool {
        opened.append((recipients, body, attachments)); return succeeds
    }
}

@Suite("Messages handoff")
struct MessagesTests {
    private let ctx = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())

    @Test func recipientsAreNormalisedAndHostileInputIsRefused() {
        #expect(MessageRecipient.parse("+1 (555) 010-0199")?.value == "+15550100199")
        #expect(MessageRecipient.parse("555.010.0199")?.value == "5550100199")
        #expect(MessageRecipient.parse(" Ada@Example.COM ")?.value == "ada@example.com")
        #expect(MessageRecipient.parse("ada@example.com")?.kind == .email && MessageRecipient.parse("5550100199")?.kind == .phone)
        for bad in ["", "12345", "1234567890123456", "555&body=x", "5550100199\nx", "a@b", "+1+5550100199", "call me", "x@y.com?subject=1", "a b@c.de"] {
            #expect(MessageRecipient.parse(bad) == nil, "\(bad) should be refused")
        }
    }

    @Test func listsSplitDedupeAndReportInvalidEntries() {
        let r = MessageRecipient.parseList("+15550100199, (555) 010-0199; +15550100199\nada@example.com, nonsense")
        #expect(r.valid.map(\.value) == ["+15550100199", "5550100199", "ada@example.com"])
        #expect(r.invalid == ["nonsense"])
    }

    @Test func composeOpensADraftWithoutSendingAndSaysSo() async throws {
        let fake = FakeComposer()
        let tool = MessagesTool(kind: .compose, composer: fake)
        let out = try await tool.execute(argumentsJSON: #"{"to":"+1 555 010 0199","body":" hello "}"#, context: ctx)
        #expect(out.contains("has not been sent") && out.contains("+15550100199"))
        #expect(fake.opened.count == 1 && fake.opened[0].body == "hello" && fake.opened[0].attachments.isEmpty)
        #expect(tool.spec.permission == .admin)
    }

    @Test func composeValidatesEverythingBeforeOpening() async throws {
        let fake = FakeComposer()
        let tool = MessagesTool(kind: .compose, composer: fake)
        for json in [#"{"to":"","body":"x"}"#, #"{"to":"junk","body":"x"}"#, #"{"to":"+15550100199","body":"  "}"#,
                     #"{"to":"+15550100199","body":"x","attachments":"relative.txt"}"#, #"{"to":"+15550100199","body":"x","attachments":"/no/such/file.txt"}"#,
                     #"{"to":"\#((1...11).map { "+1555010\(1000 + $0)" }.joined(separator: ","))","body":"x"}"#] {
            await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: json, context: ctx) }
        }
        #expect(fake.opened.isEmpty)
        fake.succeeds = false
        let out = try await tool.execute(argumentsJSON: #"{"to":"+15550100199","body":"x"}"#, context: ctx)
        #expect(out.contains("could not open"))
    }

    @Test func statusIsHonestAboutLimits() async throws {
        let text = try await MessagesTool(kind: .status, composer: FakeComposer()).execute(argumentsJSON: "{}", context: ctx)
        #expect(text.contains("Full Disk Access") && text.contains("no public API") && text.contains("cannot be confirmed"))
        #expect(MessagesTool(kind: .status, composer: FakeComposer()).spec.permission == .read)
    }
}
