import Foundation
import os

public struct ModuleLogger: Sendable {
    public let logger: Logger
    public let moduleIdentifier: String

    public init(moduleIdentifier: String) {
        self.moduleIdentifier = moduleIdentifier
        self.logger = Logger(subsystem: "com.supermeta.app", category: moduleIdentifier)
    }

    public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
    public func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

public struct WorkspaceSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let rootPath: String?

    public init(id: UUID, name: String, rootPath: String? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
    }
}

public struct ModuleContext: Sendable {
    public let moduleIdentifier: String
    public let grantedCapabilities: ModuleCapabilities
    public let workspace: WorkspaceSnapshot?
    public let eventBus: ModuleEventBus
    public let serviceRegistry: ServiceRegistry
    public let settings: SettingsService
    public let keychain: KeychainService
    public let logger: ModuleLogger

    public init(
        moduleIdentifier: String,
        grantedCapabilities: ModuleCapabilities,
        workspace: WorkspaceSnapshot?,
        eventBus: ModuleEventBus,
        serviceRegistry: ServiceRegistry,
        settings: SettingsService,
        keychain: KeychainService
    ) {
        self.moduleIdentifier = moduleIdentifier
        self.grantedCapabilities = grantedCapabilities
        self.workspace = workspace
        self.eventBus = eventBus
        self.serviceRegistry = serviceRegistry
        self.settings = settings
        self.keychain = keychain
        self.logger = ModuleLogger(moduleIdentifier: moduleIdentifier)
    }

    public func hasCapability(_ capabilities: ModuleCapabilities) -> Bool {
        grantedCapabilities.contains(capabilities)
    }

    public func requireCapability(_ capabilities: ModuleCapabilities) throws {
        let missing = capabilities.subtracting(grantedCapabilities)
        guard missing.isEmpty else {
            throw CapabilityError(missing: missing)
        }
    }
}
