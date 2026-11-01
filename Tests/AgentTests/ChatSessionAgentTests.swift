import Foundation
import Testing
@testable import Kiln

@MainActor
struct ChatSessionAgentTests {
    private func record(_ id: UUID, _ status: ToolCallStatus) -> ToolCallRecord {
        ToolCallRecord(id: id, toolName: "read_file", argumentsJSON: "{\"path\":\"a.txt\"}", status: status)
    }

    @Test func aToolCallIsUpdatedInPlaceNotDuplicated() {
        var activity: [ToolCallRecord] = []
        let id = UUID()
        ChatSession.apply(.toolCallStarted(record(id, .running)), to: &activity)
        ChatSession.apply(.toolCallFinished(record(id, .succeeded)), to: &activity)
        #expect(activity.count == 1)
        #expect(activity[0].status == .succeeded)
    }

    @Test func separateCallsKeepTheirOrder() {
        var activity: [ToolCallRecord] = []
        let first = UUID(), second = UUID()
        ChatSession.apply(.toolCallStarted(record(first, .running)), to: &activity)
        ChatSession.apply(.toolCallStarted(record(second, .running)), to: &activity)
        #expect(activity.map(\.id) == [first, second])
    }

    @Test func nonToolEventsLeaveActivityAlone() {
        var activity: [ToolCallRecord] = []
        ChatSession.apply(.textDelta("hi"), to: &activity)
        ChatSession.apply(.roundStarted(1), to: &activity)
        #expect(activity.isEmpty)
    }
}

struct ModuleToolAccessTests {
    @Test func prefixEntriesEnableModuleToolsButNothingElse() {
        let set = ToolPermissionSet(enabledTools: ["read_file", "re_*"])
        #expect(set.isEnabled("re_list_functions"))
        #expect(set.isEnabled("read_file"))
        #expect(!set.isEnabled("lab_hardware"))
        #expect(!set.isEnabled("write_file"))
    }

    @Test func theWorkstationAgentReachesReAndLabToolsUnderEveryGate() throws {
        let profile = try #require(AgentProfile.builtIns.first { $0.name == "Workstation Agent" })
        let registry = ToolRegistry(tools: [])
        let policy = ExecutionPolicy(mode: profile.mode)
        #expect(policy.checkTool("re_list_functions").verdict == .allow)
        #expect(policy.checkTool("lab_hardware").verdict == .allow)
        #expect(policy.checkTool("rm_everything").verdict == .deny)
        #expect(profile.toolPermissions.isEnabled("lab_search_models"))
        _ = registry
    }
}
