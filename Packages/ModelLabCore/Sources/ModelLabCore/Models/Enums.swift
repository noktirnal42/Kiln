import Foundation

public enum TaskType: String, Codable, Sendable, CaseIterable, Identifiable {
    case textClassification
    case tabularClassification
    case imageClassification
    case textGeneration
    case mlxFineTuning
    case smallLMPretraining
    case distillation
    case logitDistillation
    case gameAgentTraining

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .textClassification: "Text Classification"
        case .tabularClassification: "Tabular Classification"
        case .imageClassification: "Image Classification"
        case .textGeneration: "Text Generation (Inference Only)"
        case .mlxFineTuning: "Text Generation (MLX LoRA Fine-Tune)"
        case .smallLMPretraining: "Small Language Model (From Scratch)"
        case .distillation: "Automated Distillation"
        case .logitDistillation: "Logit Distillation (MLX)"
        case .gameAgentTraining: "Game Agent (Q-Learning)"
        }
    }
}

public enum DatasetSourceKind: String, Codable, Sendable {
    case huggingFace
    case urlImport
    case localImport
}

public enum DatasetFileFormat: String, Codable, Sendable {
    case csv
    case jsonl
    case json
    case txt
    case imagesFolder
    case unknown
}

public enum DownloadStatus: String, Codable, Sendable {
    case notStarted
    case downloading
    case completed
    case failed
    case cancelled
}

public enum ModelFormat: String, Codable, Sendable {
    case mlmodel
    case mlpackage
    case mlxFolder
    case mlxHubRepository
    case mlxLoraAdapter
    case mlxScratchModel
    case gameAgentPolicy
    case unknown

    public var displayName: String {
        switch self {
        case .mlmodel: "Core ML (.mlmodel)"
        case .mlpackage: "Core ML (.mlpackage)"
        case .mlxFolder: "MLX Model Folder"
        case .mlxHubRepository: "MLX Hugging Face Repo"
        case .mlxLoraAdapter: "MLX LoRA Adapter"
        case .mlxScratchModel: "From-Scratch Small LM"
        case .gameAgentPolicy: "Game Agent Policy"
        case .unknown: "Unknown"
        }
    }
}

public enum ModelOrigin: String, Codable, Sendable {
    case trainedLocally
    case importedLocal
    case downloadedMLX
    case systemFoundationModel
}

public enum ExperimentStatus: String, Codable, Sendable {
    case draft
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

/// A capability the app depends on, and whether it's usable right now, with
/// an honest reason when it isn't. Never report `.available` without having
/// actually checked.
public enum CapabilityStatus: Sendable, Equatable {
    case available
    case unavailable(reason: String)
    case notChecked

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
