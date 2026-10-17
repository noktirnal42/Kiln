import Foundation

public enum ModulePhase: Sendable, Equatable {
    case discovered
    case validated
    case failed(ModuleFailure)
    case initialized
    case activated

    public var isLoaded: Bool {
        switch self {
        case .initialized, .activated: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .discovered: return "Discovered"
        case .validated: return "Validated"
        case .failed(let failure): return "Failed: \(failure)"
        case .initialized: return "Loaded"
        case .activated: return "Active"
        }
    }
}

public enum ModuleFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownIdentifier(String)
    case invalidManifest(String)
    case versionIncompatible(minimum: String, maximum: String?, appVersion: String)
    case missingDependencies([String])
    case capabilityDenied(missing: [String])
    case factoryMissing(String)
    case initializationFailed(String)
    case notLoaded(String)
    case invalidStateTransition(from: String, to: String)

    public var description: String {
        switch self {
        case .unknownIdentifier(let id):
            return "No module found with identifier '\(id)'"
        case .invalidManifest(let reason):
            return "Invalid module manifest: \(reason)"
        case .versionIncompatible(let minimum, let maximum, let appVersion):
            return "App version \(appVersion) outside module compatibility range [\(minimum), \(maximum ?? "∞")]"
        case .missingDependencies(let deps):
            return "Missing dependencies: \(deps.joined(separator: ", "))"
        case .capabilityDenied(let missing):
            return "Capability grant denied. Missing capabilities: \(missing.joined(separator: ", "))"
        case .factoryMissing(let id):
            return "No module factory registered for '\(id)'"
        case .initializationFailed(let reason):
            return "Module initialization failed: \(reason)"
        case .notLoaded(let id):
            return "Module '\(id)' is not loaded"
        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from '\(from)' to '\(to)'"
        }
    }
}

public struct ModuleRecord: Identifiable, Sendable {
    public let manifest: ModuleManifest
    public var phase: ModulePhase
    public var grantedCapabilities: ModuleCapabilities
    public var unknownCapabilityNames: [String]
    public var module: (any Module)?

    public var id: String { manifest.identifier }
    public var isLoaded: Bool { phase.isLoaded }
}

public struct ModuleFactoryRegistry: Sendable {
    public typealias Factory = @Sendable () -> any Module

    private var factories: [String: Factory] = [:]

    public init() {}

    public mutating func register(_ type: (some ModuleDefinition).Type) {
        factories[type.identifier] = { type.init() }
    }

    public mutating func register(identifier: String, factory: @escaping Factory) {
        factories[identifier] = factory
    }

    public func make(_ identifier: String) -> (any Module)? {
        factories[identifier]?()
    }

    public var registeredIdentifiers: [String] {
        Array(factories.keys).sorted()
    }
}

public struct ModuleLifecycleEvent: ModuleEvent, Encodable, Equatable {
    public let eventType = "module.lifecycle"
    public let sourceModule = "com.supermeta.kernel"
    public let timestamp = Date()
    public let moduleIdentifier: String
    public let phase: String
    public let detail: String?

    public init(moduleIdentifier: String, phase: String, detail: String? = nil) {
        self.moduleIdentifier = moduleIdentifier
        self.phase = phase
        self.detail = detail
    }
}

