import Foundation
import Testing
@testable import Kiln

private struct FakeSource: ContactSource {
    var level: ContactsAccess
    var people: [ContactEntry]
    func access() -> ContactsAccess { level }
    func requestAccess() async -> Bool { level == .authorized }
    func allContacts() throws -> [ContactEntry] { people }
}

@Suite("Contacts")
struct ContactsTests {
    private let people = [
        ContactEntry(id: "1", name: "Ada Lovelace", organization: "Analytical Engines", emails: ["ada@example.com"], phones: ["+1 555 0100"]),
        ContactEntry(id: "2", name: "Adam Smith", emails: ["adam@wealth.org"]),
        ContactEntry(id: "3", name: "Grace Hopper", organization: "Navy", emails: ["grace@navy.mil"]),
        ContactEntry(id: "4", name: "Lovelace Fan", emails: ["fan@example.com"]),
    ]

    @Test func rankingPutsPrefixesBeforeWordsBeforeEmailsBeforeSubstrings() {
        let r = ContactsService.rank("ad", in: people)
        #expect(r.map(\.id) == ["1", "2"])                                          // both prefix the name; ties sort by name
        #expect(ContactsService.rank("love", in: people).map(\.id) == ["4", "1"])   // name prefix before word prefix
        #expect(ContactsService.rank("navy", in: people).map(\.id) == ["3"])        // organization
        #expect(ContactsService.rank("wealth", in: people).map(\.id) == ["2"])      // inside an email
        #expect(ContactsService.rank("  ", in: people).isEmpty)
        #expect(ContactsService.rank("a", in: people, limit: 2).count == 2)
    }

    @Test func wordPrefixBeatsSubstring() {
        let list = [ContactEntry(id: "a", name: "Zoe Marsh"), ContactEntry(id: "b", name: "Marsha Quinn")]
        #expect(ContactsService.rank("mars", in: list).map(\.id) == ["b", "a"])   // "Marsha Quinn" starts with it; "Zoe Marsh" only has a word that does
    }

    @Test func searchReturnsNothingWithoutAccessAndNeverPrompts() async throws {
        for level in [ContactsAccess.denied, .restricted, .notDetermined] {
            let service = ContactsService(source: FakeSource(level: level, people: people))
            #expect(try await service.search("ada").isEmpty)
        }
        #expect(try await ContactsService(source: FakeSource(level: .authorized, people: people)).search("grace").map(\.name) == ["Grace Hopper"])
    }

    @Test func toolsExplainAccessAndFormatResults() async throws {
        let ctx = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())
        let allowed = ContactsService(source: FakeSource(level: .authorized, people: people))
        let out = try await ContactsTool(kind: .search, service: allowed).execute(argumentsJSON: #"{"query":"ada"}"#, context: ctx)
        #expect(out.contains("Ada Lovelace | Analytical Engines | ada@example.com | +1 555 0100"))
        #expect(try await ContactsTool(kind: .search, service: allowed).execute(argumentsJSON: #"{"query":"zzz"}"#, context: ctx).contains("No contacts match"))
        let denied = ContactsService(source: FakeSource(level: .denied, people: people))
        #expect(try await ContactsTool(kind: .search, service: denied).execute(argumentsJSON: #"{"query":"ada"}"#, context: ctx).contains("System Settings"))
        #expect(try await ContactsTool(kind: .status, service: denied).execute(argumentsJSON: "{}", context: ctx) == ContactsAccess.denied.explanation)
        await #expect(throws: (any Error).self) { try await ContactsTool(kind: .search, service: allowed).execute(argumentsJSON: "{}", context: ctx) }
        #expect(ContactsTool(kind: .search, service: allowed).spec.permission == .read)
    }
}
