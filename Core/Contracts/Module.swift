import Foundation

public struct MenuContribution: Sendable, Equatable {
    public let title: String
    public let items: [String]

    public init(title: String, items: [String] = []) {
        self.title = title
        self.items = items
    }
}

public struct CommandContribution: Sendable, Equatable, Identifiable {
    public let identifier: String
    public let title: String
    public let shortcut: String?
    public let category: String

    public var id: String { identifier }

    public init(identifier: String, title: String, shortcut: String? = nil, category: String = "General") {
        self.identifier = identifier
        self.title = title
        self.shortcut = shortcut
        self.category = category
    }
}

public struct SettingsPane: Sendable, Equatable {
    public let title: String
    public let moduleIdentifier: String

    public init(title: String, moduleIdentifier: String) {
        self.title = title
        self.moduleIdentifier = moduleIdentifier
    }
}

public protocol Module: Sendable {
    static var identifier: String { get }
    static var displayName: String { get }
    static var version: String { get }
    static var dependencies: [String] { get }
    static var requiredCapabilities: ModuleCapabilities { get }

    func initialize(context: ModuleContext) async throws
    func activate() async throws
    func deactivate() async throws
    func shutdown() async throws
    func handleURL(_ url: URL) async -> Bool
    func contributeMenus() -> [MenuContribution]
    func contributeCommands() -> [CommandContribution]
    func contributeSettings() -> SettingsPane?
}

public extension Module {
    func handleURL(_ url: URL) async -> Bool { false }
    func contributeMenus() -> [MenuContribution] { [] }
    func contributeCommands() -> [CommandContribution] { [] }
    func contributeSettings() -> SettingsPane? { nil }
}

public protocol ModuleDefinition: Module {
    init()
}