public actor ModuleManager {
    private let appVersion: String
    private let allowedCapabilities: ModuleCapabilities
    private let factories: ModuleFactoryRegistry
    private let eventBus: ModuleEventBus
    private let settings: SettingsService
    private let keychain: KeychainService
    private let workspace: WorkspaceSnapshot?
    private var recordsByID: [String: ModuleRecord] = [:]
    private var manifestDirectories: [URL]

    public init(
        appVersion: String,
        allowedCapabilities: ModuleCapabilities,
        factories: ModuleFactoryRegistry,
        manifestDirectories: [URL],
        eventBus: ModuleEventBus = .shared,
        settings: SettingsService,
        keychain: KeychainService,
        workspace: WorkspaceSnapshot? = nil
    ) {
        self.appVersion = appVersion
        self.allowedCapabilities = allowedCapabilities
        self.factories = factories
        self.manifestDirectories = manifestDirectories
        self.eventBus = eventBus
        self.settings = settings
        self.keychain = keychain
        self.workspace = workspace
    }

    public func addManifestDirectory(_ url: URL) {
        guard !manifestDirectories.contains(url) else { return }
        manifestDirectories.append(url)
    }

    @discardableResult
    public func discoverManifests() async -> [ModuleManifest] {
        var manifests: [ModuleManifest] = []
        for directory in manifestDirectories {
            for url in Self.manifestFiles(in: directory) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let manifest = try? JSONDecoder().decode(ModuleManifest.self, from: data) else {
                    await publishLifecycle(for: url.lastPathComponent, phase: "invalid-manifest", detail: "Manifest at \(url.path) failed to decode")
                    continue
                }
                if recordsByID[manifest.identifier] == nil {
                    recordsByID[manifest.identifier] = ModuleRecord(
                        manifest: manifest,
                        phase: .discovered,
                        grantedCapabilities: [],
                        unknownCapabilityNames: [],
                        module: nil
                    )
                }
                manifests.append(manifest)
            }
        }
        return manifests
    }

    private static func manifestFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: nil
        )
        var results: [URL] = []
        var scanned = 0
        while let item = enumerator?.nextObject() as? URL {
            scanned += 1
            if scanned > 1024 { break }
            let fileName = item.lastPathComponent
            if fileName == "ModuleManifest.json" || fileName.hasSuffix(".modulemanifest.json") {
                results.append(item)
            }
        }
        return results
    }

    public func record(for identifier: String) async -> ModuleRecord? {
        recordsByID[identifier]
    }

    public func allRecords() async -> [ModuleRecord] {
        recordsByID.values.sorted { $0.manifest.identifier < $1.manifest.identifier }
    }

    public func isLoaded(_ identifier: String) async -> Bool {
        recordsByID[identifier]?.isLoaded == true
    }

    public func loadedIdentifiers() async -> [String] {
        recordsByID.values.filter(\.isLoaded).map { $0.manifest.identifier }.sorted()
    }

    public func load(_ identifier: String) async throws {
        guard var record = recordsByID[identifier] else {
            throw ModuleFailure.unknownIdentifier(identifier)
        }
        if record.isLoaded { return }
        if case .failed(let previousFailure) = record.phase {
            throw previousFailure
        }

        try validateCompatibility(record.manifest)
        record.phase = .validated

        let missingDependencies = record.manifest.dependencies.filter { recordsByID[$0] == nil }
        guard missingDependencies.isEmpty else {
            record.phase = .failed(.missingDependencies(missingDependencies))
            recordsByID[identifier] = record
            await publishLifecycle(for: identifier, phase: "load-failed", detail: ModuleFailure.missingDependencies(missingDependencies).description)
            throw ModuleFailure.missingDependencies(missingDependencies)
        }

        let (required, unknownRequired) = ModuleCapabilities.parse(record.manifest.requiredCapabilities)
        let (optional, unknownOptional) = ModuleCapabilities.parse(record.manifest.optionalCapabilities)
        record.unknownCapabilityNames = unknownRequired + unknownOptional

        let missing = required.subtracting(allowedCapabilities)
        if !missing.isEmpty {
            let failure = ModuleFailure.capabilityDenied(missing: missing.names)
            record.phase = .failed(failure)
            recordsByID[identifier] = record
            await publishLifecycle(for: identifier, phase: "load-failed", detail: failure.description)
            throw failure
        }
        record.grantedCapabilities = required.union(optional).intersection(allowedCapabilities)

        guard let module = factories.make(identifier) else {
            let failure = ModuleFailure.factoryMissing(identifier)
            record.phase = .failed(failure)
            recordsByID[identifier] = record
            await publishLifecycle(for: identifier, phase: "load-failed", detail: failure.description)
            throw failure
        }

        let context = ModuleContext(
            moduleIdentifier: identifier,
            grantedCapabilities: record.grantedCapabilities,
            workspace: workspace,
            eventBus: eventBus,
            serviceRegistry: ServiceRegistry(),
            settings: settings,
            keychain: keychain
        )
        do {
            try await module.initialize(context: context)
        } catch {
            let failure = ModuleFailure.initializationFailed(String(describing: error))
            record.phase = .failed(failure)
            recordsByID[identifier] = record
            await publishLifecycle(for: identifier, phase: "load-failed", detail: failure.description)
            throw failure
        }

        record.module = module
        record.phase = .initialized
        recordsByID[identifier] = record
        await publishLifecycle(for: identifier, phase: "initialized", detail: nil)
    }

    public func loadAll() async -> [String: ModuleFailure] {
        var failures: [String: ModuleFailure] = [:]
        let order = topologicalOrder()
        for identifier in order {
            do {
                try await load(identifier)
            } catch let failure as ModuleFailure {
                failures[identifier] = failure
            } catch {
                failures[identifier] = .initializationFailed(String(describing: error))
            }
        }
        return failures
    }

    private func topologicalOrder() -> [String] {
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for record in recordsByID.values {
            let id = record.manifest.identifier
            inDegree[id, default: 0] += 0
            for dependency in record.manifest.dependencies where recordsByID[dependency] != nil {
                inDegree[id, default: 0] += 1
                dependents[dependency, default: []].append(id)
            }
        }
        var queue = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var order: [String] = []
        while let current = queue.first {
            queue.removeFirst()
            order.append(current)
            for dependent in dependents[current] ?? [] {
                inDegree[dependent]! -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }
        let remaining = inDegree.keys.filter { !order.contains($0) }.sorted()
        return order + remaining
    }

    public func activate(_ identifier: String) async throws {
        guard var record = recordsByID[identifier] else {
            throw ModuleFailure.unknownIdentifier(identifier)
        }
        if record.phase == .activated { return }
        guard record.isLoaded else {
            throw ModuleFailure.notLoaded(identifier)
        }
        guard let module = record.module else {
            throw ModuleFailure.factoryMissing(identifier)
        }
        do {
            try await module.activate()
        } catch {
            throw ModuleFailure.initializationFailed("activation failed: \(error)")
        }
        record.phase = .activated
        recordsByID[identifier] = record
        await publishLifecycle(for: identifier, phase: "activated", detail: nil)
    }

    public func deactivate(_ identifier: String) async throws {
        guard var record = recordsByID[identifier] else {
            throw ModuleFailure.unknownIdentifier(identifier)
        }
        guard record.phase == .activated else {
            throw ModuleFailure.invalidStateTransition(from: record.phase.label, to: "Loaded")
        }
        guard let module = record.module else {
            throw ModuleFailure.factoryMissing(identifier)
        }
        try await module.deactivate()
        record.phase = .initialized
        recordsByID[identifier] = record
        await publishLifecycle(for: identifier, phase: "deactivated", detail: nil)
    }

    public func unload(_ identifier: String) async throws {
        guard var record = recordsByID[identifier] else {
            throw ModuleFailure.unknownIdentifier(identifier)
        }
        if record.phase == .activated {
            try await moduleSafeDeactivate(record)
            record.phase = .initialized
        }
        if record.isLoaded {
            guard let module = record.module else {
                throw ModuleFailure.factoryMissing(identifier)
            }
            try await module.shutdown()
            await publishLifecycle(for: identifier, phase: "shutdown", detail: nil)
        }
        recordsByID.removeValue(forKey: identifier)
    }

    private func moduleSafeDeactivate(_ record: ModuleRecord) async throws {
        guard let module = record.module else {
            throw ModuleFailure.factoryMissing(record.manifest.identifier)
        }
        try await module.deactivate()
        await publishLifecycle(for: record.manifest.identifier, phase: "deactivated", detail: nil)
    }

    public func unloadAll() async {
        for identifier in recordsByID.keys.sorted() {
            try? await unload(identifier)
        }
    }

    private func validateCompatibility(_ manifest: ModuleManifest) throws {
        guard let minVersion = SemVer(parsing: manifest.minAppVersion), let app = SemVer(parsing: appVersion) else {
            throw ModuleFailure.invalidManifest("unparseable version in '\(manifest.identifier)'")
        }
        if app < minVersion {
            throw ModuleFailure.versionIncompatible(minimum: manifest.minAppVersion, maximum: manifest.maxAppVersion, appVersion: appVersion)
        }
        if let maxString = manifest.maxAppVersion, let maxVersion = SemVer(parsing: maxString), app > maxVersion {
            throw ModuleFailure.versionIncompatible(minimum: manifest.minAppVersion, maximum: manifest.maxAppVersion, appVersion: appVersion)
        }
    }

    private func publishLifecycle(for identifier: String, phase: String, detail: String?) async {
        await eventBus.publish(ModuleLifecycleEvent(moduleIdentifier: identifier, phase: phase, detail: detail))
    }
}
