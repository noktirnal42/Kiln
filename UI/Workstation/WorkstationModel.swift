import SwiftUI
import Observation

/// The places you work in. Each is a whole screen, not a window onto one module: the agent dock stays
/// beside all of them except Agent itself, so the same agent can drive whatever is on screen.
///
/// An `Activity` is a handle on an `ActivityDescriptor`; everything about it (title, symbol, shortcut, prompts,
/// tools) comes from the registry. Each module declares its own handle next to its descriptor
/// (`extension Activity { static let browser = Activity("browser") }`) so views and tests can name it.
struct Activity: Hashable, Identifiable, Sendable {
    let id: String
    init(_ id: String) { self.id = id }

    var rawValue: String { id }

    /// Every registered activity, in catalog order.
    static var allCases: [Activity] { ActivityRegistry.standard.descriptors.map { Activity($0.id) } }

    var descriptor: ActivityDescriptor {
        guard let descriptor = ActivityRegistry.standard.descriptor(id) else {
            preconditionFailure("Activity '\(id)' is not in ActivityCatalog")
        }
        return descriptor
    }

    var title: String { descriptor.title }
    var symbol: String { descriptor.symbol }
    var summary: String { descriptor.summary }
    var moduleIdentifier: String? { descriptor.moduleIdentifier }
    var showsAgentDock: Bool { descriptor.showsAgentDock }

    /// ⌘1…⌘9 in catalog order, then ⌘0 for the tenth. Activities past the tenth have none.
    var shortcutKey: Character? { ActivityRegistry.standard.shortcutKey(for: id) }
}

/// One thing the command palette can do.
struct WorkstationCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var keywords: [String] = []
    var shortcut: String?
    /// Listed only once the user types something, so the long capability list never crowds the default palette.
    var searchOnly = false
    let run: @MainActor () -> Void
}

/// Ranking for the palette. Pure, so it can be tested without a window.
enum CommandRanking {
    /// nil means "does not match". Higher is better.
    static func score(title: String, subtitle: String, keywords: [String], query: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let t = title.lowercased()
        if t == q { return 120 }
        if t.hasPrefix(q) { return 100 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 80 }
        if t.contains(q) { return 60 }
        if isSubsequence(q, of: t) { return 40 }
        if keywords.contains(where: { $0.lowercased().contains(q) }) { return 25 }
        if subtitle.lowercased().contains(q) { return 15 }
        return nil
    }

    static func rank(_ commands: [WorkstationCommand], query: String) -> [WorkstationCommand] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return commands.enumerated().compactMap { index, command -> (Int, Int, WorkstationCommand)? in
            if command.searchOnly && !searching { return nil }
            guard let score = score(title: command.title, subtitle: command.subtitle,
                                    keywords: command.keywords, query: query) else { return nil }
            return (score, index, command)
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }   // best first; ties keep their original order
        .map(\.2)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

/// What the status bar says. Pure, for the same reason.
enum WorkstationStatus {
    enum AgentState: Equatable { case idle, running, awaitingApproval }
    enum Level: Equatable { case ok, warning, problem, neutral }

    static func agentState(isStreaming: Bool, pendingApprovals: Int) -> AgentState {
        if pendingApprovals > 0 { return .awaitingApproval }
        return isStreaming ? .running : .idle
    }

    static func agentLabel(_ state: AgentState) -> String {
        switch state {
        case .idle: "Agent idle"
        case .running: "Agent working…"
        case .awaitingApproval: "Waiting for you"
        }
    }

    /// Dropped audit entries are the one thing here that is a problem, not a statistic: the record has gaps.
    static func audit(chainConfigured: Bool, droppedEntries: Int) -> (text: String, level: Level) {
        guard chainConfigured else { return ("Audit off", .warning) }
        if droppedEntries > 0 { return ("Audit: \(droppedEntries) lost", .problem) }
        return ("Audit on", .ok)
    }
}

@MainActor
@Observable
final class WorkstationModel {
    private static let dockKey = "workstation.dockVisible"

    /// The browser presents an address and search field as soon as the workstation opens.
    var selected: Activity = .browser
    var showPalette = false
    var showApprovals = false
    var showModules = false

    /// Injected so tests never write into the real app's preferences (they run inside the app host).
    private let defaults: UserDefaults

    var dockVisible: Bool {
        didSet { defaults.set(dockVisible, forKey: Self.dockKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dockVisible = defaults.object(forKey: Self.dockKey) as? Bool ?? true
    }

    /// The dock is the agent beside your work; on the Agent activity it would just be a second copy.
    var dockShown: Bool { dockVisible && selected.showsAgentDock }

    func select(_ activity: Activity, app: AppModel) {
        selected = activity
        if let identifier = activity.moduleIdentifier {
            Task { await app.activateModule(identifier) }
        }
    }

    func toggleDock() { dockVisible.toggle() }

    /// Everything the palette offers. Built per call so labels reflect current state.
    func commands(app: AppModel) -> [WorkstationCommand] {
        var list: [WorkstationCommand] = Activity.allCases.map { activity in
            WorkstationCommand(
                id: "go.\(activity.rawValue)", title: "Go to \(activity.title)", subtitle: activity.summary,
                symbol: activity.symbol, keywords: ["open", "switch", activity.rawValue],
                shortcut: activity.shortcutKey.map { "⌘\($0)" },
                run: { [weak self] in self?.select(activity, app: app) })
        }
        list += [
            WorkstationCommand(
                id: "agent.new", title: "New conversation", subtitle: "Start a fresh conversation with the agent",
                symbol: "plus.bubble", keywords: ["chat", "agent", "clear"], shortcut: "⌘N",
                run: { [weak self] in
                    Task { await app.chatSession?.newConversation() }
                    if self?.selected != .agent { self?.dockVisible = true }
                }),
            WorkstationCommand(
                id: "dock.toggle", title: dockVisible ? "Hide agent dock" : "Show agent dock",
                subtitle: "The agent beside your current work", symbol: "sidebar.right",
                keywords: ["panel", "chat"], shortcut: "⌘⌥A", run: { [weak self] in self?.toggleDock() }),
            WorkstationCommand(
                id: "approvals.show", title: "Show approval queue", subtitle: "Tool calls waiting for you, and standing grants",
                symbol: "checkmark.shield", keywords: ["permissions", "grants"], run: { [weak self] in self?.showApprovals = true }),
            WorkstationCommand(
                id: "modules.show", title: "Show loaded modules", subtitle: "Module lifecycle and the event bus",
                symbol: "puzzlepiece.extension", keywords: ["debug", "events", "bus"], run: { [weak self] in self?.showModules = true }),
        ]
        list += DevelopCommands.all(app: app, select: { [weak self] in self?.select(.develop, app: app) })
        list += capabilityCommands { [weak self] activity in self?.select(activity, app: app) }
        return list
    }

    /// Every registered capability is also a palette command that opens its activity. They appear when you search.
    func capabilityCommands(open: @escaping @MainActor (Activity) -> Void) -> [WorkstationCommand] {
        CapabilityRegistry.all.compactMap { capability in
            guard ActivityRegistry.standard.descriptor(capability.module) != nil else { return nil }
            let activity = Activity(capability.module)
            return WorkstationCommand(
                id: "capability.\(capability.id)", title: "\(activity.title): \(capability.title)",
                subtitle: capability.agentTool.map { "Agent tool \($0)" } ?? "GUI only: \(capability.permission.rawValue)",
                symbol: activity.symbol, keywords: [capability.id, capability.agentTool ?? "", activity.rawValue],
                searchOnly: true,
                run: { open(activity) })
        }
    }
}
