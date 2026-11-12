import Foundation
import Testing
@testable import Kiln

@MainActor
struct ToolFitTests {
    private func allTools() async -> [ToolSpec] { await CapabilityRegistryTests.fullToolRegistry().allSpecs() }
    private func tokens(_ specs: [ToolSpec]) -> Int { ContextCompactor.toolSchemaTokens(specs.map(\.providerTool)) }

    @Test func aBigWindowKeepsEveryTool() async {
        let specs = await allTools()
        let result = ToolFit.fit(specs, window: 200_000)
        #expect(!result.trimmed)
        #expect(result.tools.count == specs.count)
        #expect(result.omittedGroups.isEmpty)
    }

    @Test func aSmallWindowKeepsTheDefinitionsInsideTheirShare() async {
        let specs = await allTools()
        for window in [4_096, 8_192, 16_384, 32_768] {
            let result = ToolFit.fit(specs, window: window)
            #expect(result.trimmed, "window \(window)")
            #expect(tokens(result.tools) <= Int(Double(window) * ToolFit.defaultShare), "window \(window): the kept definitions must fit their share")
        }
    }

    @Test func theCoreFileToolsSurviveTheSmallestWindows() async {
        let specs = await allTools()
        for window in [4_096, 8_192] {
            let names = Set(ToolFit.fit(specs, window: window).tools.map(\.name))
            #expect(names.isSuperset(of: ["read_file", "list_directory", "grep_files"]), "window \(window): \(names.sorted())")
        }
    }

    @Test func aModuleGroupIsNeverHalfOffered() async {
        let specs = await allTools()
        let all = Dictionary(grouping: specs.filter { !ToolFit.coreOrder.contains(ToolFit.group(of: $0.name)) }, by: { ToolFit.group(of: $0.name) })
        for window in [8_192, 16_384, 32_768, 64_000] {
            let kept = Set(ToolFit.fit(specs, window: window).tools.map(\.name))
            for (group, members) in all {
                let present = members.filter { kept.contains($0.name) }.count
                #expect(present == 0 || present == members.count, "window \(window): group \(group) kept \(present) of \(members.count)")
            }
        }
    }

    @Test func theHeaviestGroupsGoFirst() async {
        let specs = await allTools()
        let result = ToolFit.fit(specs, window: 32_768)
        #expect(result.omittedGroups.contains("re") || result.omittedGroups.contains("lab"), "reverse engineering and lab are dropped before everyday tools: \(result.omittedGroups)")
        #expect(!result.omittedGroups.contains("ide"))
    }

    @Test func theWorkstationAgentOnAnEightThousandTokenWindowStillHasRoomForMessages() async {
        let orchestrator = AgentOrchestrator(toolRegistry: await CapabilityRegistryTests.fullToolRegistry())
        let budget = orchestrator.contextBudget(profile: .workstationAgent(), contextWindow: 8_192)
        #expect(budget.toolSchemaTokens <= Int(8_192 * ToolFit.defaultShare))
        #expect(budget.available > 1_500, "was pinned at the 512 floor before tools were fitted; now \(budget.available)")
    }
}
