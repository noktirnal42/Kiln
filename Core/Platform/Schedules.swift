import Foundation

/// A task the agent runs on a schedule: a prompt, the agent profile to run it with, and when. Each run is a normal agent
/// run in its own conversation, so approvals, policy, hooks, checkpoints and the audit chain all apply; a run that needs
/// approval waits for you and raises the Dock badge. A schedule never widens permissions or answers approvals.
public struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    public enum Repeat: Codable, Equatable, Sendable {
        case everyMinutes(Int)
        case daily(hour: Int, minute: Int)
    }
    public var id = UUID()
    public var name: String
    public var prompt: String
    public var profileName: String
    public var repeats: Repeat
    public var enabled = true
    public var lastRun: Date?

    /// Due when never run and a period has passed since creation is not tracked, so a new task first runs after one period
    /// (or at the next daily time), never immediately on save.
    public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        switch repeats {
        case .everyMinutes(let minutes):
            guard minutes > 0 else { return false }
            guard let lastRun else { return false }
            return now.timeIntervalSince(lastRun) >= Double(minutes) * 60
        case .daily(let hour, let minute):
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now), now >= today else { return false }
            return lastRun.map { $0 < today } ?? true
        }
    }

    public var describe: String {
        switch repeats {
        case .everyMinutes(let m): return m % 60 == 0 ? "every \(m / 60) h" : "every \(m) min"
        case .daily(let h, let m): return String(format: "daily at %02d:%02d", h, m)
        }
    }
}

public final class ScheduleStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var tasks: [ScheduledTask]

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("schedules.json")
        tasks = (try? JSONDecoder().decode([ScheduledTask].self, from: Data(contentsOf: url))) ?? []
    }

    public static var `default`: ScheduleStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ScheduleStore(directory: base.appendingPathComponent("Kiln", isDirectory: true))
    }

    public var all: [ScheduledTask] { lock.withLock { tasks } }

    public func upsert(_ task: ScheduledTask) {
        lock.lock(); defer { lock.unlock() }
        var task = task
        // A new interval task starts its clock now, so it runs after one period instead of the moment it is saved.
        if case .everyMinutes = task.repeats, task.lastRun == nil { task.lastRun = Date() }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        persist()
    }

    public func remove(_ id: UUID) { lock.lock(); tasks.removeAll { $0.id == id }; persist(); lock.unlock() }

    public func markRun(_ id: UUID, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].lastRun = date; persist() }
    }

    public func due(now: Date = Date()) -> [ScheduledTask] { all.filter { $0.isDue(now: now) } }

    private func persist() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(tasks) { try? data.write(to: url, options: .atomic) }
    }
}
