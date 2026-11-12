import Foundation
import EventKit

public struct CalendarEvent: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var calendar: String
    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String = "", calendar: String = "") {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.location = location; self.calendar = calendar
    }
}

public struct ReminderItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var due: Date?
    public var isCompleted: Bool
    public var list: String
    public init(id: String, title: String, due: Date? = nil, isCompleted: Bool = false, list: String = "") {
        self.id = id; self.title = title; self.due = due; self.isCompleted = isCompleted; self.list = list
    }
}

public enum CalendarAccess: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
    public var isAuthorized: Bool { self == .authorized }
    public func explanation(for what: String) -> String {
        switch self {
        case .notDetermined: "Kiln has not asked for access to \(what) yet."
        case .authorized: "Kiln can use \(what)."
        case .denied: "Access to \(what) was refused. Allow Kiln in System Settings, Privacy & Security."
        case .restricted: "Access to \(what) is restricted on this Mac."
        }
    }
}

/// Where calendar data comes from. The real one is EventKit; tests supply fixed data.
public protocol CalendarSource: Sendable {
    func eventsAccess() -> CalendarAccess
    func remindersAccess() -> CalendarAccess
    func requestEvents() async -> Bool
    func requestReminders() async -> Bool
    func events(from: Date, to: Date) throws -> [CalendarEvent]
    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool, location: String, notes: String, calendar: String?) throws -> CalendarEvent
    func reminders(includeCompleted: Bool) async throws -> [ReminderItem]
    func createReminder(title: String, due: Date?, notes: String, list: String?) throws -> ReminderItem
}

public struct EventKitSource: CalendarSource {
    public init() {}
    private func map(_ s: EKAuthorizationStatus) -> CalendarAccess {
        switch s { case .fullAccess: .authorized; case .denied: .denied; case .restricted: .restricted; default: .notDetermined }  // write-only counts as not enough to read
    }
    public func eventsAccess() -> CalendarAccess { map(EKEventStore.authorizationStatus(for: .event)) }
    public func remindersAccess() -> CalendarAccess { map(EKEventStore.authorizationStatus(for: .reminder)) }
    public func requestEvents() async -> Bool { (try? await EKEventStore().requestFullAccessToEvents()) ?? false }
    public func requestReminders() async -> Bool { (try? await EKEventStore().requestFullAccessToReminders()) ?? false }

    public func events(from: Date, to: Date) throws -> [CalendarEvent] {
        let store = EKEventStore()
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).sorted { $0.startDate < $1.startDate }.map {
            CalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay, location: $0.location ?? "", calendar: $0.calendar?.title ?? "")
        }
    }

    public func createEvent(title: String, start: Date, end: Date, isAllDay: Bool, location: String, notes: String, calendar: String?) throws -> CalendarEvent {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title; event.startDate = start; event.endDate = end; event.isAllDay = isAllDay
        if !location.isEmpty { event.location = location }
        if !notes.isEmpty { event.notes = notes }
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        if let calendar, !calendar.isEmpty {
            guard let match = writable.first(where: { $0.title.lowercased() == calendar.lowercased() }) else { throw CalendarError.noSuchCalendar(calendar) }
            event.calendar = match
        } else if let def = store.defaultCalendarForNewEvents { event.calendar = def } else { throw CalendarError.noDefaultCalendar }
        try store.save(event, span: .thisEvent)
        return CalendarEvent(id: event.eventIdentifier ?? "", title: title, start: start, end: end, isAllDay: isAllDay, location: location, calendar: event.calendar.title)
    }

    public func reminders(includeCompleted: Bool) async throws -> [ReminderItem] {
        let store = EKEventStore()
        let predicate = store.predicateForReminders(in: nil)
        // Converted inside the callback: EKReminder is not Sendable and must not cross the continuation.
        let items: [ReminderItem] = await withCheckedContinuation { k in
            store.fetchReminders(matching: predicate) { found in
                k.resume(returning: (found ?? []).map {
                    ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date, isCompleted: $0.isCompleted, list: $0.calendar?.title ?? "")
                })
            }
        }
        return items.filter { includeCompleted || !$0.isCompleted }
    }

    public func createReminder(title: String, due: Date?, notes: String, list: String?) throws -> ReminderItem {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if !notes.isEmpty { reminder.notes = notes }
        if let due { reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        let writable = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        if let list, !list.isEmpty {
            guard let match = writable.first(where: { $0.title.lowercased() == list.lowercased() }) else { throw CalendarError.noSuchCalendar(list) }
            reminder.calendar = match
        } else if let def = store.defaultCalendarForNewReminders() { reminder.calendar = def } else { throw CalendarError.noDefaultCalendar }
        try store.save(reminder, commit: true)
        return ReminderItem(id: reminder.calendarItemIdentifier, title: title, due: due, isCompleted: false, list: reminder.calendar.title)
    }
}

