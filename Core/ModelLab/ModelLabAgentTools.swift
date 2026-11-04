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
        case importDataset = "import_dataset"
        case createExperiment = "create_experiment"
        case evaluate = "evaluate_predictions"
        case exportModel = "export_model"
        case predict = "predict"
        case predictImages = "predict_images"
        case startSmallLM = "start_small_lm"
        case startLoRA = "start_lora"
        case startDistillation = "start_distillation"

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
            case .importDataset:
                ToolSpec(name: "lab_import_dataset", summary: "Copy a local CSV, TSV, JSON, JSONL, TXT file (or a folder of images) into the Model Lab dataset library and register it. Returns the dataset ID and its columns.",
                         parameters: [ToolParam(name: "path", description: "Absolute path of the local file or folder")], permission: .write)
            case .createExperiment:
                ToolSpec(name: "lab_create_experiment", summary: "Create a draft Create ML classifier experiment over a registered dataset. Start it with lab_start_training.",
                         parameters: [
                            ToolParam(name: "name", description: "Experiment name"),
                            ToolParam(name: "task", description: "text_classification, tabular_classification or image_classification (image: dataset must be an imported folder of images, one subfolder per label; column arguments are ignored)"),
                            ToolParam(name: "dataset_id", description: "ID from lab_list_datasets or lab_import_dataset"),
                            ToolParam(name: "input_columns", description: "Comma-separated input column names (exactly one for text classification; not used for images)", required: false),
                            ToolParam(name: "label_column", description: "Name of the label column (not used for images)", required: false),
                            ToolParam(name: "validation_fraction", type: "number", description: "Share held out for validation, between 0 and 1; default 0.2", required: false),
                         ], permission: .write)
            case .evaluate:
                ToolSpec(name: "lab_evaluate_predictions", summary: "Score predictions against references with accuracy, F1, BLEU and ROUGE (the same runner as the Evaluation tab). Pure computation; nothing is written.",
                         parameters: [
                            ToolParam(name: "predictions", type: "array", description: "Predicted strings, one per example"),
                            ToolParam(name: "references", type: "array", description: "Reference strings in the same order"),
                         ], permission: .read)
            case .startSmallLM:
                ToolSpec(name: "lab_start_small_lm", summary: "Create a small character-level language-model experiment over a registered UTF-8 text dataset and start training it from scratch on this Mac's GPU. Uses compute and writes a new artifact; requires approval. Bounded: 10–2000 iterations, 32–256 dimensions (multiple of 4), 1–6 layers, corpus at most 5 MB. Poll lab_get_experiment; cancel with lab_cancel_training.",
                         parameters: [
                            ToolParam(name: "name", description: "Experiment name"),
                            ToolParam(name: "dataset_id", description: "ID of a text dataset (txt)"),
                            ToolParam(name: "iterations", type: "integer", description: "Training iterations; default 150", required: false),
                            ToolParam(name: "dimensions", type: "integer", description: "Embedding size; default 64", required: false),
                            ToolParam(name: "layers", type: "integer", description: "Transformer layers; default 2", required: false),
                         ], permission: .execute)
            case .startLoRA:
                ToolSpec(name: "lab_start_lora", summary: "Create an MLX LoRA fine-tune experiment over a registered .txt or .jsonl dataset and start it on this Mac's GPU. Uses compute and writes an adapter; requires approval. The base model must already be cached locally: if it is not, nothing is downloaded and the call fails. Only after the user agrees to the download, retry with allow_download=true. Bounded: 10–1000 iterations, rank 1–32, at most 20,000 examples. Poll lab_get_experiment; cancel with lab_cancel_training.",
                         parameters: [
                            ToolParam(name: "name", description: "Experiment name"),
                            ToolParam(name: "dataset_id", description: "ID of a txt or jsonl dataset"),
                            ToolParam(name: "base_model", description: "Hugging Face repo as org/name, e.g. mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
                            ToolParam(name: "iterations", type: "integer", description: "Default 100", required: false),
                            ToolParam(name: "rank", type: "integer", description: "LoRA rank; default 8", required: false),
                            ToolParam(name: "allow_download", type: "boolean", description: "true only after the user agreed to download the base model from huggingface.co; default false", required: false),
                         ], permission: .execute)
            case .startDistillation:
                ToolSpec(name: "lab_start_distillation", summary: "Distill a teacher into a small student: the teacher answers your seed prompts, then a LoRA student trains on those answers (synthetic-data distillation, not logit matching). Uses compute and writes a dataset and adapter; requires approval. teacher is \"apple\" (Apple Intelligence, if available) or an MLX repo; MLX repos must already be cached locally, otherwise nothing is downloaded and the call fails. Only after the user agrees to the download, retry with allow_download=true. Bounded: 1–200 seed prompts, 10–1000 iterations, rank 1–32. Poll lab_get_experiment; cancel with lab_cancel_training.",
                         parameters: [
                            ToolParam(name: "name", description: "Experiment name"),
                            ToolParam(name: "seed_prompts", type: "array", description: "Prompts the teacher answers; the answers become the training data"),
                            ToolParam(name: "teacher", description: "\"apple\" or an MLX Hugging Face repo as org/name"),
                            ToolParam(name: "student_model", description: "Student base model, Hugging Face repo as org/name, e.g. mlx-community/Llama-3.2-1B-Instruct-4bit"),
                            ToolParam(name: "iterations", type: "integer", description: "Default 100", required: false),
                            ToolParam(name: "rank", type: "integer", description: "LoRA rank; default 8", required: false),
                            ToolParam(name: "allow_download", type: "boolean", description: "true only after the user agreed to download uncached models from huggingface.co; default false", required: false),
                         ], permission: .execute)
            case .predict:
                ToolSpec(name: "lab_predict", summary: "Run a trained Create ML text classifier over example inputs and return the predicted label and confidence for each. Pair with lab_evaluate_predictions to score a held-out set.",
                         parameters: [
                            ToolParam(name: "artifact_id", description: "Artifact ID from lab_get_experiment (a .mlmodel / .mlpackage)"),
                            ToolParam(name: "texts", type: "array", description: "Input strings, at most 200"),
                         ], permission: .read)
            case .predictImages:
                ToolSpec(name: "lab_predict_images", summary: "Run a trained Create ML image classifier over image files and return the predicted label and confidence for each. Give either image_paths or a folder (its images, one level deep, up to 200). With a folder whose subfolders are named by label, also reports accuracy against those names, which scores a held-out set.",
                         parameters: [
                            ToolParam(name: "artifact_id", description: "Artifact ID from lab_get_experiment (an image-classifier .mlmodel / .mlpackage)"),
                            ToolParam(name: "image_paths", type: "array", description: "Absolute image file paths, at most 200", required: false),
                            ToolParam(name: "folder", description: "Absolute folder of images; subfolders are treated as true labels", required: false),
                         ], permission: .read)
            case .exportModel:
                ToolSpec(name: "lab_export_model", summary: "Export a produced model artifact (Create ML .mlmodel/.mlpackage as core_ml, or MLX artifacts as mlx_package) into an existing folder, keeping its file name (a numbered suffix is added rather than overwriting). GGUF is not available.",
                         parameters: [
                            ToolParam(name: "artifact_id", description: "Artifact ID from lab_get_experiment"),
                            ToolParam(name: "format", description: "core_ml or mlx_package"),
                            ToolParam(name: "destination_folder", description: "Absolute path of an existing folder to copy the export into"),
                         ], permission: .write)
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
        case .importDataset:
            let path = try Self.requiredString(args, "path")
            return try await MainActor.run {
                let record = try module.importLocalDataset(at: URL(fileURLWithPath: path))
                return "Imported dataset \(record.id) · \(record.name) · \(record.formatRaw) · \(record.rowCount.map(String.init) ?? "?") rows · columns: \(record.columns.joined(separator: ", "))"
            }
        case .createExperiment:
            let rawTask = try Self.requiredString(args, "task").lowercased().replacingOccurrences(of: "_", with: "")
            guard let task = TaskType.allCases.first(where: { $0.rawValue.lowercased() == rawTask }) else {
                throw ModelLabToolError.invalid("task must be text_classification, tabular_classification or image_classification")
            }
            let inputs = ((args["input_columns"] as? String) ?? "").split(separator: ",").map(String.init)
            let fraction = (args["validation_fraction"] as? Double) ?? 0.2
            let name = try Self.requiredString(args, "name")
            let datasetID = try Self.requiredString(args, "dataset_id")
            let label = rawTask == "imageclassification" ? "" : try Self.requiredString(args, "label_column")
            return try await MainActor.run {
                let record = try module.createClassifierExperiment(name: name, task: task, datasetID: datasetID,
                                                                   inputColumns: inputs, labelColumn: label, validationFraction: fraction)
                return "Created draft experiment \(record.id) · \(record.name). Start it with lab_start_training, then poll lab_get_experiment."
            }
        case .evaluate:
            let predictions = (args["predictions"] as? [Any])?.map { "\($0)" } ?? []
            let references = (args["references"] as? [Any])?.map { "\($0)" } ?? []
            guard !predictions.isEmpty, predictions.count == references.count else {
                throw ModelLabToolError.invalid("predictions and references must be non-empty arrays of the same length")
            }
            let run = try EvaluationRunner().evaluate(
                modelName: "agent", predictions: predictions, references: references,
                metrics: [AccuracyMetric(), F1Metric(), BLEUMetric(), ROUGEMetric(.rouge1), ROUGEMetric(.rouge2), ROUGEMetric(.rougeL)])
            return run.outcomes.map { String(format: "%@ = %.4f%@", $0.metricName, $0.value, $0.lowerIsBetter ? " (lower is better)" : "") }
                .joined(separator: "\n") + "\n\(predictions.count) examples"
        case .startSmallLM:
            let name = try Self.requiredString(args, "name")
            let datasetID = try Self.requiredString(args, "dataset_id")
            let iterations = (args["iterations"] as? Int) ?? 150
            let dimensions = (args["dimensions"] as? Int) ?? 64
            let layers = (args["layers"] as? Int) ?? 2
            let id = try await MainActor.run {
                try module.startSmallLMExperiment(name: name, datasetID: datasetID, iterations: iterations, dimensions: dimensions, layers: layers)
            }
            return "Training started for experiment \(id). This does not mean it succeeded. Poll lab_get_experiment for status, metrics and the produced artifact."
        case .startLoRA:
            let name = try Self.requiredString(args, "name")
            let datasetID = try Self.requiredString(args, "dataset_id")
            let base = try Self.requiredString(args, "base_model")
            let iterations = (args["iterations"] as? Int) ?? 100
            let rank = (args["rank"] as? Int) ?? 8
            let allow = (args["allow_download"] as? Bool) ?? false
            let id = try await MainActor.run {
                try module.startLoRAExperiment(name: name, datasetID: datasetID, baseModel: base, iterations: iterations, rank: rank, allowDownload: allow)
            }
            return "LoRA training started for experiment \(id). This does not mean it succeeded. Poll lab_get_experiment for status, metrics and the adapter artifact."
        case .startDistillation:
            let name = try Self.requiredString(args, "name")
            let teacher = try Self.requiredString(args, "teacher")
            let student = try Self.requiredString(args, "student_model")
            let seeds = (args["seed_prompts"] as? [Any])?.map { "\($0)" } ?? []
            let iterations = (args["iterations"] as? Int) ?? 100
            let rank = (args["rank"] as? Int) ?? 8
            let allow = (args["allow_download"] as? Bool) ?? false
            let id = try await MainActor.run {
                try module.startDistillationExperiment(name: name, seedPrompts: seeds, teacher: teacher, studentModel: student,
                                                       iterations: iterations, rank: rank, allowDownload: allow)
            }
            return "Distillation started for experiment \(id). This does not mean it succeeded. Poll lab_get_experiment for status, metrics and the adapter artifact."
        case .predict:
            let id = try Self.requiredString(args, "artifact_id")
            let texts = (args["texts"] as? [Any])?.map { "\($0)" } ?? []
            guard !texts.isEmpty, texts.count <= 200 else { throw ModelLabToolError.invalid("texts must be a non-empty array of at most 200 strings") }
            let predictions = try await MainActor.run { try module.predict(artifactID: id, texts: texts) }
            return zip(texts, predictions).map { "\($0) → \($1)" }.joined(separator: "\n")
        case .predictImages:
            let id = try Self.requiredString(args, "artifact_id")
            let images = try ImageHoldout.collect(imagePaths: (args["image_paths"] as? [Any])?.map { "\($0)" }, folder: args["folder"] as? String)
            let results = try await MainActor.run { try module.predictImages(artifactID: id, images: images.map(\.url)) }
            return ImageHoldout.report(images: images, results: results)
        case .exportModel:
            let id = try Self.requiredString(args, "artifact_id")
            let formatName = try Self.requiredString(args, "format").lowercased()
            let format: ModelExporters.ExportFormat
            switch formatName {
            case "core_ml", "coreml": format = .coreML
            case "mlx_package", "mlx": format = .mlxPackage
            default: throw ModelLabToolError.invalid("format must be core_ml or mlx_package (GGUF is unavailable)")
            }
            let folder = try Self.requiredString(args, "destination_folder")
            var isDirectory: ObjCBool = false
            guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ModelLabToolError.invalid("destination_folder must be the absolute path of an existing folder")
            }
            let destination = URL(fileURLWithPath: folder, isDirectory: true)
            let exported = try await MainActor.run { try module.exportArtifact(id: id, format: format, destinationFolder: destination) }
            return "Exported to \(exported.path)"
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

    static func requiredString(_ args: [String: Any], _ key: String) throws -> String {
        let value = ((args[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ModelLabToolError.invalid("\(key) is required") }
        return value
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
    case invalid(String)
    case experimentNotFound(String), experimentNotRunning(String)
    var description: String {
        switch self {
        case .invalid(let message): message
        case .missingQuery: "query is required"
        case .missingExperimentID: "experiment_id is required"
        case .storeUnavailable: "Model Lab store is unavailable"
        case .experimentNotFound(let id): "No experiment with ID \(id)"
        case .experimentNotRunning(let id): "Experiment \(id) is not running; no training was cancelled"
        }
    }
}
