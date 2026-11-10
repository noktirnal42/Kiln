import Foundation
import Testing
@testable import Kiln

struct ScheduleDueTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2026, month: 11, day: 9, hour: h, minute: m))! }

    @Test func intervalAndDailyDueRules() {
        var every = ScheduledTask(name: "n", prompt: "p", profileName: "Coding Agent", repeats: .everyMinutes(30))
        #expect(!every.isDue(now: date(12, 0), calendar: cal))                    // never started: not due until stored with a start
        every.lastRun = date(11, 0)
        #expect(every.isDue(now: date(11, 30), calendar: cal) && !every.isDue(now: date(11, 29), calendar: cal))
        every.enabled = false
        #expect(!every.isDue(now: date(23, 0), calendar: cal))
        var daily = ScheduledTask(name: "d", prompt: "p", profileName: "Coding Agent", repeats: .daily(hour: 9, minute: 0))
        #expect(!daily.isDue(now: date(8, 59), calendar: cal) && daily.isDue(now: date(9, 0), calendar: cal))
        daily.lastRun = date(9, 1)
        #expect(!daily.isDue(now: date(15, 0), calendar: cal))                    // already ran today
    }

    @Test func storePersistsAndStartsIntervalClockOnSave() throws {
        let dir = try PlatformTestSupport.tempDir("sched")
        let store = ScheduleStore(directory: dir)
        store.upsert(ScheduledTask(name: "n", prompt: "p", profileName: "Coding Agent", repeats: .everyMinutes(10)))
        #expect(store.due().isEmpty)
        #expect(ScheduleStore(directory: dir).all.first?.lastRun != nil)
        #expect(store.due(now: Date().addingTimeInterval(11 * 60)).count == 1)
    }

    @Test func toolsSaveListAndRefuseTooFrequent() async throws {
        let store = ScheduleStore(directory: try PlatformTestSupport.tempDir("sched"))
        let chain = try PlatformTestSupport.auditChain()
        var services = ToolServices(); services.audit = PlatformAudit(chain: chain)
        let context = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID(), services: services)
        let write = ScheduleWriteTool(store: store)
        _ = try await write.execute(argumentsJSON: #"{"name":"nightly","prompt":"run the tests","daily_at":"02:30"}"#, context: context)
        #expect(try await ScheduleListTool(store: store).execute(argumentsJSON: "{}", context: context).contains("daily at 02:30"))
        await #expect(throws: (any Error).self) { _ = try await write.execute(argumentsJSON: #"{"name":"x","prompt":"p","every_minutes":1}"#, context: context) }
        _ = try await write.execute(argumentsJSON: #"{"name":"nightly","action":"remove"}"#, context: context)
        #expect(store.all.isEmpty)
        #expect(try await chain.recent(10).filter { $0.type == "schedule.saved" }.count == 2)
    }
}

@MainActor
struct ScheduleRunTests {
    @Test func aDueTaskRunsAsAnAgentRunInItsOwnConversation() async throws {
        let store = ScheduleStore(directory: try PlatformTestSupport.tempDir("sched"))
        var task = ScheduledTask(name: "digest", prompt: "summarise today", profileName: "Coding Agent", repeats: .everyMinutes(5))
        task.lastRun = Date().addingTimeInterval(-3600)
        store.upsert(task)
        let chain = try PlatformTestSupport.auditChain()
        let session = try await PlatformSessionFactory.make(project: nil, chain: chain, schedules: store)
        let sink = FakeAttention()
        session.attention = sink
        let before = session.conversationID
        await session.runDueTasks()
        #expect(session.conversationID != before && session.conversationTitle == "⏱ digest")
        #expect(session.messages.first?.content == "summarise today" && session.messages.count == 2)
        #expect(store.due().isEmpty)
        #expect(try await chain.recent(30).map(\.type).contains("schedule.run"))
    }
}
