import Foundation
import Testing
@testable import Kiln

struct ConversationTitleTests {
    @Test func theFirstLineBecomesTheTitle() {
        #expect(ConversationTitle.make(from: "Fix the failing tests\nand run them again") == "Fix the failing tests")
        #expect(ConversationTitle.make(from: "   spaced    out   words  ") == "spaced out words")
    }

    @Test func longMessagesAreCutAtAWordWithAnEllipsis() {
        let title = ConversationTitle.make(from: "Please review the authentication middleware for session fixation problems and report", limit: 40)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 41)
        #expect(!title.dropLast().hasSuffix(" "))
        #expect("Please review the authentication middleware for".hasPrefix(String(title.dropLast())))
    }

    @Test func emptyOrMarkupOnlyMessagesKeepThePlaceholder() {
        #expect(ConversationTitle.make(from: "") == ConversationTitle.placeholder)
        #expect(ConversationTitle.make(from: "   \n  ") == ConversationTitle.placeholder)
        #expect(ConversationTitle.make(from: "###") == ConversationTitle.placeholder)
    }
}

struct HistoryGroupingTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func summary(_ title: String, daysAgo: Double, messages: Int = 2, id: UUID = UUID()) -> ConversationSummary {
        ConversationSummary(id: id, title: title, modelID: nil, createdAt: now,
                            updatedAt: now.addingTimeInterval(-daysAgo * 86_400), messageCount: messages)
    }

    @Test func conversationsFallIntoTodayYesterdayWeekAndOlder() {
        let groups = HistoryGrouping.group([
            summary("old", daysAgo: 30), summary("week", daysAgo: 4), summary("yesterday", daysAgo: 1), summary("today", daysAgo: 0),
        ], openID: nil, now: now, calendar: calendar)
        #expect(groups.map(\.bucket) == [.today, .yesterday, .previousWeek, .older])
        #expect(groups.flatMap(\.items).map(\.title) == ["today", "yesterday", "week", "old"])
    }

    @Test func emptyGroupsAreOmittedAndNewestComesFirstWithinAGroup() {
        let groups = HistoryGrouping.group([summary("a", daysAgo: 0.2), summary("b", daysAgo: 0.1)], openID: nil, now: now, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.title) == ["b", "a"])
    }

    @Test func aConversationWithNoMessagesIsHiddenUnlessItIsOpen() {
        let open = UUID()
        let items = [summary("blank", daysAgo: 0, messages: 0), summary("current", daysAgo: 0, messages: 0, id: open)]
        #expect(HistoryGrouping.group(items, openID: nil, now: now, calendar: calendar).isEmpty)
        #expect(HistoryGrouping.group(items, openID: open, now: now, calendar: calendar).flatMap(\.items).map(\.title) == ["current"])
    }
}

struct WorkspaceStoreTests {
    private func store() throws -> (WorkspaceStore, UserDefaults, URL) {
        let suite = "kiln.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (WorkspaceStore(defaults: defaults), defaults, dir)
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aRememberedProjectIsCurrentAndSurvivesARelaunch() throws {
        let (store, defaults, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try folder("alpha", in: root)
        try store.remember(project)
        #expect(store.recents().map(\.name) == ["alpha"])

        let relaunched = WorkspaceStore(defaults: defaults)
        #expect(relaunched.current?.resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path)
    }

    @Test func recentsAreNewestFirstCappedAndDeduplicated() throws {
        let (store, _, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        for index in 0..<10 {
            try store.remember(try folder("p\(index)", in: root), now: start.addingTimeInterval(Double(index)))
        }
        #expect(store.recents().count == WorkspaceStore.maxRecents)
        #expect(store.recents().first?.name == "p9")

        try store.remember(try folder("p5", in: root), now: start.addingTimeInterval(100))
        #expect(store.recents().first?.name == "p5")
        #expect(store.recents().filter { $0.name == "p5" }.count == 1)
    }

    @Test func workingWithoutAProjectAndForgettingOneBothClearCurrent() throws {
        let (store, _, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try folder("alpha", in: root)
        try store.remember(project)
        store.clearCurrent()
        #expect(store.current == nil)
        #expect(store.recents().count == 1, "clearing the current project keeps it in the recents")

        try store.remember(project)
        store.forget(path: project.path)
        #expect(store.current == nil && store.recents().isEmpty)
    }
}

struct StarterPromptTests {
    @Test func everyPlaceOffersSomethingToAsk() {
        for activity in Activity.allCases {
            #expect(!StarterPrompts.prompts(for: activity, hasProject: true).isEmpty, "\(activity.title) has no starter prompts")
            #expect(!StarterPrompts.prompts(for: activity, hasProject: false).isEmpty)
        }
    }

    @Test func projectPromptsAppearOnlyWhenThereIsAProject() {
        let with = StarterPrompts.prompts(for: .agent, hasProject: true).map(\.title)
        let without = StarterPrompts.prompts(for: .agent, hasProject: false).map(\.title)
        #expect(with.contains("Fix the failing tests"))
        #expect(!without.contains("Fix the failing tests"))
    }

    @Test func eachToolSuggestsItsOwnKindOfQuestion() {
        #expect(StarterPrompts.prompts(for: .analyze, hasProject: false).first?.title == "Analyze a binary")
        #expect(StarterPrompts.prompts(for: .lab, hasProject: false).map(\.title).contains("What can my Mac run?"))
        #expect(Set(StarterPrompts.prompts(for: .lab, hasProject: true).map(\.id)).count == StarterPrompts.prompts(for: .lab, hasProject: true).count)
    }
}
