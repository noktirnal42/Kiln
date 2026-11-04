import Testing
@testable import Kiln

@Suite("First-run checklist")
struct GetStartedTests {
    private func state(_ model: Bool = false, _ project: Bool = false, _ chat: Bool = false) -> GetStarted.State {
        .init(providerReady: model, hasProject: project, hasConversation: chat)
    }

    @Test("a fresh install starts at connecting a model") func fresh() { #expect(GetStarted.next(state()) == .model) }
    @Test("steps are offered in order and skip what is already done") func order() {
        #expect(GetStarted.next(state(true)) == .project)
        #expect(GetStarted.next(state(true, true)) == .firstTask)
        #expect(GetStarted.next(state(false, true)) == .model)
    }
    @Test("once everything is done the card goes away") func finished() {
        #expect(GetStarted.next(state(true, true, true)) == nil)
        #expect(!GetStarted.shows(state(true, true, true), dismissed: false))
    }
    @Test("dismissing hides it for good") func dismissed() {
        #expect(GetStarted.shows(state(), dismissed: false))
        #expect(!GetStarted.shows(state(), dismissed: true))
    }
}
