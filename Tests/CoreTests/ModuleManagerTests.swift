import Foundation
import Testing
@testable import SuperMetaApp

actor LifecycleRecorder {
    private var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }

    func all() -> [String] {
        entries
    }
}

actor StubModule: Module, ModuleDefinition {
    nonisolated static let identifier = "com.test.stub"
    nonisolated static let displayName = "Stub"
    nonisolated static let version = "1.0.0"
    nonisolated static let dependencies: [String] = []
    nonisolated static let requiredCapabilities: ModuleCapabilities = []

    let recorder: LifecycleRecorder
    private var grantedContext: ModuleContext?

    init() {
        self.recorder = LifecycleRecorder()
    }

    init(recorder: LifecycleRecorder) {
        self.recorder = recorder
    }

    func initialize(context: ModuleContext) async throws {
        grantedContext = context
        await recorder.record("initialize")
    }

    func activate() async throws {
        await recorder.record("activate")
    }

    func deactivate() async throws {
        await recorder.record("deactivate")
    }

    func shutdown() async throws {
        await recorder.record("shutdown")
    }

    func storedContext() -> ModuleContext? {
        grantedContext
    }
}

actor RestrictedStubModule: Module, ModuleDefinition {
    nonisolated static let identifier = "com.test.restricted"
    nonisolated static let displayName = "Restricted"
    nonisolated static let version = "1.0.0"
    nonisolated static let dependencies: [String] = []
    nonisolated static let requiredCapabilities: ModuleCapabilities = [.fileSystemRead, .kernelDebug]

    init() {}
    func initialize(context: ModuleContext) async throws {}
    func activate() async throws {}
    func deactivate() async throws {}
    func shutdown() async throws {}
}

