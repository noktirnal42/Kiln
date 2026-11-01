import Foundation
import SwiftData
import Observation

@MainActor
@Observable
public final class AppModel {
    public let eventBus: ModuleEventBus
    public let serviceRegistry: ServiceRegistry
    public let keychain: KeychainService
    public let settings: SettingsService
    public let manager: ModuleManager
    public let themeManager = ThemeManager()
    public let modelContainer: ModelContainer
    public let modelRegistry: ModelRegistry
    public let ptyManager = PTYManager()
    public let mcpService = MCPClientService()
    public let gitService = GitService()
    public let fileIndexService = FileIndexService()
    /// Gate B's shared center: every agent run routes approvals through
    /// this one queue, and its grants are the persistable "always allow"
    /// answers.
    public let approvalCenter = ApprovalCenter.shared
    /// The single-agent runtime, wired to the app's real services.
    public private(set) var orchestrator: AgentOrchestrator?
    /// Tamper-evident record of every agent run, and the count of entries it could not write.
    public let auditChain: AuditChain?
    public let auditHealth = AuditHealth()

    public private(set) var records: [ModuleRecord] = []
    public private(set) var busEntries: [BusEntry] = []
    public private(set) var uiModules: [String: any ModuleUI] = [:]
    public private(set) var chatSession: ChatSession?
    public var activeModuleID: String?
    public private(set) var bootstrapError: String?

    private var catchAllToken: SubscriptionToken?

    public static let appVersion = "0.1.0"

