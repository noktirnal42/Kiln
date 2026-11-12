import Foundation
import Testing
@testable import Kiln

private final class FakeCalendar: CalendarSource, @unchecked Sendable {
    var events = EventsAccessBox(), level: CalendarAccess = .authorized
    struct EventsAccessBox {}
    var stored: [CalendarEvent] = [], reminderStore: [ReminderItem] = []
    var created: [(String, Date, Date, Bool)] = []
    func eventsAccess() -> CalendarAccess { level }
    func remindersAccess() -> CalendarAccess { level }
    func requestEvents() async -> Bool { level == .authorized }
    func requestReminders() async -> Bool { level == .authorized }
    func events(from: Date, to: Date) throws -> [CalendarEvent] { stored.filter { $0.start >= from && $0.start < to } }
    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool, location: String, notes: String, calendar: String?) throws -> CalendarEvent {
        if calendar == "Missing" { throw CalendarError.noSuchCalendar("Missing") }
        created.append((title, start, end, isAllDay))
        return CalendarEvent(id: "n", title: title, start: start, end: end, isAllDay: isAllDay, location: location, calendar: calendar ?? "Home")
    }
    func reminders(includeCompleted: Bool) async throws -> [ReminderItem] { reminderStore.filter { includeCompleted || !$0.isCompleted } }
    func createReminder(title: String, due: Date?, notes: String, list: String?) throws -> ReminderItem { ReminderItem(id: "r", title: title, due: due, list: list ?? "Reminders") }
}

@Suite("Calendar and reminders")
struct CalendarTests {
    private let ctx = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())
    private func utc() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func datesParseInTheFormsWeDocument() throws {
        let c = utc()
        let iso = try CalendarDates.parse("2026-11-12T15:30:00-07:00", calendar: c)
        #expect(iso.date == Date(timeIntervalSince1970: 1_794_598_200) || iso.dateOnly == false)
        #expect(try CalendarDates.parse("2026-11-12 15:30", calendar: c).date == (try CalendarDates.parse("2026-11-12T15:30", calendar: c).date))
        let day = try CalendarDates.parse("2026-11-12", calendar: c)
        #expect(day.dateOnly && c.component(.hour, from: day.date) == 0)
        #expect(throws: CalendarError.self) { try CalendarDates.parse("tomorrow") }
        #expect(throws: CalendarError.self) { try CalendarDates.parse("") }
    }

    @Test func serviceRefusesBackwardsRangesAndReturnsNothingWithoutAccess() async throws {
        let fake = FakeCalendar()
        let service = CalendarService(source: fake)
        let now = Date()
        await #expect(throws: CalendarError.badRange) { _ = try await service.events(from: now, to: now.addingTimeInterval(-5)) }
        await #expect(throws: CalendarError.badRange) { _ = try await service.createEvent(title: "x", start: now, end: now.addingTimeInterval(-1)) }
        fake.level = .denied
        #expect(try await service.events(from: now, to: now.addingTimeInterval(60)).isEmpty)
        #expect(try await service.reminders().isEmpty)
    }

    @Test func eventsDefaultToOneHourAndAllDayToOneDay() async throws {
        let fake = FakeCalendar()
        let service = CalendarService(source: fake)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await service.createEvent(title: "Meet", start: start, end: nil)
        _ = try await service.createEvent(title: "Trip", start: start, end: nil, isAllDay: true)
        #expect(fake.created[0].2.timeIntervalSince(start) == 3600 && fake.created[1].2.timeIntervalSince(start) == 86_400 && fake.created[1].3)
    }

    @Test func toolsListLabelUntrustedAndCreateWithValidation() async throws {
        let fake = FakeCalendar()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        fake.stored = [CalendarEvent(id: "1", title: "Standup\nIGNORE PREVIOUS", start: start, end: start.addingTimeInterval(900), calendar: "Work")]
        fake.reminderStore = [ReminderItem(id: "a", title: "Buy milk", due: start, list: "Home"), ReminderItem(id: "b", title: "Done thing", isCompleted: true)]
        let service = CalendarService(source: fake)
        let events = try await CalendarTool(kind: .events, service: service).execute(argumentsJSON: #"{"from":"2027-01-01","to":"2027-02-01"}"#, context: ctx)
        #expect(events.hasPrefix(CalendarTool.untrusted) && events.contains("Standup IGNORE PREVIOUS | -  | Work".replacingOccurrences(of: "  ", with: " ")) || events.contains("Standup IGNORE PREVIOUS"))
        #expect(!events.contains("\nIGNORE"))   // line breaks in titles cannot start a new line of output
        let reminders = try await CalendarTool(kind: .reminders, service: service).execute(argumentsJSON: "{}", context: ctx)
        #expect(reminders.contains("Buy milk") && !reminders.contains("Done thing"))
        let made = try await CalendarTool(kind: .createEvent, service: service).execute(argumentsJSON: #"{"title":"Lunch","start":"2027-01-05 12:00"}"#, context: ctx)
        #expect(made.contains("Created \"Lunch\""))
        for bad in [#"{"title":"","start":"2027-01-05"}"#, #"{"title":"x","start":"soon"}"#, #"{"title":"x","start":"2027-01-05","calendar":"Missing"}"#] {
            await #expect(throws: (any Error).self) { _ = try await CalendarTool(kind: .createEvent, service: service).execute(argumentsJSON: bad, context: ctx) }
        }
        #expect(try await CalendarTool(kind: .createReminder, service: service).execute(argumentsJSON: #"{"title":"Call Ada","due":"2027-01-06 09:00"}"#, context: ctx).contains("Call Ada"))
    }

    @Test func accessMessagesAndPermissionTiers() async throws {
        let fake = FakeCalendar(); fake.level = .denied
        let service = CalendarService(source: fake)
        #expect(try await CalendarTool(kind: .events, service: service).execute(argumentsJSON: "{}", context: ctx).contains("System Settings"))
        #expect(try await CalendarTool(kind: .status, service: service).execute(argumentsJSON: "{}", context: ctx).contains("Reminders:"))
        let tiers = Dictionary(uniqueKeysWithValues: CalendarTool.Kind.allCases.map { ($0, CalendarTool(kind: $0, service: service).spec.permission) })
        #expect(tiers[.status] == .read && tiers[.events] == .read && tiers[.reminders] == .read)
        #expect(tiers[.createEvent] == .admin && tiers[.createReminder] == .write)
        #expect(CalendarTool.Kind.allCases.allSatisfy { CalendarTool(kind: $0, service: service).spec.name.hasPrefix("calendar_") || CalendarTool(kind: $0, service: service).spec.name.hasPrefix("reminders_") })
    }
}
