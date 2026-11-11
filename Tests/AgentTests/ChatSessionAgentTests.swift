import Foundation
import Testing
import SwiftData
import ModelLabCore
@testable import Kiln

@MainActor
struct ChatSessionAgentTests {
    @Test func configuredLimitPausesQueueAndCanContinue() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        struct Provider: Kiln.ModelProvider {
            let counter: Counter
            let id = "stub"
            let name = "Stub"
            let providerType: ProviderType = .customEndpoint
            let capabilities: ProviderCapabilities = [.streaming, .tools]
            func fetchModels() async throws -> [ModelDescriptor] {
                [ModelDescriptor(id: "stub-m1", name: "m1", providerID: id, providerType: providerType, supportsTools: true)]
            }
            func checkAvailability() async -> ProviderAvailability { .available() }
            func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
                let number = counter.next()
                return AsyncThrowingStream { c in
                    Task {
                        if number == 1 {
                            try? await Task.sleep(for: .milliseconds(200))
                            c.yield(ChatChunk(finishReason: .toolCalls, toolCalls: [ToolCall(id: "call-1", name: "read_file", arguments: #"{"path":"a.txt"}"#)]))
                        } else {
                            c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: "Done."), finishReason: .stop))
                        }
                        c.finish()
                    }
                }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "sample".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let registry = ModelRegistry(eventBus: ModuleEventBus())
        await registry.register(Provider(counter: Counter()))
        let limits = AgentRoundLimits(defaults: nil)
        #expect(limits.set(1, for: "Workstation Agent"))
        let session = ChatSession(registry: registry, conversations: ConversationStore(container: container), artifacts: ArtifactStore(container: container), workspaceRoot: root.path, roundLimits: limits)
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: nil)
        defer { watcher.cancel() }
        session.attachOrchestrator(AgentOrchestrator(toolRegistry: ToolRegistry(tools: [ReadFileTool()]), approvalCenter: center))
        await session.newConversation()
        session.selectedModelID = "stub-m1"
        let run = Task { await session.send("Read the file") }
        for _ in 0..<100 where !session.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.isStreaming)
        await session.send("queued follow-up")
        await run.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.pausedAfterRounds == 1)
        #expect(session.queuePaused && session.queuedMessages.map(\.text) == ["queued follow-up"])
        await session.continuePausedRun()
        #expect(session.messages.contains { $0.role == .user && $0.content.hasPrefix("Continue the previous task.") })
        for _ in 0..<100 where !session.queuedMessages.isEmpty || session.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func record(_ id: UUID, _ status: ToolCallStatus) -> ToolCallRecord {
        ToolCallRecord(id: id, toolName: "read_file", argumentsJSON: "{\"path\":\"a.txt\"}", status: status)
    }

    @Test func aToolCallIsUpdatedInPlaceNotDuplicated() {
        var activity: [ToolCallRecord] = []
        let id = UUID()
        ChatSession.apply(.toolCallStarted(record(id, .running)), to: &activity)
        ChatSession.apply(.toolCallFinished(record(id, .succeeded)), to: &activity)
        #expect(activity.count == 1)
        #expect(activity[0].status == .succeeded)
    }

    @Test func separateCallsKeepTheirOrder() {
        var activity: [ToolCallRecord] = []
        let first = UUID(), second = UUID()
        ChatSession.apply(.toolCallStarted(record(first, .running)), to: &activity)
        ChatSession.apply(.toolCallStarted(record(second, .running)), to: &activity)
        #expect(activity.map(\.id) == [first, second])
    }

    @Test func nonToolEventsLeaveActivityAlone() {
        var activity: [ToolCallRecord] = []
        ChatSession.apply(.textDelta("hi"), to: &activity)
        ChatSession.apply(.roundStarted(1), to: &activity)
        #expect(activity.isEmpty)
    }
}

struct ModuleToolAccessTests {
    @Test func prefixEntriesEnableModuleToolsButNothingElse() {
        let set = ToolPermissionSet(enabledTools: ["read_file", "re_*"])
        #expect(set.isEnabled("re_list_functions"))
        #expect(set.isEnabled("read_file"))
        #expect(!set.isEnabled("lab_hardware"))
        #expect(!set.isEnabled("write_file"))
    }

