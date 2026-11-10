import SwiftUI

/// Scheduled agent tasks: a prompt, an agent profile and when. Runs are normal agent runs (approvals still apply).
struct SchedulesPaneView: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var name = ""
    @State private var prompt = ""
    @State private var profile = "Coding Agent"
    @State private var daily = false
    @State private var minutes = 60
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack { Text("Scheduled tasks").font(SSTypography.headline()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Runs while Kiln is open. Each run is a normal agent run in its own conversation; anything needing approval waits for you and badges the Dock.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            if let store = session.scheduleStore {
                let _ = tick
                List(store.all) { task in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(task.name).font(SSTypography.body())
                            Text("\(task.describe) · \(task.profileName)\(task.lastRun.map { " · last \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                                .font(SSTypography.caption()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { task.enabled }, set: { var t = task; t.enabled = $0; store.upsert(t); tick += 1 })).labelsHidden()
                            .accessibilityLabel("Enable \(task.name)")
                        Button("Remove", role: .destructive) { store.remove(task.id); tick += 1 }
                    }
                }
                .overlay {
                    if store.all.isEmpty {
                        ContentUnavailableView("No scheduled tasks", systemImage: "calendar.badge.clock",
                            description: Text("Add a name, prompt and schedule below to create your first task."))
                    }
                }
                Divider()
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Prompt", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                HStack {
                    Picker("Agent", selection: $profile) { ForEach(session.agentProfiles.map(\.name), id: \.self) { Text($0) } }.frame(maxWidth: 240)
                    Picker("", selection: $daily) { Text("Every").tag(false); Text("Daily at").tag(true) }.pickerStyle(.segmented).frame(width: 150).labelsHidden()
                    if daily { DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden() }
                    else { Stepper("\(minutes) min", value: $minutes, in: 5...1440, step: 5) }
                    Spacer()
                    Button("Add") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        store.upsert(ScheduledTask(name: name, prompt: prompt, profileName: profile,
                                                   repeats: daily ? .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0) : .everyMinutes(minutes)))
                        Task { await session.platformAuditRecord("schedule.saved", ["name": .string(name), "source": .string("pane")]) }
                        name = ""; prompt = ""; tick += 1
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                ContentUnavailableView("Scheduling unavailable", systemImage: "calendar.badge.exclamationmark",
                    description: Text("This build does not have a schedule store."))
            }
        }
        .padding(SSSpacing.m).frame(width: 680, height: 500)
    }
}