public enum CalendarError: Error, Equatable, LocalizedError {
    case noSuchCalendar(String), noDefaultCalendar, badDate(String), badRange
    public var errorDescription: String? {
        switch self {
        case .noSuchCalendar(let n): "No writable calendar or list named \"\(n)\"."
        case .noDefaultCalendar: "There is no default calendar or list to save into. Set one in the Calendar or Reminders app."
        case .badDate(let d): "Could not read the date \"\(d)\". Use 2026-11-12, 2026-11-12 15:30 or 2026-11-12T15:30:00-07:00."
        case .badRange: "The end must be after the start."
        }
    }
}

public enum CalendarDates {
    /// Accepts ISO 8601 with a zone, "yyyy-MM-dd HH:mm" or "yyyy-MM-ddTHH:mm" (this Mac's time zone), and "yyyy-MM-dd" (start of that day).
    public static func parse(_ text: String, calendar: Calendar = .current) throws -> (date: Date, dateOnly: Bool) {
        let t = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let d = iso.date(from: t) { return (d, false) }
        }
        for (format, dateOnly) in [("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd'T'HH:mm:ss", false), ("yyyy-MM-dd", true)] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone; f.dateFormat = format
            if let d = f.date(from: t) { return (d, dateOnly) }
        }
        throw CalendarError.badDate(text)
    }
}

public struct CalendarService: Sendable {
    private let source: any CalendarSource
    public init(source: any CalendarSource = EventKitSource()) { self.source = source }

    public var eventsAccess: CalendarAccess { source.eventsAccess() }
    public var remindersAccess: CalendarAccess { source.remindersAccess() }

    @discardableResult public func ensureEvents() async -> CalendarAccess {
        if source.eventsAccess() == .notDetermined { _ = await source.requestEvents() }
        return source.eventsAccess()
    }
    @discardableResult public func ensureReminders() async -> CalendarAccess {
        if source.remindersAccess() == .notDetermined { _ = await source.requestReminders() }
        return source.remindersAccess()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        guard await ensureEvents().isAuthorized else { return [] }
        guard to > from else { throw CalendarError.badRange }
        return try source.events(from: from, to: min(to, from.addingTimeInterval(366 * 86_400)))
    }

    public func createEvent(title: String, start: Date, end: Date?, isAllDay: Bool = false, location: String = "", notes: String = "", calendar: String? = nil) async throws -> CalendarEvent {
        let finish = end ?? (isAllDay ? start.addingTimeInterval(86_400) : start.addingTimeInterval(3600))
        guard finish > start else { throw CalendarError.badRange }
        return try source.createEvent(title: title, start: start, end: finish, isAllDay: isAllDay, location: location, notes: notes, calendar: calendar)
    }

    public func reminders(includeCompleted: Bool = false) async throws -> [ReminderItem] {
        guard await ensureReminders().isAuthorized else { return [] }
        return try await source.reminders(includeCompleted: includeCompleted)
            .sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
    }

    public func createReminder(title: String, due: Date? = nil, notes: String = "", list: String? = nil) async throws -> ReminderItem {
        try source.createReminder(title: title, due: due, notes: notes, list: list)
    }
}
