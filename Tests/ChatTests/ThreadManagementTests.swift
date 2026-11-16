import Foundation
import SwiftData
import Testing
@testable import Kiln

@MainActor
struct ThreadManagementTests {
    private func makeStore() throws -> ConversationStore {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ConversationStore(container: container)
    }

    @Test func pinAndArchiveArePersistedAndArchivingUnpins() async throws {
        let store = try makeStore()
        let a = try await store.createConversation(title: "A")
        try await store.setPinned(a.id, true)
        #expect(try await store.conversations().first?.isPinned == true)
        try await store.setArchived(a.id, true)
        let after = try #require(try await store.conversations().first)
        #expect(after.isArchived && !after.isPinned)
        try await store.setArchived(a.id, false)
        #expect(try await store.conversations().first?.isArchived == false)
    }

    @Test func searchFindsTitlesAndMessageTextWithoutDuplicates() async throws {
        let store = try makeStore()
        let a = try await store.createConversation(title: "Deploy notes")
        let b = try await store.createConversation(title: "Other")
        _ = try await store.appendMessage(conversationID: a.id, role: .user, content: "how do I deploy")
        _ = try await store.appendMessage(conversationID: b.id, role: .user, content: "the Kubernetes DEPLOY failed")
        _ = try await store.appendMessage(conversationID: b.id, role: .user, content: "unrelated")
        let hits = try await store.search("deploy")
        #expect(Set(hits.map(\.id)) == [a.id, b.id] && hits.count == 2)
        #expect(try await store.search("   ").isEmpty)
        #expect(try await store.search("zzz-none").isEmpty)
    }

    @Test func pinnedThreadsLeadAndArchivedOnesLeaveTheHistory() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func item(_ t: String, days: Double, pinned: Bool = false, archived: Bool = false) -> ConversationSummary {
            ConversationSummary(id: UUID(), title: t, modelID: nil, createdAt: now, updatedAt: now.addingTimeInterval(-days * 86_400), messageCount: 2, isPinned: pinned, isArchived: archived)
        }
        let groups = HistoryGrouping.group([item("today", days: 0), item("old pinned", days: 40, pinned: true), item("gone", days: 0, archived: true)],
                                           openID: nil, now: now, calendar: Calendar(identifier: .gregorian))
        #expect(groups.map(\.bucket) == [.pinned, .today])
        #expect(groups.flatMap(\.items).map(\.title) == ["old pinned", "today"])
    }

    @Test func renamingFromTheSidebarKeepsTheHistoryOrder() async throws {
        let store = try makeStore()
        let a = try await store.createConversation(title: "old title")
        let before = try #require(try await store.conversations().first).updatedAt
        try await store.renameConversation(a.id, to: "new title", touch: false)
        let after = try #require(try await store.conversations().first)
        #expect(after.title == "new title" && after.updatedAt == before)
    }
}
