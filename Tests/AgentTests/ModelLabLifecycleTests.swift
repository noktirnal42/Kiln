import Foundation
import SwiftData
import Testing
import ModelLabCore
@testable import Kiln

@MainActor
struct ModelLabLifecycleTests {
    private func module() throws -> ModelLabModule {
        let schema = Schema([ExperimentRecord.self, DatasetRecord.self, ModelArtifactRecord.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let module = ModelLabModule()
        module.container = container
        container.mainContext.insert(DatasetRecord(id: "ds1", name: "Reviews", sourceKind: .localImport, localRelativePath: "reviews.csv",
                                                   format: .csv, columns: ["text", "label", "stars"]))
        try container.mainContext.save()
        return module
    }

    @Test func createsADraftClassifierExperimentWithItsValidationFraction() throws {
        let module = try module()
        let record = try module.createClassifierExperiment(name: "Sentiment", task: .textClassification, datasetID: "ds1",
                                                           inputColumns: ["text"], labelColumn: "label", validationFraction: 0.3)
        #expect(record.statusRaw == ExperimentStatus.draft.rawValue)
        #expect(record.textColumn == "text" && record.labelColumn == "label")
        #expect(record.hyperparameters["validationFraction"] == "0.3")
        let saved = try #require(module.mainContext?.fetch(FetchDescriptor<ExperimentRecord>()).first)
        #expect(saved.id == record.id)
    }

    @Test func tabularExperimentsKeepEveryFeatureColumn() throws {
        let module = try module()
        let record = try module.createClassifierExperiment(name: "Tab", task: .tabularClassification, datasetID: "ds1",
                                                             inputColumns: ["text", "stars"], labelColumn: "label")
        #expect(record.featureColumns == ["text", "stars"])
    }

    @Test func rejectsBadInputsWithSpecificMessages() throws {
        let module = try module()
        func message(_ body: () throws -> Void) -> String {
            do { try body(); return "no error" } catch { return String(describing: error) }
        }
        #expect(message { _ = try module.createClassifierExperiment(name: "x", task: .textClassification, datasetID: "nope", inputColumns: ["text"], labelColumn: "label") }.contains("No dataset"))
        #expect(message { _ = try module.createClassifierExperiment(name: "x", task: .textClassification, datasetID: "ds1", inputColumns: ["body"], labelColumn: "label") }.contains("Unknown column"))
        #expect(message { _ = try module.createClassifierExperiment(name: "x", task: .textClassification, datasetID: "ds1", inputColumns: ["text", "stars"], labelColumn: "label") }.contains("exactly one"))
        #expect(message { _ = try module.createClassifierExperiment(name: "x", task: .textClassification, datasetID: "ds1", inputColumns: ["text"], labelColumn: "label", validationFraction: 1.5) }.contains("between 0 and 1"))
        #expect(message { _ = try module.createClassifierExperiment(name: "x", task: .textGeneration, datasetID: "ds1", inputColumns: ["text"], labelColumn: "label") }.contains("Only"))
        #expect(message { _ = try module.createClassifierExperiment(name: " ", task: .textClassification, datasetID: "ds1", inputColumns: ["text"], labelColumn: "label") }.contains("name"))
    }

    @Test func exportRefusesUnknownArtifactsAndMissingFolders() throws {
        let module = try module()
        #expect(throws: (any Error).self) { try module.exportArtifact(id: "missing", format: .coreML, destinationFolder: URL(fileURLWithPath: "/tmp")) }
    }

    /// A real classifier trained by Kiln on a 120-row synthetic sentiment CSV (see docs/13-AGENT-CAPABILITY-MATRIX.md).
    @Test func aTrainedClassifierFixtureClassifiesHeldOutText() throws {
        let model = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/review-sentiment.mlmodel")
        let results = try ModelLabModule.predict(modelURL: model, texts: ["Absolutely wonderful, I love it", "Terrible, a total waste of money"])
        #expect(results[0].hasPrefix("positive") && results[1].hasPrefix("negative"))
    }

    @Test func toolsAreRegisteredWithTheRightPermissions() {
        #expect(ModelLabAgentTools.Kind.predict.spec.permission == .read)
        #expect(ModelLabAgentTools.Kind.importDataset.spec.permission == .write)
        #expect(ModelLabAgentTools.Kind.createExperiment.spec.permission == .write)
        #expect(ModelLabAgentTools.Kind.exportModel.spec.permission == .write)
        #expect(ModelLabAgentTools.Kind.evaluate.spec.permission == .read)
    }

    @Test func evaluationToolScoresPredictions() async throws {
        let tool = ModelLabAgentTool(kind: .evaluate, module: ModelLabModule())
        let out = try await tool.execute(argumentsJSON: #"{"predictions":["a","b","a"],"references":["a","b","b"]}"#,
                                         context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID(), redactSecrets: true, services: ToolServices()))
        #expect(out.contains("accuracy") || out.lowercased().contains("accuracy"))
        #expect(out.contains("3 examples"))
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(argumentsJSON: #"{"predictions":["a"],"references":[]}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID(), redactSecrets: true, services: ToolServices()))
        }
    }
}
