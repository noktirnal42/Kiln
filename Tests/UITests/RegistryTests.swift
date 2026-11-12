import Foundation
import Testing
@testable import Kiln

/// The activity registry and the capability registry: the integration rule, enforced.
@MainActor
struct ActivityRegistryTests {
    private let registry = ActivityRegistry.standard

    @Test func theActivitiesKeepTheirOrderSidebarAndShortcuts() {
        #expect(registry.descriptors.map(\.id) ==
                ["home", "agent", "swarm", "develop", "analyze", "lab", "audit", "browser", "devices", "media", "images", "maps", "news"])
        #expect(Activity.allCases.compactMap { $0.shortcutKey.map(String.init) } == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        // Home has the logo and Agent has New chat; the rest are the sidebar's Workstation list, in order.
        #expect(Activity.allCases.filter(\.descriptor.showsInSidebar).map(\.id) ==
                ["swarm", "develop", "analyze", "lab", "audit", "browser", "devices", "media", "images", "maps", "news"])
    }

    @Test func idsAreUniqueAndEveryActivityIsComplete() {
        let ids = registry.descriptors.map(\.id)
        #expect(Set(ids).count == ids.count)
        for descriptor in registry.descriptors {
            #expect(!descriptor.title.isEmpty && !descriptor.symbol.isEmpty && !descriptor.summary.isEmpty)
            #expect(!descriptor.starterPrompts(true).isEmpty && !descriptor.starterPrompts(false).isEmpty, "\(descriptor.id) has no starter prompts")
        }
    }

    @Test func moreThanTenActivitiesNeverShareAShortcut() {
        func descriptor(_ id: String) -> ActivityDescriptor {
            ActivityDescriptor(id: id, title: id, symbol: "circle", summary: id)
        }
        let big = ActivityRegistry((0..<12).map { descriptor("a\($0)") })
        let keys = (0..<12).compactMap { big.shortcutKey(for: "a\($0)") }
        #expect(keys.count == 10 && Set(keys).count == 10, "the 11th and 12th get no shortcut rather than a duplicate")
        let quiet = ActivityRegistry([descriptor("x"), { var d = descriptor("y"); d.shortcut = .none; return d }(), descriptor("z")])
        #expect(quiet.shortcutKey(for: "x") == "1" && quiet.shortcutKey(for: "y") == nil && quiet.shortcutKey(for: "z") == "2")
    }

    @Test func policyPrefixesComeFromTheRegistryAndMatchTheOldList() {
        #expect(Set(ExecutionPolicy.moduleToolPrefixes) ==
                ["re_", "lab_", "swarm_", "mcp_", "computer_", "browser_", "device_", "media_", "ide_", "image_", "maps_", "news_", "mail_"])
        #expect(ExecutionPolicy.isModuleTool("media_open") && !ExecutionPolicy.isModuleTool("read_file"))
    }

    @Test func theWorkstationAgentIsDerivedFromTheRegistry() {
        let profile = AgentProfile.builtIns.first { $0.name == "Workstation Agent" }
        let enabled = profile?.toolPermissions.enabledTools ?? []
        for pattern in ["re_*", "lab_*", "browser_*", "device_*", "media_*", "mcp_*", "computer_use", "read_file", "git_commit"] {
            #expect(enabled.contains(pattern), "\(pattern) missing from the Workstation Agent")
        }
        #expect(!enabled.contains("swarm_*"), "swarm tools belong to workers, not the Workstation Agent")
        let prompt = profile?.systemPrompt ?? ""
        for fragment in ["re_* tools", "lab_* tools", "media_* tools", "device_* tools", "browser_* tools", "list_skills", "computer_use"] {
            #expect(prompt.contains(fragment), "prompt lost \(fragment)")
        }
    }

    @Test func aNewModuleAppearsEverywhereFromOneDescriptor() {
        var extra = ActivityDescriptor(id: "notes", title: "Notes", symbol: "note.text", summary: "Notes")
        extra.toolPrefixes = ["notes_"]
        extra.agentPromptSentence = "Use the notes_* tools to keep notes."
        extra.capabilities = [.tool("notes_add", "Add a note", .write)]
        let bigger = ActivityRegistry(registry.descriptors + [extra])
        #expect(bigger.shortcutKey(for: "notes") == nil, "the eleventh activity has no shortcut yet")
        #expect(bigger.toolPrefixes.contains("notes_"))
        #expect(bigger.agentToolPatterns.contains("notes_*"))
        #expect(AgentProfile.workstationAgent(registry: bigger).systemPrompt.contains("notes_* tools"))
        #expect(bigger.capabilities.last?.module == "notes")
    }

    @Test func capabilitiesAreSearchOnlyPaletteCommandsThatOpenTheirActivity() throws {
        let suiteName = "kiln.tests.\(UUID().uuidString)"
        let defaults = TestDefaults.suite(suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workstation = WorkstationModel(defaults: defaults)
        let capabilityCommands = workstation.capabilityCommands { workstation.selected = $0 }
        #expect(capabilityCommands.count == CapabilityRegistry.all.count)
        #expect(CommandRanking.rank(capabilityCommands, query: "").isEmpty, "the default palette stays short")
        let hits = CommandRanking.rank(capabilityCommands, query: "browser_open")
        #expect(hits.contains { $0.id == "capability.browser_open" })
        let open = try #require(hits.first { $0.id == "capability.browser_open" })
        workstation.selected = .home
        open.run()
        #expect(workstation.selected == .browser)
    }
}

