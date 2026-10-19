import Foundation
import CreateML
import TabularData

public enum TrainingPhase: String, Sendable {
    case preparingData
    case training
    case evaluating
    case savingArtifact
    case done
}

public struct TrainingProgress: Sendable {
    public let phase: TrainingPhase
    public let message: String
}

public struct TrainingJob: Sendable {
    public let task: TaskType
    public let datasetFileURL: URL
    public let textOrFeatureColumns: [String]
    public let labelColumn: String
    public let validationFraction: Double
    public let outputName: String

    public init(
        task: TaskType,
        datasetFileURL: URL,
        textOrFeatureColumns: [String],
        labelColumn: String,
        validationFraction: Double = 0.2,
        outputName: String
    ) {
        self.task = task
        self.datasetFileURL = datasetFileURL
        self.textOrFeatureColumns = textOrFeatureColumns
        self.labelColumn = labelColumn
        self.validationFraction = validationFraction
        self.outputName = outputName
    }
}

public struct TrainingResult: Sendable {
    public let modelFileRelativePath: String
    public let trainingAccuracy: Double
    public let validationAccuracy: Double
    public let metrics: [MetricPoint]
}

public enum TrainingError: LocalizedError {
    case cancelled
    case unsupportedTask(TaskType)
    case unsupportedDataFormat(String)
    case missingColumn(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Training was cancelled."
        case .unsupportedTask(let task): "\(task.displayName) is not supported by this training provider."
        case .unsupportedDataFormat(let format): "Create ML training needs a tabular dataset; .\(format) could not be converted."
        case .missingColumn(let name): "Column '\(name)' was not found in the dataset."
        }
    }
}

public protocol TrainingProvider: Sendable {
    var name: String { get }
    var supportedTasks: [TaskType] { get }
    func capability(for task: TaskType) -> CapabilityStatus
    func train(job: TrainingJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void) async throws -> TrainingResult
}

/// Real, synchronous, on-device training via CreateML's `MLTextClassifier`
/// and `MLClassifier` (tabular). CreateML's throwing initializers for these
/// types do not expose incremental (0-100%) progress or a mid-call
/// cancellation hook in the SDK on this machine, so progress is reported in
/// coarse, honest phases rather than a fabricated percentage, and
/// cancellation is cooperative: checked before the blocking call starts, not
/// during it.
public struct CreateMLTrainingProvider: TrainingProvider {
    public let name = "Create ML"
    public let supportedTasks: [TaskType] = [.textClassification, .tabularClassification, .imageClassification]
    private let artifactStore = ArtifactStore()

    public init() {}

    public func capability(for task: TaskType) -> CapabilityStatus {
        supportedTasks.contains(task) ? .available : .unavailable(reason: "\(task.displayName) has no Create ML training path yet.")
    }

    public func train(job: TrainingJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void) async throws -> TrainingResult {
        guard supportedTasks.contains(job.task) else { throw TrainingError.unsupportedTask(job.task) }
        try Task.checkCancellation()

        if job.task == .imageClassification {
            onProgress(TrainingProgress(phase: .preparingData, message: "Reading labeled subfolders under \(job.datasetFileURL.lastPathComponent)"))
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try trainImageClassifier(job: job, onProgress: onProgress)
            }.value
        }

        onProgress(TrainingProgress(phase: .preparingData, message: "Loading \(job.datasetFileURL.lastPathComponent)"))
        let frame = try loadDataFrame(from: job.datasetFileURL)

        try Task.checkCancellation()