    @Test func theWorkstationAgentReachesReAndLabToolsUnderEveryGate() throws {
        let profile = try #require(AgentProfile.builtIns.first { $0.name == "Workstation Agent" })
        let registry = ToolRegistry(tools: [])
        let policy = ExecutionPolicy(mode: profile.mode)
        #expect(policy.checkTool("re_list_functions").verdict == .allow)
        #expect(policy.checkTool("lab_hardware").verdict == .allow)
        #expect(policy.checkTool("rm_everything").verdict == .deny)
        #expect(profile.toolPermissions.isEnabled("lab_search_models"))
        _ = registry
    }
}

struct TextToolCallTests {
    private let offered: Set<String> = ["read_file", "list_directory"]

    @Test func aBareJSONCallToAnOfferedToolIsRecognised() throws {
        let call = try #require(TextToolCall.parse(#"{"name":"read_file","arguments":{"path":"notes.txt"}}"#, offered: offered))
        #expect(call.name == "read_file")
        #expect(call.arguments.contains("notes.txt"))
    }

    @Test func aFencedCallIsRecognisedToo() throws {
        let text = "```json\n{\n  \"name\": \"list_directory\",\n  \"arguments\": {}\n}\n```"
        #expect(TextToolCall.parse(text, offered: offered)?.name == "list_directory")
    }

    @Test func proseUnknownToolsAndExtraKeysNeverTrigger() {
        #expect(TextToolCall.parse("I will call read_file now", offered: offered) == nil)
        #expect(TextToolCall.parse(#"{"name":"delete_file","arguments":{}}"#, offered: offered) == nil)
        #expect(TextToolCall.parse(#"Sure! {"name":"read_file","arguments":{}}"#, offered: offered) == nil)
        #expect(TextToolCall.parse(#"{"name":"read_file","arguments":{},"run":"rm -rf /"}"#, offered: offered) == nil)
    }

    @Test func severalCallsInARowAreAllRecognisedInOrder() {
        let text = #"{"name": "list_directory", "arguments": {"path": "/"}} {"name": "read_file", "arguments": {"path": "Package.swift"}}"#
        let calls = TextToolCall.parseAll(text, offered: offered)
        #expect(calls.map(\.name) == ["list_directory", "read_file"])
        #expect(calls.map(\.index) == [0, 1])
        #expect(Set(calls.map(\.id)).count == 2, "each call gets its own id")
        #expect(calls[1].arguments.contains("Package.swift"))
    }

    @Test func commaSeparatedLinesAndArraysWorkToo() {
        let lines = "{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}},\n{\"name\":\"read_file\",\"arguments\":{\"path\":\"b\"}}"
        #expect(TextToolCall.parseAll(lines, offered: offered).count == 2)
        #expect(TextToolCall.parseAll("[" + lines + "]", offered: offered).count == 2)
        #expect(TextToolCall.parseAll("```json\n" + lines + "\n```", offered: offered).count == 2)
    }

    @Test func braceCharactersInsideStringsDoNotBreakSplitting() {
        let text = #"{"name":"read_file","arguments":{"path":"we{ird}.txt"}} {"name":"list_directory","arguments":{}}"#
        #expect(TextToolCall.parseAll(text, offered: offered).map(\.name) == ["read_file", "list_directory"])
    }

    @Test func manyCallsAreAllOrNothing() {
        let good = #"{"name":"read_file","arguments":{}}"#
        #expect(TextToolCall.parseAll(good + #" {"name":"echo","arguments":{}}"#, offered: offered).isEmpty, "one unknown tool and none run")
        #expect(TextToolCall.parseAll(good + " and then " + good, offered: offered).isEmpty, "prose between calls")
        #expect(TextToolCall.parseAll(good + #" {"name":"read_file","arguments"#, offered: offered).isEmpty, "a truncated second call")
        #expect(TextToolCall.parseAll("Sure: " + good, offered: offered).isEmpty)
        #expect(TextToolCall.parseAll(String(repeating: good, count: 9), offered: offered).isEmpty, "more than eight calls is not a plan, it is a loop")
        #expect(TextToolCall.parseAll("", offered: offered).isEmpty)
    }

    @Test func aSingleCallStillParsesTheSameWay() {
        #expect(TextToolCall.parseAll(#"{"name":"read_file","arguments":{"path":"x"}}"#, offered: offered).count == 1)
    }
}

