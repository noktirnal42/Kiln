import Foundation

/// The set of registered activities, and everything the app derives from it.
struct ActivityRegistry: Sendable {
    let descriptors: [ActivityDescriptor]

    init(_ descriptors: [ActivityDescriptor]) { self.descriptors = descriptors }

    /// The app's registry: `ActivityCatalog` is the one place a module is registered.
    static let standard = ActivityRegistry(ActivityCatalog.descriptors)

    func descriptor(_ id: String) -> ActivityDescriptor? { descriptors.first { $0.id == id } }

    /// ⌘1…⌘9 then ⌘0 to the activities that take a shortcut, in catalog order.
    func shortcutKey(for id: String) -> Character? {
        let keys: [Character] = Array("1234567890")
        let numbered = descriptors.filter { if case .automatic = $0.shortcut { true } else { false } }
        guard let index = numbered.firstIndex(where: { $0.id == id }), keys.indices.contains(index) else { return nil }
        return keys[index]
    }

    /// Prefixes of tools contributed by modules (`ExecutionPolicy.moduleToolPrefixes`).
    var toolPrefixes: [String] { descriptors.flatMap(\.toolPrefixes) }

    /// Tool patterns the Workstation Agent enables for modules.
    var agentToolPatterns: [String] { descriptors.flatMap(\.enabledToolPatterns) }

    var agentPromptSentences: [String] { descriptors.compactMap(\.agentPromptSentence) }

    /// Every capability, tagged with its module.
    var capabilities: [Capability] {
        descriptors.flatMap { descriptor in
            descriptor.capabilities.map { capability in
                var tagged = capability
                tagged.module = descriptor.id
                return tagged
            }
        }
    }

    /// Registers every module's agent tools. Called once the modules are loaded.
    @MainActor
    func registerTools(_ context: ToolRegistrationContext) async {
        for descriptor in descriptors { await descriptor.registerTools?(context) }
    }
}

/// Every capability in the app, derived from the activity registry so a module declares them in one place.
enum CapabilityRegistry {
    static var all: [Capability] { ActivityRegistry.standard.capabilities }
    static func capabilities(for module: String) -> [Capability] { all.filter { $0.module == module } }
    static var gaps: [Capability] { all.filter { $0.agentTool == nil } }
}