        return try await Task.detached(priority: .userInitiated) {
            switch job.task {
            case .textClassification:
                return try trainTextClassifier(frame: frame, job: job, onProgress: onProgress)
            case .tabularClassification:
                return try trainTabularClassifier(frame: frame, job: job, onProgress: onProgress)
            case .imageClassification:
                throw TrainingError.unsupportedTask(.imageClassification)
            case .textGeneration:
                throw TrainingError.unsupportedTask(.textGeneration)
            case .mlxFineTuning:
                throw TrainingError.unsupportedTask(.mlxFineTuning)
            case .smallLMPretraining:
                throw TrainingError.unsupportedTask(.smallLMPretraining)
            case .distillation:
                throw TrainingError.unsupportedTask(.distillation)
            case .logitDistillation:
                throw TrainingError.unsupportedTask(.logitDistillation)
            case .gameAgentTraining:
                throw TrainingError.unsupportedTask(.gameAgentTraining)
            }
        }.value
    }

    private func loadDataFrame(from url: URL) throws -> DataFrame {
        switch url.pathExtension.lowercased() {
        case "csv", "tsv":
            return try DataFrame(contentsOfCSVFile: url)
        case "jsonl", "ndjson":
            return try loadJSONDataFrame(from: url, isLineDelimited: true)
        case "json":
            return try loadJSONDataFrame(from: url, isLineDelimited: false)
        default:
            throw TrainingError.unsupportedDataFormat(url.pathExtension.isEmpty ? "unknown" : url.pathExtension)
        }
    }

    private func loadJSONDataFrame(from url: URL, isLineDelimited: Bool) throws -> DataFrame {
        let data = try Data(contentsOf: url)
        let values: [Any]
        if isLineDelimited {
            let lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
            values = try lines.map { line in
                guard let lineData = String(line).data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    throw TrainingError.unsupportedDataFormat("jsonl")
                }
                return object
            }
        } else {
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw TrainingError.unsupportedDataFormat("json")
            }
            values = array
        }

        let objects = values.compactMap { $0 as? [String: Any] }
        guard !objects.isEmpty else { throw TrainingError.unsupportedDataFormat("json") }
        let columns = Set(objects.flatMap(\.keys)).sorted()
        let csv = ([columns] + objects.map { object in
            columns.map { csvField(object[$0]) }
        })
        .map { $0.joined(separator: ",") }
        .joined(separator: "\n") + "\n"
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try csv.write(to: temporaryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try DataFrame(contentsOfCSVFile: temporaryURL)
    }

    private func csvField(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        let string: String
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            string = String(decoding: data, as: UTF8.self)
        } else {
            string = "\(value)"
        }
        return "\"\(string.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func trainTextClassifier(
        frame: DataFrame, job: TrainingJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) throws -> TrainingResult {
        guard let textColumn = job.textOrFeatureColumns.first else {
            throw TrainingError.missingColumn("(no text column selected)")
        }
        guard frame.columns.map(\.name).contains(textColumn) else { throw TrainingError.missingColumn(textColumn) }
        guard frame.columns.map(\.name).contains(job.labelColumn) else { throw TrainingError.missingColumn(job.labelColumn) }

        onProgress(TrainingProgress(phase: .training, message: "Training MLTextClassifier on \(frame.rows.count) rows (this runs on-device and may take a while; progress is not incremental for this model type)"))
        let classifier = try MLTextClassifier(
            trainingData: frame,
            textColumn: textColumn,
            labelColumn: job.labelColumn,
            parameters: .init(validation: .split(strategy: .fixed(ratio: job.validationFraction, seed: 42)))
        )

        onProgress(TrainingProgress(phase: .evaluating, message: "Computing validation metrics"))
        let trainingAccuracy = 1.0 - classifier.trainingMetrics.classificationError
        let validationAccuracy = 1.0 - classifier.validationMetrics.classificationError

        onProgress(TrainingProgress(phase: .savingArtifact, message: "Writing .mlmodel"))
        let fileName = "\(job.outputName).mlmodel"
        let destination = LibraryPaths.models.appendingPathComponent(fileName)
        try classifier.write(to: destination, metadata: MLModelMetadata(
            author: "Model Lab", shortDescription: "Text classifier trained in Model Lab", version: "1.0"
        ))

        onProgress(TrainingProgress(phase: .done, message: "Done"))
        return TrainingResult(
            modelFileRelativePath: fileName,
            trainingAccuracy: trainingAccuracy,
            validationAccuracy: validationAccuracy,
            metrics: [
                MetricPoint(name: "trainingAccuracy", value: trainingAccuracy),
                MetricPoint(name: "validationAccuracy", value: validationAccuracy)
            ]
        )
    }

    private func trainTabularClassifier(
        frame: DataFrame, job: TrainingJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) throws -> TrainingResult {
        guard frame.columns.map(\.name).contains(job.labelColumn) else { throw TrainingError.missingColumn(job.labelColumn) }
        let featureColumns = job.textOrFeatureColumns.isEmpty ? nil : job.textOrFeatureColumns

        onProgress(TrainingProgress(phase: .training, message: "Training tabular classifier (Create ML auto-selects boosted tree / random forest / logistic regression) on \(frame.rows.count) rows"))
        let classifier = try MLClassifier(trainingData: frame, targetColumn: job.labelColumn, featureColumns: featureColumns)

        onProgress(TrainingProgress(phase: .evaluating, message: "Computing validation metrics"))
        let trainingAccuracy = 1.0 - classifier.trainingMetrics.classificationError
        let validationAccuracy = 1.0 - classifier.validationMetrics.classificationError

        onProgress(TrainingProgress(phase: .savingArtifact, message: "Writing .mlmodel"))
        let fileName = "\(job.outputName).mlmodel"
        let destination = LibraryPaths.models.appendingPathComponent(fileName)
        try classifier.write(to: destination, metadata: MLModelMetadata(
            author: "Model Lab", shortDescription: "Tabular classifier trained in Model Lab", version: "1.0"
        ))

        onProgress(TrainingProgress(phase: .done, message: "Done"))
        return TrainingResult(
            modelFileRelativePath: fileName,
            trainingAccuracy: trainingAccuracy,
            validationAccuracy: validationAccuracy,
            metrics: [
                MetricPoint(name: "trainingAccuracy", value: trainingAccuracy),
                MetricPoint(name: "validationAccuracy", value: validationAccuracy)
            ]
        )
    }

    /// `job.datasetFileURL` is the root of a labeled-subfolder image layout
    /// (one subfolder per class, matching `DatasetImporter`'s `.imagesFolder`
    /// detection) rather than a single file, since `MLImageClassifier.DataSource
    /// .labeledDirectories` reads a folder directly. Text/feature/label
    /// columns don't apply here — labels come from subfolder names.
    private func trainImageClassifier(
        job: TrainingJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) throws -> TrainingResult {
        onProgress(TrainingProgress(
            phase: .training,
            message: "Training MLImageClassifier via transfer learning (this runs on-device and may take a while; progress is not incremental for this model type)"
        ))
        let classifier = try MLImageClassifier(
            trainingData: .labeledDirectories(at: job.datasetFileURL),
            parameters: .init(
                validation: .split(strategy: .fixed(ratio: job.validationFraction, seed: 42)),
                augmentation: [],
                algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 1), classifier: .logisticRegressor)
            )
        )

        onProgress(TrainingProgress(phase: .evaluating, message: "Computing validation metrics"))
        let trainingAccuracy = 1.0 - classifier.trainingMetrics.classificationError
        let validationAccuracy = 1.0 - classifier.validationMetrics.classificationError

        onProgress(TrainingProgress(phase: .savingArtifact, message: "Writing .mlmodel"))
        let fileName = "\(job.outputName).mlmodel"
        let destination = LibraryPaths.models.appendingPathComponent(fileName)
        try classifier.write(to: destination, metadata: MLModelMetadata(
            author: "Model Lab", shortDescription: "Image classifier trained in Model Lab", version: "1.0"
        ))

        onProgress(TrainingProgress(phase: .done, message: "Done"))
        return TrainingResult(
            modelFileRelativePath: fileName,
            trainingAccuracy: trainingAccuracy,
            validationAccuracy: validationAccuracy,
            metrics: [
                MetricPoint(name: "trainingAccuracy", value: trainingAccuracy),
                MetricPoint(name: "validationAccuracy", value: validationAccuracy)
            ]
        )
    }
}