@MainActor
struct ApprovalActivityTests {
    @Test func aCallWaitingOnApprovalIsShownAsSuchThenRunning() {
        var activity: [ToolCallRecord] = []
        let id = UUID()
        ChatSession.apply(.toolCallStarted(ToolCallRecord(id: id, toolName: "write_file", argumentsJSON: "{}")), to: &activity)
        let request = ApprovalRequest(toolName: "write_file", toolSummary: "", argumentsJSON: "{}", permission: .write,
                                      isDestructive: false, preview: "", consequences: "")
        ChatSession.apply(.awaitingApproval(request), to: &activity)
        #expect(activity[0].status == .awaitingApproval)
        ChatSession.apply(.approvalResolved(id: request.id, approved: true), to: &activity)
        #expect(activity[0].status == .running)
    }
}

struct ModelLabActionToolTests {
    @Test func statusIsReadOnlyAndCancellationRequiresWriteApproval() {
        #expect(ModelLabAgentTools.Kind.experiment.spec.permission == .read)
        #expect(ModelLabAgentTools.Kind.cancelTraining.spec.permission == .write)
        #expect(ModelLabAgentTools.Kind.cancelTraining.spec.name == "lab_cancel_training")
    }

    @Test func exactExperimentIDIsRequired() throws {
        #expect(throws: ModelLabToolError.self) { try ModelLabAgentTool.experimentID([:]) }
        #expect(throws: ModelLabToolError.self) { try ModelLabAgentTool.experimentID(["experiment_id": "  "]) }
        #expect(try ModelLabAgentTool.experimentID(["experiment_id": " run-1 "]) == "run-1")
    }

    @MainActor
    @Test func cancellationNeverTargetsAnUnrelatedRun() {
        let module = ModelLabModule()
        #expect(throws: ModelLabToolError.self) { try ModelLabAgentTool.cancelTraining(module, id: "unknown-run") }
    }
}

@MainActor
struct ModelLifecycleToolTests {
    private func context() throws -> ModelContext {
        let schema = Schema([ModelArtifactRecord.self])
        return ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    @Test func specsDeclareTheirPermissionTiers() {
        #expect(ModelLabAgentTools.Kind.listModels.spec.permission == .read)
        #expect(ModelLabAgentTools.Kind.registerModel.spec.permission == .write)
        #expect(ModelLabAgentTools.Kind.deleteModel.spec.permission == .execute)
        #expect(ModelLabAgentTools.Kind.registerModel.spec.name == "lab_register_model")
    }

    @Test func registerListAndDeleteARepositoryWithoutDownloading() throws {
        let context = try context()
        #expect(try ModelLabAgentTool.models(context: context, limit: 10) == "No models registered.")
        let message = try ModelLabAgentTool.registerModel(context: context, repo: "kiln-test-org/never-downloaded-model")
        #expect(message.contains("Nothing was downloaded"))
        _ = try ModelLabAgentTool.registerModel(context: context, repo: "kiln-test-org/never-downloaded-model")
        let listing = try ModelLabAgentTool.models(context: context, limit: 10)
        #expect(listing.components(separatedBy: "\n").count == 1 && listing.contains("not cached"))
        let id = try #require(try context.fetch(FetchDescriptor<ModelArtifactRecord>()).first?.id)
        #expect(try ModelLabAgentTool.deleteModel(context: context, id: id).contains("cache was not touched"))
        #expect(try ModelLabAgentTool.models(context: context, limit: 10) == "No models registered.")
    }

    @Test func badRepositoryIdsAndUnknownModelsAreRejected() throws {
        let context = try context()
        for bad in ["no-slash", "../etc/passwd", "a/b/c", "org/", "org/na me"] {
            #expect(throws: ModelLabToolError.self) { try ModelLabAgentTool.registerModel(context: context, repo: bad) }
        }
        #expect(throws: ModelLabToolError.self) { try ModelLabAgentTool.deleteModel(context: context, id: "missing") }
    }
}

@MainActor
struct ClassifierTrainingActionTests {
    private func fixture() throws -> (URL, ExperimentRecord, DatasetRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-classifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "text,label\ngreat,positive\npoor,negative\n".write(to: root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        let dataset = DatasetRecord(id: "fixture", name: "Fixture", sourceKind: .localImport, localRelativePath: "data.csv", format: .csv)
        let experiment = ExperimentRecord(name: "../../untrusted display name", task: .textClassification, datasetID: dataset.id, textColumn: "text", labelColumn: "label")
        return (root, experiment, dataset)
    }

    @Test func usesSavedConfigurationAndUniqueSafeArtifacts() throws {
        let (root, experiment, dataset) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ModelLabModule.classifierTrainingJob(experiment: experiment, dataset: dataset, datasetsRoot: root)
        let second = try ModelLabModule.classifierTrainingJob(experiment: experiment, dataset: dataset, datasetsRoot: root)
        #expect(first.textOrFeatureColumns == ["text"])
        #expect(first.labelColumn == "label")
        #expect(first.validationFraction == 0.2)
        #expect(!first.outputName.contains("/") && first.outputName != second.outputName)
        #expect(ModelLabAgentTools.Kind.startTraining.spec.permission == .execute)
    }

    @Test func rejectsEscapesMissingDataAndCompletedRuns() throws {
        let (root, experiment, dataset) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside.csv", "/tmp/outside.csv", "missing.csv", ""] {
            dataset.localRelativePath = path
            #expect(throws: ModelLabModuleError.self) { try ModelLabModule.classifierTrainingJob(experiment: experiment, dataset: dataset, datasetsRoot: root) }
        }
        dataset.localRelativePath = "data.csv"
        experiment.status = .completed
        #expect(throws: ModelLabModuleError.self) { try ModelLabModule.classifierTrainingJob(experiment: experiment, dataset: dataset, datasetsRoot: root) }
    }

