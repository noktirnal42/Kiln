import Foundation
import Testing
@testable import Kiln

@MainActor
struct WorkstationTests {
    private func command(_ id: String, _ title: String, subtitle: String = "", keywords: [String] = []) -> WorkstationCommand {
        WorkstationCommand(id: id, title: title, subtitle: subtitle, symbol: "circle", keywords: keywords, run: {})
    }

    /// A throwaway preferences suite, so nothing here touches the real app's settings.
    private func isolatedDefaults() -> UserDefaults {
        let name = "kiln.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Activities

    @Test func everyActivityHasAUniqueShortcutInRailOrder() {
        let keys = Activity.allCases.map { String($0.shortcutKey) }
        #expect(keys == ["1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(Set(keys).count == Activity.allCases.count)
    }

    @Test func moduleBackedActivitiesPointAtRealModules() {
        #expect(Activity.agent.moduleIdentifier == ChatModule.identifier)
        #expect(Activity.analyze.moduleIdentifier == REModule.identifier)
        #expect(Activity.lab.moduleIdentifier == ModelLabModule.identifier)
        #expect(Activity.browser.moduleIdentifier == BrowserModule.identifier)
        for activity in [Activity.home, .swarm, .develop, .audit] { #expect(activity.moduleIdentifier == nil) }
    }

    @Test func everyActivityHasTitleSymbolAndSummary() {
        for activity in Activity.allCases {
            #expect(!activity.title.isEmpty && !activity.symbol.isEmpty && !activity.summary.isEmpty)
        }
    }

    @Test func theDockIsNeverShownBesideTheAgentActivityItself() {
        let model = WorkstationModel(defaults: isolatedDefaults())
        model.dockVisible = true
        model.selected = .analyze
        #expect(model.dockShown)
        model.selected = .agent
        #expect(!model.dockShown, "it would be a second copy of the same conversation")
        model.dockVisible = false
        model.selected = .lab
        #expect(!model.dockShown)
    }

    // MARK: Ranking

    @Test func emptyQueryKeepsOriginalOrder() {
        let list = [command("a", "Zebra"), command("b", "Apple")]
        #expect(CommandRanking.rank(list, query: "").map(\.id) == ["a", "b"])
        #expect(CommandRanking.rank(list, query: "   ").map(\.id) == ["a", "b"])
    }

    @Test func exactBeatsPrefixBeatsWordPrefixBeatsSubstringBeatsFuzzy() {
        let list = [
            command("fuzzy", "Take extra mini nail"),   // t-e-r-m-i-n-a-l as a scattered subsequence only
            command("substring", "Subterminal"),         // contains it, but not at a word start
            command("word", "Go to Terminal"),           // a word starts with it
            command("prefix", "Terminal tools"),         // the title starts with it
            command("exact", "terminal"),
        ]
        #expect(CommandRanking.rank(list, query: "terminal").map(\.id) == ["exact", "prefix", "word", "substring", "fuzzy"])
    }

    @Test func nonMatchesAreExcluded() {
        let list = [command("a", "Go to Home"), command("b", "New conversation")]
        #expect(CommandRanking.rank(list, query: "zzz").isEmpty)
    }

    @Test func fuzzySubsequenceMatches() {
        let list = [command("a", "Show approval queue")]
        #expect(CommandRanking.rank(list, query: "sapq").map(\.id) == ["a"])
    }

    @Test func keywordsAndSubtitlesMatchBelowTitles() {
        let list = [
            command("sub", "Alpha", subtitle: "involves grants"),
            command("kw", "Beta", keywords: ["grants"]),
            command("title", "Grants overview"),
        ]
        let ranked = CommandRanking.rank(list, query: "grants").map(\.id)
        #expect(ranked == ["title", "kw", "sub"])
    }

    @Test func tiesKeepTheirOriginalOrder() {
        let list = [command("1", "Open one"), command("2", "Open two"), command("3", "Open three")]
        #expect(CommandRanking.rank(list, query: "open").map(\.id) == ["1", "2", "3"])
    }

    @Test func theDockPreferenceIsRememberedAndDefaultsToVisible() {
        let defaults = isolatedDefaults()
        #expect(WorkstationModel(defaults: defaults).dockVisible, "visible until the user hides it")
        let first = WorkstationModel(defaults: defaults)
        first.dockVisible = false
        #expect(!WorkstationModel(defaults: defaults).dockVisible)
    }

    @Test func rankingIsCaseInsensitive() {
        #expect(CommandRanking.rank([command("a", "Go to Audit")], query: "AUDIT").count == 1)
    }

    // MARK: Status

    @Test func approvalsOutrankStreamingWhenDecidingTheAgentState() {
        #expect(WorkstationStatus.agentState(isStreaming: true, pendingApprovals: 1) == .awaitingApproval)
        #expect(WorkstationStatus.agentState(isStreaming: true, pendingApprovals: 0) == .running)
        #expect(WorkstationStatus.agentState(isStreaming: false, pendingApprovals: 0) == .idle)
    }

    @Test func agentLabelsAreDistinct() {
        let labels = [WorkstationStatus.AgentState.idle, .running, .awaitingApproval].map(WorkstationStatus.agentLabel)
        #expect(Set(labels).count == 3)
    }

    @Test func lostAuditEntriesAreAProblemNotAStatistic() {
        #expect(WorkstationStatus.audit(chainConfigured: true, droppedEntries: 0).level == .ok)
        let lost = WorkstationStatus.audit(chainConfigured: true, droppedEntries: 3)
        #expect(lost.level == .problem)
        #expect(lost.text.contains("3"))
        #expect(WorkstationStatus.audit(chainConfigured: false, droppedEntries: 0).level == .warning)
    }

    // MARK: Commands

    @Test func theModelOffersAGoToCommandForEveryActivityAndTheCoreActions() throws {
        let model = WorkstationModel(defaults: isolatedDefaults())
        let app = AppModel()
        let ids = Set(model.commands(app: app).map(\.id))
        for activity in Activity.allCases { #expect(ids.contains("go.\(activity.rawValue)")) }
        #expect(ids.isSuperset(of: ["agent.new", "dock.toggle", "approvals.show", "modules.show"]))
    }
}
