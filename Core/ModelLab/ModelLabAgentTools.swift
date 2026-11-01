import Foundation
import SwiftData
import ModelLabCore

/// Model Lab as agent tools. Reads are local; the two searches reach Hugging Face, so they are
/// `.execute` and go through approval like any other network call.
public enum ModelLabAgentTools {
    public static let prefix = "lab_"

    @MainActor
    public static func register(module: ModelLabModule, into registry: ToolRegistry = .shared) {
        for tool in [Kind.hardware, .experiments, .datasets, .searchModels, .searchDatasets] {
            registry.register(ModelLabAgentTool(kind: tool, module: module))
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case hardware, experiments, datasets
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
    case missingQuery
    var description: String { "query is required" }
}
