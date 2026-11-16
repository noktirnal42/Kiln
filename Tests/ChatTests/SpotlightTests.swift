import Foundation
import SwiftData
import Testing
@testable import Kiln

private actor RecordingIndexer: SpotlightIndexing {
    var indexed: [SpotlightEntry] = [], removed: [String] = [], clears = 0
    func index(_ entries: [SpotlightEntry]) { indexed += entries }
    func remove(identifiers: [String]) { removed += identifiers }
    func removeAll() { clears += 1 }
}

@Suite("Spotlight")
struct SpotlightTests {
    private func summary(_ title: String, id: UUID = UUID()) -> ConversationSummary {
        ConversationSummary(id: id, title: title, modelID: nil, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2), messageCount: 2)
    }
    private func message(_ role: ChatMessage.Role, _ text: String) -> MessageSnapshot { MessageSnapshot(id: UUID(), role: role, content: text, createdAt: Date()) }

    @Test func offIndexesNothingAndPlaceholderTitlesAreSkipped() {
        #expect(ConversationSpotlight.entry(for: summary("Plan the trip"), messages: [], mode: .off) == nil)
        #expect(ConversationSpotlight.entry(for: summary(ConversationTitle.placeholder), messages: [], mode: .titles) == nil)
        #expect(ConversationSpotlight.entry(for: summary("  "), messages: [], mode: .full) == nil)
    }

    @Test func titlesOnlyNeverIncludesWhatWasSaid() throws {
        let e = try #require(ConversationSpotlight.entry(for: summary("Plan the trip"), messages: [message(.user, "my secret plan")], mode: .titles))
        #expect(e.title == "Plan the trip" && e.text.isEmpty && !e.summary.contains("secret plan"))
    }

    @Test func fullModeRedactsSecretsBoundsTextAndSkipsToolMessages() throws {
        let key = "sk-" + String(repeating: "a", count: 40)
        let big = String(repeating: "word ", count: 10_000)
        let msgs = [message(.user, "use key \(key) please"), message(.tool, "TOOL OUTPUT HIDDEN"), message(.assistant, "Done.\n" + big)]
        let e = try #require(ConversationSpotlight.entry(for: summary("Keys"), messages: msgs, mode: .full))
        #expect(!e.text.contains(key) && !e.summary.contains(key))
        #expect(!e.text.contains("TOOL OUTPUT HIDDEN"))
        #expect(e.text.count <= ConversationSpotlight.textLimit && e.summary.count <= ConversationSpotlight.summaryLimit && !e.summary.contains("\n"))
    }

    @Test func identifiersRoundTripAndForeignOnesAreRejected() {
        let id = UUID()
        #expect(ConversationSpotlight.conversationID(from: ConversationSpotlight.identifier(for: id)) == id)
        #expect(ConversationSpotlight.conversationID(from: "something.else") == nil)
        #expect(ConversationSpotlight.conversationID(from: "kiln.conversation.not-a-uuid") == nil)
    }

    @Test func defaultModeIsOffAndUnknownValuesFallBackToOff() throws {
        let d = try #require(TestDefaults.suite("kiln.test.spotlight"))
        d.removePersistentDomain(forName: "kiln.test.spotlight")
        #expect(SpotlightMode.current(d) == .off)
        d.set("full", forKey: SpotlightMode.defaultsKey); #expect(SpotlightMode.current(d) == .full)
        d.set("everything", forKey: SpotlightMode.defaultsKey); #expect(SpotlightMode.current(d) == .off)
    }

    @Test func syncFollowsTheModeAndCleansUp() async throws {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let store = ConversationStore(container: container)
        let convo = try await store.createConversation(title: "Trip plan")
        _ = try await store.appendMessage(conversationID: convo.id, role: .user, content: "Where should we go?")
        _ = try await store.appendMessage(conversationID: convo.id, role: .assistant, content: "Try Lisbon in spring.")
        _ = try await store.createConversation(title: ConversationTitle.placeholder)

        let defaults = try #require(TestDefaults.suite("kiln.test.spotlightsync"))
        defaults.removePersistentDomain(forName: "kiln.test.spotlightsync")
        let indexer = RecordingIndexer()
        let sync = SpotlightSync(store: store, indexer: indexer, suiteName: "kiln.test.spotlightsync")

        await sync.rebuild()                                  // Off: clears, indexes nothing
        let clears = await indexer.clears, none = await indexer.indexed
        #expect(clears == 1 && none.isEmpty)
        await sync.update(convo.id)
        let stillNone = await indexer.indexed
        #expect(stillNone.isEmpty)

        defaults.set("titles", forKey: SpotlightMode.defaultsKey)
        await sync.rebuild()
        var indexed = await indexer.indexed
        #expect(indexed.count == 1 && indexed[0].title == "Trip plan" && indexed[0].text.isEmpty)

        defaults.set("full", forKey: SpotlightMode.defaultsKey)
        await sync.update(convo.id)
        indexed = await indexer.indexed
        #expect(indexed.last?.text.contains("Lisbon") == true)

        await sync.remove(convo.id)
        let removed = await indexer.removed
        #expect(removed == [ConversationSpotlight.identifier(for: convo.id)])
    }
}
