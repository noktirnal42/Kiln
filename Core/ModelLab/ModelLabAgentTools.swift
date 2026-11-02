import Foundation
import SwiftData
import ModelLabCore

/// Model Lab as agent tools. Reads are local; the two searches reach Hugging Face, so they are
/// `.execute` and go through approval like any other network call. Training cancellation
/// is a write action and targets only the explicitly named running experiment.
public enum ModelLabAgentTools {
    public static let prefix = "lab_"

    @MainActor
    public static func register(module: ModelLabModule, into registry: ToolRegistry = .shared) {
        for tool in Kind.allCases {
            registry.register(ModelLabAgentTool(kind: tool, module: module))
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case hardware, experiments, datasets
        case experiment = "get_experiment"
        case startTraining = "start_training"
        case cancelTraining = "cancel_training"
        case searchModels = "search_models"
        case searchDatasets = "search_datasets"

        var spec: ToolSpec {
            switch self {
            case .hardware:
                ToolSpec(name: "lab_hardware", summary: "Report this Mac's chip, memory and the largest model it can comfortably load.",
                         permission: .read)
            case .experiments:
                ToolSpec(name: "lab_list_experiments", summary: "List Model Lab experiments with task, status and base model.",
                         parameters: [ToolParam(name: "limit", type: "integer", description: "Most recent first; default 25", required: false)],
                         permission: .read)
            case .experiment:
                ToolSpec(name: "lab_get_experiment", summary: "Read one Model Lab experiment's status, recent metrics and produced artifact.",
                         parameters: [ToolParam(name: "experiment_id", description: "Exact ID from lab_list_experiments")], permission: .read)
            case .startTraining:
                ToolSpec(name: "lab_start_training", summary: "Start an existing Create ML classifier experiment using its registered local dataset and saved configuration. Uses compute and writes a new artifact; requires approval. Does not start LoRA or other training types. Poll lab_get_experiment for progress.",
                         parameters: [ToolParam(name: "experiment_id", description: "Exact ID of a draft, failed or cancelled classifier experiment")], permission: .execute)
            case .cancelTraining:
                ToolSpec(name: "lab_cancel_training", summary: "Request cancellation of the named running Model Lab experiment. Cancellation is cooperative; poll lab_get_experiment for its final state.",
                         parameters: [ToolParam(name: "experiment_id", description: "Exact ID of the running experiment")], permission: .write)
            case .datasets:
                ToolSpec(name: "lab_list_datasets", summary: "List datasets registered in Model Lab with format, size and columns.",
                         parameters: [ToolParam(name: "limit", type: "integer", description: "Default 25", required: false)],
                         permission: .read)
            case .searchModels:
                ToolSpec(name: "lab_search_models", summary: "Search Hugging Face for models.",
                         parameters: [ToolParam(name: "query", description: "Search text")], permission: .execute)
            case .searchDatasets:
                ToolSpec(name: "lab_search_datasets", summary: "Search Hugging Face for datasets.",
                         parameters: [ToolParam(name: "query", description: "Search text")], permission: .execute)
            }
        }
    }
}

struct ModelLabAgentTool: ToolExecuting {
    let kind: ModelLabAgentTools.Kind
    let module: ModelLabModule

    var spec: ToolSpec { kind.spec }

    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        let limit = max(1, min(200, (args["limit"] as? Int) ?? 25))
        switch kind {
        case .hardware:
            return await MainActor.run { Self.describe(module.hardware) }
        case .experiments:
            return try await MainActor.run { try Self.experiments(module, limit: limit) }
        case .experiment:
            let id = try Self.experimentID(args)
            return try await MainActor.run { try Self.experiment(module, id: id) }
        case .startTraining:
            let id = try Self.experimentID(args)
            try await module.startClassifierExperiment(id: id)
            return "Training started for experiment \(id). This does not mean training succeeded. Poll lab_get_experiment for status, errors and the produced artifact."
        case .cancelTraining:
            let id = try Self.experimentID(args)
            return try await MainActor.run { try Self.cancelTraining(module, id: id) }
        case .datasets:
            return try await MainActor.run { try Self.datasets(module, limit: limit) }
        case .searchModels:
            let query = try Self.query(args)
            let results = try await module.searchHuggingFaceModels(query: query)
            return Self.lines(results.prefix(20).map {
                "\($0.id) · \($0.pipelineTag ?? "?") · \($0.downloads.map(String.init) ?? "?") downloads"
            }, empty: "No models found for “\(query)”.")
        case .searchDatasets:
            let query = try Self.query(args)
            let results = try await module.searchHuggingFaceDatasets(query: query)
            return Self.lines(results.prefix(20).map { "\($0.id) · \($0.downloads.map(String.init) ?? "?") downloads" },
                              empty: "No datasets found for “\(query)”.")
        }
    }