struct ModuleManagerTests {
    private func makeManifestDirectory(
        _ manifests: [ModuleManifest]
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermeta-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        for (index, manifest) in manifests.enumerated() {
            let file = directory.appendingPathComponent(index == 0 ? "ModuleManifest.json" : "\(manifest.identifier).modulemanifest.json")
            try encoder.encode(manifest).write(to: file)
        }
        return directory
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeManager(
        manifestDirectory: URL,
        allowed: ModuleCapabilities = ModuleCapabilities(rawValue: UInt64.max),
        factories: ModuleFactoryRegistry = {
            var registry = ModuleFactoryRegistry()
            registry.register(StubModule.self)
            registry.register(RestrictedStubModule.self)
            return registry
        }(),
        bus: ModuleEventBus = ModuleEventBus(),
        appVersion: String = "0.1.0"
    ) -> ModuleManager {
        ModuleManager(
            appVersion: appVersion,
            allowedCapabilities: allowed,
            factories: factories,
            manifestDirectories: [manifestDirectory],
            eventBus: bus,
            settings: SettingsService(userConfigURL: nil),
            keychain: KeychainService()
        )
    }

    @Test func discoversManifestsFromDirectory() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(
                identifier: StubModule.identifier,
                displayName: "Stub",
                version: "1.0.0",
                minAppVersion: "0.1.0"
            ),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory)
        let manifests = await manager.discoverManifests()
        #expect(manifests.count == 1)
        #expect(manifests.first?.identifier == StubModule.identifier)
        let records = await manager.allRecords()
        #expect(records.count == 1)
        #expect(records.first?.phase == .discovered)
    }

    @Test func loadsAndUnloadsModule() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: StubModule.identifier, displayName: "Stub", version: "1.0.0", minAppVersion: "0.1.0"),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory)
        await manager.discoverManifests()

        try await manager.load(StubModule.identifier)
        #expect(await manager.isLoaded(StubModule.identifier))
        if let record = await manager.record(for: StubModule.identifier) {
            #expect(record.phase == .initialized)
            #expect(record.grantedCapabilities.isEmpty)
        }

        if let record = await manager.record(for: StubModule.identifier), let module = record.module as? StubModule {
            let calls = await module.recorder.all()
            #expect(calls == ["initialize"])
        } else {
            Issue.record("module missing")
        }

        try await manager.unload(StubModule.identifier)
        #expect(await manager.isLoaded(StubModule.identifier) == false)
        if await manager.record(for: StubModule.identifier) != nil {
            Issue.record("record should be gone")
        }
    }

    @Test func lifecycleSequenceRunsInOrder() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: StubModule.identifier, displayName: "Stub", version: "1.0.0", minAppVersion: "0.1.0"),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory)
        await manager.discoverManifests()
        try await manager.load(StubModule.identifier)
        try await manager.activate(StubModule.identifier)
        try await manager.deactivate(StubModule.identifier)

        let recordBeforeUnload = await manager.record(for: StubModule.identifier)
        let module = recordBeforeUnload?.module as? StubModule
        try await manager.unload(StubModule.identifier)

        guard let module else {
            Issue.record("module is not a StubModule")
            return
        }
        let calls = await module.recorder.all()
        #expect(calls == ["initialize", "activate", "deactivate", "shutdown"])
    }

    @Test func capabilityDenialFailsCleanlyWithMissingNames() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(
                identifier: RestrictedStubModule.identifier,
                displayName: "Restricted",
                version: "1.0.0",
                minAppVersion: "0.1.0",
                requiredCapabilities: ["fileSystem.read", "kernel.debug"]
            ),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory, allowed: [.fileSystemRead])
        await manager.discoverManifests()

        do {
            try await manager.load(RestrictedStubModule.identifier)
            Issue.record("load should have failed")
        } catch let failure as ModuleFailure {
            guard case .capabilityDenied(let missing) = failure else {
                Issue.record("unexpected failure: \(failure)")
                return
            }
            #expect(missing == ["kernel.debug"])
        }

        if let record = await manager.record(for: RestrictedStubModule.identifier) {
            guard case .failed(.capabilityDenied(let missing)) = record.phase else {
                Issue.record("phase should be failed with capability denial")
                return
            }
            #expect(missing == ["kernel.debug"])
        }
    }

    @Test func missingDependencyFailsCleanly() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(
                identifier: StubModule.identifier,
                displayName: "Stub",
                version: "1.0.0",
                minAppVersion: "0.1.0",
                dependencies: ["com.test.does.not.exist"]
            ),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory)
        await manager.discoverManifests()

        let failures = await manager.loadAll()
        #expect(failures[StubModule.identifier] == .missingDependencies(["com.test.does.not.exist"]))
    }

    @Test func versionIncompatibilityFailsCleanly() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: StubModule.identifier, displayName: "Stub", version: "1.0.0", minAppVersion: "9.0.0"),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory, appVersion: "0.1.0")
        await manager.discoverManifests()

        do {
            try await manager.load(StubModule.identifier)
            Issue.record("load should have failed")
        } catch let failure as ModuleFailure {
            guard case .versionIncompatible(let minimum, _, let appVersion) = failure else {
                Issue.record("unexpected failure: \(failure)")
                return
            }
            #expect(minimum == "9.0.0")
            #expect(appVersion == "0.1.0")
        }
    }

    @Test func missingFactoryFailsCleanly() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: "com.test.nofactory", displayName: "NoFactory", version: "1.0.0", minAppVersion: "0.1.0"),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory)
        await manager.discoverManifests()

        do {
            try await manager.load("com.test.nofactory")
            Issue.record("load should have failed")
        } catch let failure as ModuleFailure {
            #expect(failure == .factoryMissing("com.test.nofactory"))
        }
    }

    @Test func publishesLifecycleEventsToBus() async throws {
        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: StubModule.identifier, displayName: "Stub", version: "1.0.0", minAppVersion: "0.1.0"),
        ])
        defer { cleanup(directory) }
        let bus = ModuleEventBus()
        let manager = makeManager(manifestDirectory: directory, bus: bus)
        await manager.discoverManifests()

        let received = LifecycleRecorder()
        _ = await bus.subscribe(ModuleLifecycleEvent.self) { event in
            await received.record("\(event.moduleIdentifier):\(event.phase)")
        }

        try await manager.load(StubModule.identifier)
        try await manager.unload(StubModule.identifier)
        let events = await received.all()
        #expect(events.contains("com.test.stub:initialized"))
        #expect(events.contains("com.test.stub:shutdown"))
    }

    @Test func loadAllRespectsDependencyOrder() async throws {
        struct ChildModule: Module, ModuleDefinition {
            nonisolated static let identifier = "com.test.child"
            nonisolated static let displayName = "Child"
            nonisolated static let version = "1.0.0"
            nonisolated static let dependencies: [String] = []
            nonisolated static let requiredCapabilities: ModuleCapabilities = []
            func initialize(context: ModuleContext) async throws {}
            func activate() async throws {}
            func deactivate() async throws {}
            func shutdown() async throws {}
        }
        struct ParentModule: Module, ModuleDefinition {
            nonisolated static let identifier = "com.test.parent"
            nonisolated static let displayName = "Parent"
            nonisolated static let version = "1.0.0"
            nonisolated static let dependencies: [String] = [ChildModule.identifier]
            nonisolated static let requiredCapabilities: ModuleCapabilities = []
            func initialize(context: ModuleContext) async throws {}
            func activate() async throws {}
            func deactivate() async throws {}
            func shutdown() async throws {}
        }
        var factories = ModuleFactoryRegistry()
        factories.register(ChildModule.self)
        factories.register(ParentModule.self)

        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: ChildModule.identifier, displayName: "Child", version: "1.0.0", minAppVersion: "0.1.0"),
            ModuleManifest(identifier: ParentModule.identifier, displayName: "Parent", version: "1.0.0", minAppVersion: "0.1.0", dependencies: [ChildModule.identifier]),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory, factories: factories)
        await manager.discoverManifests()
        let failures = await manager.loadAll()
        #expect(failures.isEmpty)
        #expect(await manager.isLoaded(ChildModule.identifier))
        #expect(await manager.isLoaded(ParentModule.identifier))
    }

    @Test func moduleContextGrantsDeclaredCapabilities() async throws {
        struct CapableModule: Module, ModuleDefinition {
            nonisolated static let identifier = "com.test.capable"
            nonisolated static let displayName = "Capable"
            nonisolated static let version = "1.0.0"
            nonisolated static let dependencies: [String] = []
            nonisolated static let requiredCapabilities: ModuleCapabilities = [.systemInfo]
            var granted: ModuleCapabilities = []
            func initialize(context: ModuleContext) async throws {}
            func activate() async throws {}
            func deactivate() async throws {}
            func shutdown() async throws {}
        }
        var factories = ModuleFactoryRegistry()
        factories.register(CapableModule.self)

        let directory = try makeManifestDirectory([
            ModuleManifest(identifier: CapableModule.identifier, displayName: "Capable", version: "1.0.0", minAppVersion: "0.1.0", requiredCapabilities: ["systemInfo"]),
        ])
        defer { cleanup(directory) }
        let manager = makeManager(manifestDirectory: directory, factories: factories)
        await manager.discoverManifests()
        try await manager.load(CapableModule.identifier)

        if let record = await manager.record(for: CapableModule.identifier) {
            #expect(record.grantedCapabilities == [.systemInfo])
        } else {
            Issue.record("record missing")
        }
    }
}