@MainActor
struct CapabilityRegistryTests {
    /// Every tool the app registers, built the way `AppModel` does: built-ins plus each activity's own registration.
    static func fullToolRegistry() async -> ToolRegistry {
        let registry = ToolRegistry()
        BuiltInTools.registerAll(into: registry)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-capability-\(UUID().uuidString)")
        let modules: [String: Any] = [
            REModule.identifier: REModule(),
            ModelLabModule.identifier: ModelLabModule(),
            BrowserModule.identifier: BrowserModule(dataStore: .nonPersistent(), downloadsFolder: folder),
            DevicesModule.identifier: DevicesModule(),
            MediaModule.identifier: MediaModule(),
            ImageStudioModule.identifier: ImageStudioModule(),
        ]
        await ActivityRegistry.standard.registerTools(ToolRegistrationContext(registry: registry, loadedModule: { modules[$0] },
            develop: DevelopController(editor: EditorWorkspace(), builder: BuildRunner())))
        return registry
    }

    static func workerToolSpecs() async throws -> [ToolSpec] {
        let bus = CoordinationBus()
        let endpoint = try await bus.register(agent: "worker.capability")
        return SwarmBusTools.make(endpoint: endpoint, task: SwarmTask(id: "x", title: "X", role: .researcher), blocker: BlockerBox()).map(\.spec)
    }

    @Test func everyCapabilityHasAnAgentToolOrAWrittenReason() {
        var seen = Set<String>()
        for capability in CapabilityRegistry.all {
            #expect(seen.insert(capability.id).inserted, "duplicate capability id \(capability.id)")
            #expect(ActivityRegistry.standard.descriptor(capability.module) != nil, "\(capability.id) names no activity")
            #expect(!capability.title.isEmpty)
            if capability.agentTool == nil {
                let reason = capability.exemption ?? ""
                #expect(reason.count >= 40, "\(capability.id) has neither an agent tool nor a written exemption (it would ship GUI-only)")
            } else if !capability.workerScoped {
                #expect(capability.exemption == nil, "\(capability.id) has a tool; it should not also carry an exemption")
            }
        }
    }

    @Test func everyToolBackedCapabilityIsRegisteredWithTheSamePermission() async throws {
        let registry = await Self.fullToolRegistry()
        let workers = try await Self.workerToolSpecs()
        for capability in CapabilityRegistry.all {
            guard let name = capability.agentTool else { continue }
            let spec = capability.workerScoped ? workers.first { $0.name == name } : registry.tool(named: name)?.spec
            #expect(spec != nil, "\(capability.id): agent tool \(name) is not registered")
            #expect(spec?.permission == capability.permission, "\(capability.id): permission differs from tool \(name)")
        }
    }

    @Test func everyRegisteredToolHasACapability() async throws {
        let registry = await Self.fullToolRegistry()
        let claimed = Set(CapabilityRegistry.all.compactMap(\.agentTool))
        for spec in registry.allSpecs() {
            #expect(claimed.contains(spec.name), "tool \(spec.name) has no capability; declare it in its module's descriptor")
        }
        let workers = try await Self.workerToolSpecs()
        for spec in workers { #expect(claimed.contains(spec.name), "worker tool \(spec.name) has no capability") }
    }

    @Test func everyModuleToolIsReachableThroughTheMCPToolList() async throws {
        let registry = await Self.fullToolRegistry()
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: nil)
        watcher.cancel()
        let handler = KilnMCPHandler(orchestrator: AgentOrchestrator(toolRegistry: registry, approvalCenter: center), registry: registry)
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"] as [String: Any])
        let reply = try #require(await handler.handle(body))
        let result = try #require((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any])
        let listed = Set((result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })

        let moduleTools = registry.allSpecs().map(\.name).filter { ExecutionPolicy.isModuleTool($0) }
        #expect(!moduleTools.isEmpty)
        for name in moduleTools { #expect(listed.contains(name), "\(name) is a module tool but MCP does not list it") }
        // Worker-scoped tools are the one deliberate exception, and each says why.
        for capability in CapabilityRegistry.all where capability.workerScoped {
            #expect(!listed.contains(capability.agentTool ?? ""))
            #expect(capability.exemption != nil)
        }
    }

    @Test func gapsAreListedInTheCapabilityMatrixDocument() throws {
        // docs/13 carries the human-readable list; keep it from silently drifting behind the code.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try? String(contentsOf: root.appendingPathComponent("docs/13-AGENT-CAPABILITY-MATRIX.md"), encoding: .utf8)
        guard let doc else { return }   // running from an installed bundle without the repo: nothing to compare
        for capability in CapabilityRegistry.gaps where capability.exemption?.hasPrefix("Gap") == true {
            #expect(doc.contains("`\(capability.id)`"), "gap \(capability.id) is missing from docs/13-AGENT-CAPABILITY-MATRIX.md")
        }
    }
}
