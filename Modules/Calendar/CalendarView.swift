import SwiftUI

struct CalendarView: View {
    @State private var events: [CalendarEvent] = []
    @State private var reminders: [ReminderItem] = []
    @State private var eventsAccess = CalendarService().eventsAccess
    @State private var remindersAccess = CalendarService().remindersAccess
    @State private var newReminder = ""
    @State private var message: String?
    @State private var busy = false
    @State private var loaded = false
    private let service = CalendarService()

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Calendar", subtitle: "Next 7 days and open reminders", symbol: "calendar", trailing: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Reload").accessibilityLabel("Reload")
                }
            })
            if let message { Text(message).font(SSTypography.caption()).foregroundStyle(SSColor.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, SSSpacing.m).padding(.vertical, 4) }
            HSplitView {
                section(title: "Events", symbol: "calendar", access: eventsAccess, what: "Calendar", allow: { eventsAccess = await service.ensureEvents(); await load() }) {
                    if loaded, events.isEmpty { Text("Nothing in the next 7 days.").font(SSTypography.caption()).foregroundStyle(.secondary) }
                    ForEach(events) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title.isEmpty ? "(no title)" : e.title).fontWeight(.medium).lineLimit(2)
                            Text(e.isAllDay ? "\(e.start.formatted(date: .abbreviated, time: .omitted)) · all day" : "\(e.start.formatted(date: .abbreviated, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                .font(SSTypography.caption()).foregroundStyle(.secondary)
                            if !e.location.isEmpty { Label(e.location, systemImage: "mappin").font(SSTypography.caption()).foregroundStyle(.secondary) }
                        }.padding(.vertical, 2)
                    }
                }.frame(minWidth: 280)
                section(title: "Reminders", symbol: "checklist", access: remindersAccess, what: "Reminders", allow: { remindersAccess = await service.ensureReminders(); await load() }) {
                    HStack {
                        TextField("Add a reminder", text: $newReminder).textFieldStyle(.roundedBorder).onSubmit { add() }
                        Button("Add") { add() }.disabled(newReminder.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if loaded, reminders.isEmpty { Text("No open reminders.").font(SSTypography.caption()).foregroundStyle(.secondary) }
                    ForEach(reminders) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).lineLimit(2)
                            Text([r.due.map { $0.formatted(date: .abbreviated, time: .shortened) }, r.list].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(SSTypography.caption()).foregroundStyle(.secondary)
                        }.padding(.vertical, 2)
                    }
                }.frame(minWidth: 280)
            }
        }
        .background(SSColor.canvas)
        .task { await load() }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, symbol: String, access: CalendarAccess, what: String, allow: @escaping () async -> Void, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                Label(title, systemImage: symbol).font(SSTypography.headline())
                if access.isAuthorized { content() } else {
                    Text(access.explanation(for: what)).font(SSTypography.caption()).foregroundStyle(.secondary)
                    if access == .notDetermined { Button("Allow access to \(what)") { Task { await allow() } }.buttonStyle(.borderedProminent) }
                }
            }.padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        busy = true; defer { busy = false; loaded = true }
        eventsAccess = service.eventsAccess; remindersAccess = service.remindersAccess
        let start = Calendar.current.startOfDay(for: Date())
        do {
            if eventsAccess.isAuthorized { events = try await service.events(from: start, to: start.addingTimeInterval(7 * 86_400)) }
            if remindersAccess.isAuthorized { reminders = try await service.reminders() }
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func add() {
        let title = newReminder.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            do { _ = try await service.createReminder(title: title); newReminder = ""; await load() } catch { message = error.localizedDescription }
        }
    }
}
