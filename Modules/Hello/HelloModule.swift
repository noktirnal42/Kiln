import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
public final class HelloModule: @preconcurrency Module, ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.hello"
    public nonisolated static let displayName = "Hello"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [.systemInfo]

    public private(set) var publishedPings = 0
    public private(set) var receivedPings = 0
    public private(set) var lastReceivedPing: String?
    public private(set) var lastLifecycleNotice: String?
    public private(set) var isActivated = false

    private var context: ModuleContext?
    private var lifecycleToken: SubscriptionToken?
    private var pingToken: SubscriptionToken?

    public nonisolated init() {}

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        context.logger.info("Hello module initialized")
        let bus = context.eventBus
        lifecycleToken = await bus.subscribe(ModuleLifecycleEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleLifecycle(event)
        }
        pingToken = await bus.subscribe(HelloPingEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handlePing(event)
        }
        await context.serviceRegistry.register(self, for: HelloModule.self)
    }

    public func activate() async throws {
        isActivated = true
        context?.logger.info("Hello module activated")
    }

    public func deactivate() async throws {
        isActivated = false
        context?.logger.info("Hello module deactivated")
    }

    public func shutdown() async throws {
        if let bus = context?.eventBus {
            if let lifecycleToken { await bus.unsubscribe(lifecycleToken) }
            if let pingToken { await bus.unsubscribe(pingToken) }
        }
        lifecycleToken = nil
        pingToken = nil
        context = nil
        isActivated = false
    }

    public nonisolated func contributeMenus() -> [MenuContribution] {
        [MenuContribution(title: "Hello", items: ["Publish Ping"])]
    }

    public nonisolated func contributeCommands() -> [CommandContribution] {
        [CommandContribution(identifier: "hello.ping", title: "Publish Hello Ping", shortcut: "⌘⇧H", category: "Hello")]
    }

    public func makeRootView() -> AnyView {
        AnyView(HelloModuleView(module: self))
    }

    public func publishPing(message: String) async throws {
        guard let context else {
            throw ModuleFailure.notLoaded(Self.identifier)
        }
        try context.requireCapability(.systemInfo)
        await context.eventBus.publish(HelloPingEvent(sourceModule: Self.identifier, message: message))
        publishedPings += 1
    }

    public func systemInfoSummary() throws -> String {
        guard let context else {
            throw ModuleFailure.notLoaded(Self.identifier)
        }
        try context.requireCapability(.systemInfo)
        let processInfo = ProcessInfo.processInfo
        let memoryGB = Double(processInfo.physicalMemory) / 1_073_741_824
        return String(
            format: "%@ · %d cores · %.1f GB RAM · uptime %.0f min",
            processInfo.hostName,
            processInfo.processorCount,
            memoryGB,
            processInfo.systemUptime / 60
        )
    }

    private func handlePing(_ event: HelloPingEvent) async {
        receivedPings += 1
        lastReceivedPing = event.message
    }

    private func handleLifecycle(_ event: ModuleLifecycleEvent) async {
        lastLifecycleNotice = "\(event.moduleIdentifier): \(event.phase)"
    }
}
