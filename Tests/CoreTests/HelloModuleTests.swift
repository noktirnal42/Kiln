import Foundation
import Testing
@testable import Kiln

@MainActor
struct HelloModuleTests {
    private func makeManifest() -> ModuleManifest {
        ModuleManifest(
            identifier: HelloModule.identifier,
            displayName: "Hello",
            version: "1.0.0",
            minAppVersion: "0.1.0",
            requiredCapabilities: ["systemInfo"]
        )
    }

    private func loadHello(bus: ModuleEventBus) async throws -> HelloModule {
        let module = HelloModule()
        let context = ModuleContext(
            moduleIdentifier: HelloModule.identifier,
            grantedCapabilities: [.systemInfo],
            workspace: nil,
            eventBus: bus,
            serviceRegistry: ServiceRegistry(),
            settings: SettingsService(userConfigURL: nil),
            keychain: KeychainService()
        )
        try await module.initialize(context: context)
        return module
    }

    @Test func publishesPingEventCrossModule() async throws {
        let bus = ModuleEventBus()
        let module = try await loadHello(bus: bus)
        defer { Task { try? await module.shutdown() } }

        let counter = Counter()
        _ = await bus.subscribe(HelloPingEvent.self) { event in
            await counter.add(event.message)
        }
        try await module.publishPing(message: "cross-module")
        #expect(await counter.snapshot() == ["cross-module"])
        #expect(module.publishedPings == 1)
    }

    @Test func receivesPingsItPublishes() async throws {
        let bus = ModuleEventBus()
        let module = try await loadHello(bus: bus)
        defer { Task { try? await module.shutdown() } }
        try await module.publishPing(message: "self")
        #expect(module.receivedPings == 1)
        #expect(module.lastReceivedPing == "self")
    }

    @Test func systemInfoRequiresCapability() async throws {
        let module = HelloModule()
        let context = ModuleContext(
            moduleIdentifier: HelloModule.identifier,
            grantedCapabilities: [],
            workspace: nil,
            eventBus: ModuleEventBus(),
            serviceRegistry: ServiceRegistry(),
            settings: SettingsService(userConfigURL: nil),
            keychain: KeychainService()
        )
        try await module.initialize(context: context)
        defer { Task { try? await module.shutdown() } }

        #expect(throws: CapabilityError(missing: .systemInfo)) {
            try module.systemInfoSummary()
        }
    }

    @Test func systemInfoSucceedsWithGrant() async throws {
        let bus = ModuleEventBus()
        let module = try await loadHello(bus: bus)
        defer { Task { try? await module.shutdown() } }
        let summary = try module.systemInfoSummary()
        #expect(!summary.isEmpty)
    }

    @Test func manifestMatchesStaticMetadata() throws {
        let manifest = makeManifest()
        #expect(manifest.identifier == HelloModule.identifier)
        #expect(manifest.requiredCapabilities == ["systemInfo"])
    }

    @Test func bundledManifestDecodes() throws {
        let bundle = Bundle(for: AppModel.self)
        let url = bundle.url(forResource: "HelloModule.modulemanifest", withExtension: "json", subdirectory: "ModuleManifests")
        guard let url else {
            Issue.record("bundled manifest not found in app bundle")
            return
        }
        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: url))
        #expect(manifest.identifier == HelloModule.identifier)
        #expect(manifest.displayName == "Hello")
        #expect(manifest.requiredCapabilities == ["systemInfo"])
    }
}

