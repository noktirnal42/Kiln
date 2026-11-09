import Foundation
import Testing
@testable import Kiln

/// The shared activity chrome and the Analyze tab model that sits on it.
@MainActor
struct ActivityChromeTests {
    @Test func analyzeTabsStartWithFunctionsThenEveryFindingsTab() {
        let tabs = REViewTab.allCases
        #expect(tabs.first == .functions)
        #expect(tabs.dropFirst().compactMap(\.finding) == REFindingsTab.allCases)
        #expect(REViewTab.functions.finding == nil)
    }

    @Test func everyAnalyzeTabHasAnIconAndAUniqueName() {
        let tabs = REViewTab.allCases
        #expect(Set(tabs.map(\.rawValue)).count == tabs.count)
        #expect(tabs.allSatisfy { !$0.symbol.isEmpty })
    }

    @Test func developTabsAreTheFiveTools() {
        #expect(DevelopView.Tool.allCases.map(\.rawValue) == ["Editor", "Terminal", "Git", "Search", "MCP"])
    }

    @Test func chromeHeightsKeepPaneHeadersShorterThanActivityHeaders() {
        #expect(SSChrome.paneHeaderHeight < SSChrome.headerHeight)
        #expect(SSChrome.headerHeight >= 36)
    }
}