    public init() {
        BuiltInTools.registerAll()
        let schema = Schema([
            Workspace.self, ModuleState.self, Conversation.self, Message.self,
            Artifact.self, ArtifactVersion.self, SettingsEntry.self,
        ])
        let configuration: ModelConfiguration
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let storeDirectory = appSupport.appendingPathComponent("Kiln", isDirectory: true)
            try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: storeDirectory.appendingPathComponent("Kiln.store"))
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            container = (try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))!
            bootstrapError = "Persistent store unavailable (\(error.localizedDescription)); running in-memory."
        }
        self.modelContainer = container

        let eventBus = ModuleEventBus()
        self.eventBus = eventBus
        self.serviceRegistry = ServiceRegistry()
        self.keychain = KeychainService()
        self.modelRegistry = ModelRegistry(eventBus: eventBus)

        let userConfigURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Kiln/settings.json")
        self.settings = SettingsService(userConfigURL: userConfigURL)

        var factories = ModuleFactoryRegistry()
        factories.register(HelloModule.self)
        factories.register(ChatModule.self)
        factories.register(ModelLabModule.self)
        factories.register(REModule.self)

        var manifestDirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ModuleManifests") {
            manifestDirs.append(bundled)
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            manifestDirs.append(appSupport.appendingPathComponent("Kiln/Modules"))
        }

        self.manager = ModuleManager(
            appVersion: Self.appVersion,
            allowedCapabilities: ModuleCapabilities(rawValue: UInt64.max),
            factories: factories,
            manifestDirectories: manifestDirs,
            eventBus: eventBus,
            settings: settings,
            keychain: keychain,
            serviceRegistry: serviceRegistry
        )

        // The agent runtime shares the app's git service and file index,
        // and reads the web-search key from the Keychain. Tools fall back
        // to their own implementations when a service is absent, so this
        // only removes duplication — it never widens what tools may do.
        let keychain = self.keychain
        // Every agent run is recorded into a tamper-evident chain. The head is kept one directory
        // above the log so truncating the log alone is reported, not silently accepted.
        let auditRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kiln", isDirectory: true)
        let auditChain = auditRoot.map {
            AuditChain(directory: $0.appendingPathComponent("Audit", isDirectory: true), headDirectory: $0)
        }
        self.auditChain = auditChain
        self.orchestrator = AgentOrchestrator(
            approvalCenter: approvalCenter,
            services: ToolServices(
                git: gitService,
                fileIndex: fileIndexService,
                webSearchKey: { keychain.get(module: "com.kiln.tools", key: "web-search-key") }
            ),
            auditChain: auditChain,
            // Kiln's own control plane: audit log and head, grants, settings, and the app itself.
            monitor: MonitorPolicy(
                enabled: true, pauseAtSeverity: 5,
                protectedPaths: [auditRoot, Bundle.main.bundleURL].compactMap { $0 }
            ),
            // Model-based monitor pass: OFF unless `monitor.rubricModel` is set, so by default no
            // extra model calls are made and no activity leaves the machine. Calls use
            // completeSilently, which never changes the model the user's chat is using.
            rubric: { [settings = self.settings, registry = self.modelRegistry] in
                let model = await settings.get("monitor.rubricModel", as: String.self, fallback: "")
                guard !model.isEmpty else { return nil }
                let fallback = await settings.get("monitor.rubricFallbackModel", as: String.self, fallback: "")
                return RubricMonitor(model: model, fallbackModel: fallback.isEmpty ? nil : fallback) { model, system, prompt in
                    try await registry.completeSilently(ChatRequest(
                        messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: prompt)],
                        model: model, temperature: 0, maxTokens: 800
                    ))
                }
            },
            auditHealth: auditHealth
        )
    }

    public func bootstrap() async {
        await themeManager.attach(settings: settings)
        catchAllToken = await eventBus.subscribeAny { [weak self] entry in
            guard let self else { return }
            await self.recordBusEntry(entry)
        }
        await registerModelProviders()
        await manager.discoverManifests()
        _ = await manager.loadAll()
        await refreshRecords()
        for record in records where record.module is (any ModuleUI) {
            try? await manager.activate(record.id)
        }
        await refreshRecords()
        if let re = (await manager.record(for: REModule.identifier))?.module as? REModule {
            REAgentTools.register(module: re)
            #if DEBUG
            // Visual-QA hook, compiled out of release builds:
            //   open Kiln.app --args -KilnImportFixture /usr/bin/true
            // imports the binary at launch so analysis views can be checked without the file picker.
            // Skips a fixture already imported on an earlier launch, so relaunches don't pile up copies.
            if let fixture = UserDefaults.standard.string(forKey: "KilnImportFixture") {
                let name = URL(fileURLWithPath: fixture).lastPathComponent
                let alreadyImported = re.projects.contains { $0.binaryURL.lastPathComponent == name }
                if !alreadyImported {
                    _ = try? await re.importBinary(at: URL(fileURLWithPath: fixture))
                }
            }
            #endif
        }
        await syncUIModules()
        if activeModuleID == nil, let firstUI = uiModules.keys.sorted().first {
            await activateModule(firstUI)
        }
    }

    private func registerModelProviders() async {
        let keychain = self.keychain
        let registry = modelRegistry
        await registry.register(OpenCodeProvider(scope: .local))
        await registry.register(OpenCodeProvider(
            scope: .cloud,
            secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "ollama-cloud")
        ))
        await registry.register(OpenRouterProvider(
            secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "openrouter")
        ))
        await registry.register(NVIDIANIMProvider(
            secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "nvidia-nim")
        ))
        await registry.register(CustomEndpointProvider(
            baseURL: await settings.get("providers.custom.baseURL", as: String.self, fallback: ""),
            secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "custom")
        ))
        await registry.register(AppleFoundationProvider())
        await registry.register(MLXProvider())

        let conversations = ConversationStore(container: modelContainer)
        let artifacts = ArtifactStore(container: modelContainer)
        await serviceRegistry.register(modelRegistry, for: ModelRegistry.self)
        await serviceRegistry.register(conversations, for: ConversationStore.self)
        await serviceRegistry.register(artifacts, for: ArtifactStore.self)
        await serviceRegistry.register(ptyManager, for: PTYManager.self)
        await serviceRegistry.register(mcpService, for: MCPClientService.self)
        await serviceRegistry.register(gitService, for: GitService.self)
        await serviceRegistry.register(fileIndexService, for: FileIndexService.self)
        // One session for the whole app: the Agent activity and the dock beside every other activity
        // show the same conversation. The chat module resolves this rather than making its own.
        let session = ChatSession(
            registry: modelRegistry, conversations: conversations, artifacts: artifacts,
            ptyManager: ptyManager, mcpService: mcpService, gitService: gitService,
            fileIndexService: fileIndexService
        )
        chatSession = session
        if let orchestrator { session.attachOrchestrator(orchestrator) }
        await serviceRegistry.register(session, for: ChatSession.self)
    }

    public func shutdown() async {
        await manager.unloadAll()
        await refreshRecords()
    }

    public func refreshRecords() async {
        records = await manager.allRecords()
    }

    public func loadModule(_ identifier: String) async {
        try? await manager.load(identifier)
        await refreshRecords()
        await syncUIModules()
    }

    public func unloadModule(_ identifier: String) async {
        try? await manager.unload(identifier)
        if activeModuleID == identifier {
            activeModuleID = nil
        }
        await refreshRecords()
        await syncUIModules()
    }

    public func activateModule(_ identifier: String) async {
        if !(await manager.isLoaded(identifier)) {
            try? await manager.load(identifier)
        }
        try? await manager.activate(identifier)
        await refreshRecords()
        await syncUIModules()
        activeModuleID = identifier
    }

    public var activeModuleUI: (any ModuleUI)? {
        guard let activeModuleID else { return nil }
        return uiModules[activeModuleID]
    }

    public var activeRecord: ModuleRecord? {
        guard let activeModuleID else { return nil }
        return records.first { $0.id == activeModuleID }
    }

    private func syncUIModules() async {
        var result: [String: any ModuleUI] = [:]
        for record in records {
            guard record.isLoaded, let module = record.module, let ui = module as? (any ModuleUI) else { continue }
            result[record.id] = ui
        }
        uiModules = result
    }

    private func recordBusEntry(_ entry: BusEntry) async {
        busEntries.append(entry)
        if busEntries.count > 100 {
            busEntries.removeFirst(busEntries.count - 100)
        }
    }
}
