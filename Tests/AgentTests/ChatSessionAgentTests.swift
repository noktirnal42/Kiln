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