    @Test func rejectsInvalidConfigurationAndSymlinkEscapes() throws {
        let (root, experiment, dataset) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for fraction in ["nan", "1", "0", "invalid"] {
            experiment.hyperparameters = ["validationFraction": fraction]
            #expect(throws: ModelLabModuleError.self) { try ModelLabModule.classifierTrainingJob(experiment: experiment, dataset: dataset, datasetsRoot: root) }
        }
        experiment.hyperparameters = [:]
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).csv")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.csv"), withDestinationURL: outside)
        dataset.localRelativePath = "escape.csv"
        #expect(throws: ModelLabModuleError.self) { try ModelLabModule.classifierTrainingJob(experiment: experiment, dataset: dataset, datasetsRoot: root) }
    }
}


@MainActor
struct ExperimentDraftConfigurationTests {
    @Test func savedTabularFeaturesReachTheTrainingJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-tabular-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "age,income,label\n23,40000,yes\n45,85000,no\n".write(to: root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        let schema = Schema([ExperimentRecord.self, DatasetRecord.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let writer = ModelContext(container)
        let dataset = DatasetRecord(id: "tabular-fixture", name: "Fixture", sourceKind: .localImport,
                                    localRelativePath: "data.csv", format: .csv)
        let draft = ModelLabModule.makeExperimentDraft(name: "Tabular", task: .tabularClassification,
            datasetID: dataset.id, inputColumnsText: " age, income, ,age ", labelColumnText: " label ")
        writer.insert(dataset)
        writer.insert(draft)
        try writer.save()
        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(FetchDescriptor<ExperimentRecord>()).first)
        let savedDataset = try #require(reader.fetch(FetchDescriptor<DatasetRecord>()).first)
        let job = try ModelLabModule.classifierTrainingJob(experiment: saved, dataset: savedDataset, datasetsRoot: root)
        #expect(saved.textColumn == nil)
        #expect(saved.featureColumns == ["age", "income"])
        #expect(job.textOrFeatureColumns == ["age", "income"])
        #expect(job.labelColumn == "label")
    }

    @Test func textClassificationKeepsASingleColumnName() {
        let draft = ModelLabModule.makeExperimentDraft(name: "Text", task: .textClassification,
            datasetID: "fixture", inputColumnsText: " message, body ", labelColumnText: " category ")
        #expect(draft.textColumn == "message, body")
        #expect(draft.featureColumns.isEmpty)
        #expect(draft.labelColumn == "category")
    }

    @Test func nonClassifierTasksDiscardStaleColumnFields() {
        let draft = ModelLabModule.makeExperimentDraft(name: "LM", task: .smallLMPretraining,
            datasetID: "fixture", inputColumnsText: "age,income", labelColumnText: "label")
        #expect(draft.textColumn == nil)
        #expect(draft.labelColumn == nil)
        #expect(draft.featureColumns.isEmpty)
    }
}
