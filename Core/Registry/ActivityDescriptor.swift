import SwiftUI

/// A suggested first message. It fills the composer; it never sends on its own.
struct StarterPrompt: Identifiable, Equatable, Sendable {
    let title: String
    let symbol: String
    let text: String
    var id: String { title }
}

/// Hands a module's registration closure what it needs to register agent tools: the registry to add them to and
/// a way to reach any loaded module (Browser needs Analyze, for instance).
@MainActor
struct ToolRegistrationContext {
    let registry: ToolRegistry
    let loadedModule: @MainActor (String) async -> Any?
    /// The Develop IDE service, for the `ide_*` tools (Develop is built into the shell, not a module).
    var develop: DevelopController?

    func module<M>(_ identifier: String, as type: M.Type = M.self) async -> M? {
        await loadedModule(identifier) as? M
    }
}

/// Everything the shell needs to know about one activity, declared once in the module's own folder.
///
/// The Work menu, ⌘-number shortcuts, command palette, starter prompts, the execution policy's module-tool prefixes and the
/// Workstation Agent's tool list and prompt are all derived from the registered descriptors, so adding an activity is
/// one descriptor and one line in `ActivityCatalog`, not an edit to six shared files.
struct ActivityDescriptor: Identifiable, Sendable {
    enum Shortcut: Sendable {
        /// The next free ⌘1…⌘9, then ⌘0, in catalog order. Activities past the tenth get none rather than a duplicate.
        case automatic
        case none
    }

    enum Content: Sendable {
        /// Render the module named by `moduleIdentifier` through the module host.
        case module
        /// A view the shell builds itself (Home, Swarm, Develop, Audit).
        case custom(@MainActor @Sendable (WorkstationModel) -> AnyView)
    }

    let id: String
    let title: String
    let symbol: String
    let summary: String
    var shortcut: Shortcut = .automatic
    /// The module that renders this activity, when one does.
    var moduleIdentifier: String?
    var content: Content = .module
    /// Listed in the Work menu. Home and Agent have their own places.
    var showsInSidebar = true
    /// The agent panel stays beside this activity. False only where it would be a second copy (Agent itself).
    var showsAgentDock = true
    var starterPrompts: @Sendable (_ hasProject: Bool) -> [StarterPrompt] = { _ in [] }
    /// Agent tool name prefixes this module owns (`browser_`). They are what `ExecutionPolicy` treats as module tools.
    var toolPrefixes: [String] = []
    /// What the Workstation Agent profile enables for this module. Nil means every tool under `toolPrefixes`.
    var agentToolPatterns: [String]?
    /// One sentence for the Workstation Agent's system prompt.
    var agentPromptSentence: String?
    /// Every action this module offers, each tied to an agent tool or a written reason it has none.
    var capabilities: [Capability] = []
    /// A counter the module bumps when the agent asks to show something in it (`media_open`); the shell brings the activity
    /// forward when it rises.
    var focusRequestCount: (@MainActor @Sendable (AppModel) -> Int)?
    /// Registers the module's agent tools (and so its MCP tools) once the module is loaded.
    var registerTools: (@MainActor @Sendable (ToolRegistrationContext) async -> Void)?

    var enabledToolPatterns: [String] { agentToolPatterns ?? toolPrefixes.map { $0 + "*" } }
}
