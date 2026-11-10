import SwiftUI
import Observation

/// The places you work in. Each is a whole screen, not a window onto one module: the agent dock stays
/// beside all of them except Agent itself, so the same agent can drive whatever is on screen.
enum Activity: String, CaseIterable, Identifiable, Sendable {
    case home, agent, swarm, develop, analyze, lab, audit, browser, devices, media, images

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .agent: "Agent"
        case .swarm: "Swarm"
        case .develop: "Develop"
        case .analyze: "Analyze"
        case .lab: "Lab"
        case .audit: "Audit"
        case .browser: "Browser"
        case .devices: "Devices"
        case .media: "Media"
        case .images: "Images"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .agent: "sparkles"
        case .swarm: "person.3.sequence"
        case .develop: "chevron.left.forwardslash.chevron.right"
        case .analyze: "magnifyingglass.circle"
        case .lab: "brain.head.profile"
        case .audit: "checkmark.seal"
        case .browser: "globe"
        case .devices: "iphone.gen3"
        case .media: "play.rectangle"
        case .images: "photo.artframe"
        }
    }

    var summary: String {
        switch self {
        case .home: "Overview of your workstation"
        case .agent: "Converse with a model, with tools"
        case .swarm: "Give a goal to a team of agents working in parallel"
        case .develop: "Terminal, git, search and MCP servers"
        case .analyze: "Reverse engineering and decryption"
        case .lab: "Datasets, training, evaluation and models"
        case .audit: "What agents did, and whether the record is intact"
        case .browser: "Tabbed web browser the agent can read"
        case .devices: "iOS simulators and Android emulators: boot, view, install, drive"
        case .media: "Video, images and audio: view, generate, speak and transcribe"
        case .images: "Generate, edit and upscale images; download FLUX, SDXL and other models"
        }
    }

    /// The module that renders this activity, when one does. Home, Develop and Audit are built in.
    var moduleIdentifier: String? {
        switch self {
        case .agent: ChatModule.identifier
        case .analyze: REModule.identifier
        case .lab: ModelLabModule.identifier
        case .browser: BrowserModule.identifier
        case .devices: DevicesModule.identifier
        case .media: MediaModule.identifier
        case .images: ImageStudioModule.identifier
        case .home, .swarm, .develop, .audit: nil
        }
    }

    /// ⌘1…⌘9 in declaration order, then ⌘0 for the tenth. Later activities share ⌘0 until the shell gets a better scheme.
    var shortcutKey: Character {
        let number = (Activity.allCases.firstIndex(of: self) ?? 0) + 1
        // ⌘1…⌘9, ⌘0 for the tenth, ⌘- for the eleventh.
        return number < 10 ? Character(String(number)) : (number == 10 ? "0" : "-")
    }
}

/// One thing the command palette can do.
struct WorkstationCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var keywords: [String] = []
    var shortcut: String?
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
        commands.enumerated().compactMap { index, command -> (Int, Int, WorkstationCommand)? in
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

    /// Opens on the agent: like the apps this sits beside, the conversation is the front door, and the other
    /// activities are things you reach from it.
    var selected: Activity = .agent
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
    var dockShown: Bool { dockVisible && selected != .agent }

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
                shortcut: "⌘\(activity.shortcutKey)",
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
        return list
    }
}