    // MARK: Pure formatting (tested)

    static func query(_ args: [String: Any]) throws -> String {
        let text = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModelLabToolError.missingQuery }
        return text
    }

    static func lines(_ rows: [String], empty: String) -> String {
        rows.isEmpty ? empty : rows.joined(separator: "\n")
    }

    static func describe(_ hardware: HardwareProfile) -> String {
        let chip = hardware.isAppleSilicon ? "Apple Silicon" : "Intel"
        let limitGB = Double(hardware.recommendedWorkingLimitBytes) / 1_073_741_824
        return "\(chip), \(hardware.memoryGB) GB unified memory, \(hardware.coreCount) cores"
            + (hardware.metalDeviceName.map { ", GPU \($0)" } ?? "")
            + String(format: ". Working limit about %.1f GB for model weights plus overhead.", limitGB)
    }

    static func experimentID(_ args: [String: Any]) throws -> String {
        let id = ((args["experiment_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ModelLabToolError.missingExperimentID }
        return id
    }

    @MainActor
    private static func experiment(_ module: ModelLabModule, id: String) throws -> String {
        guard let context = module.mainContext else { throw ModelLabToolError.storeUnavailable }
        let descriptor = FetchDescriptor<ExperimentRecord>(predicate: #Predicate { $0.id == id })
        guard let experiment = try context.fetch(descriptor).first else { throw ModelLabToolError.experimentNotFound(id) }
        let metrics = experiment.metricsHistory.suffix(20).map { point in
            ["metric": point.name, "value": point.value] as [String: Any]
        }
        var payload: [String: Any] = [
            "id": experiment.id, "name": experiment.name, "task": experiment.taskRaw,
            "status": experiment.statusRaw, "dataset_id": experiment.datasetID,
            "recent_metrics": metrics
        ]
        payload["artifact_id"] = experiment.producedArtifactID
        payload["error"] = experiment.errorMessage
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func cancelTraining(_ module: ModelLabModule, id: String) throws -> String {
        if module.createMLCoordinator.runningExperimentID == id { module.createMLCoordinator.cancel() }
        else if module.mlxFineTuningCoordinator.runningExperimentID == id { module.mlxFineTuningCoordinator.cancel() }
        else if module.smallLMCoordinator.runningExperimentID == id { module.smallLMCoordinator.cancel() }
        else if module.distillationCoordinator.runningExperimentID == id { module.distillationCoordinator.cancel() }
        else { throw ModelLabToolError.experimentNotRunning(id) }
        return "Cancellation requested for experiment \(id). Poll lab_get_experiment for the final state."
    }

    @MainActor
    private static func experiments(_ module: ModelLabModule, limit: Int) throws -> String {
        guard let context = module.mainContext else { return "Model Lab store is not available." }
        var descriptor = FetchDescriptor<ExperimentRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let rows = try context.fetch(descriptor).map {
            "\($0.id) · \($0.name) · \($0.taskRaw) · \($0.statusRaw)" + ($0.baseModelID.map { " · base \($0)" } ?? "")
        }
        return lines(rows, empty: "No experiments yet.")
    }

    @MainActor
    private static func datasets(_ module: ModelLabModule, limit: Int) throws -> String {
        guard let context = module.mainContext else { return "Model Lab store is not available." }
        var descriptor = FetchDescriptor<DatasetRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let rows = try context.fetch(descriptor).map {
            "\($0.id) · \($0.name) · \($0.formatRaw)" + ($0.sizeBytes.map { " · \($0) bytes" } ?? "")
                + ($0.columns.isEmpty ? "" : " · columns: \($0.columns.prefix(12).joined(separator: ", "))")
        }
        return lines(rows, empty: "No datasets yet.")
    }
}

enum ModelLabToolError: Error, CustomStringConvertible {
    case missingQuery, missingExperimentID, storeUnavailable
    case experimentNotFound(String), experimentNotRunning(String)
    var description: String {
        switch self {
        case .missingQuery: "query is required"
        case .missingExperimentID: "experiment_id is required"
        case .storeUnavailable: "Model Lab store is unavailable"
        case .experimentNotFound(let id): "No experiment with ID \(id)"
        case .experimentNotRunning(let id): "Experiment \(id) is not running; no training was cancelled"
        }
    }
}
