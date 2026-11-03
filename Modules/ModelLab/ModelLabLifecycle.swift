import Foundation
import SwiftData
import ModelLabCore

/// The Model Lab actions that complete a workflow (import a dataset → create an experiment → train → evaluate →
/// export). The GUI and the agent tools call these same methods, so both get the same validation and the same files.
extension ModelLabModule {
    /// Copies a local data file into the dataset library and registers it. A folder of images is allowed too.
    @MainActor
    @discardableResult
    public func importLocalDataset(at url: URL) throws -> DatasetRecord {
        try requireCapabilities([.fileSystemWrite])
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelLabModuleError.invalidTrainingConfiguration("No file or folder at \(url.path).")
        }
        let importer = DatasetImporter()
        let format = importer.detectFormat(at: url)
        guard format != .unknown else {
            throw ModelLabModuleError.invalidTrainingConfiguration("Unsupported dataset type. Use CSV, TSV, JSON, JSONL, TXT or a folder of images.")
        }
        let preview = try importer.preview(at: url)
        let store = ModelLabCore.ArtifactStore()
        let relativePath = try store.importItem(at: url, into: .datasets)
        let record = DatasetRecord(
            id: "ds-\(UUID().uuidString)",
            name: url.deletingPathExtension().lastPathComponent,
            sourceKind: .localImport,
            sourceURL: url.path,
            tags: ["imported"],
            sizeBytes: store.sizeOnDisk(relativePath: relativePath, in: .datasets),
            localRelativePath: relativePath,
            format: format,
            downloadStatus: .completed,
            columns: preview.columns,
            rowCount: preview.rowCount
        )
        context.insert(record)
        try context.save()
        return record
    }

    /// Creates a draft Create ML classifier experiment (text or tabular) over a registered dataset.
    @MainActor
    @discardableResult
    public func createClassifierExperiment(
        name: String, task: TaskType, datasetID: String,
        inputColumns: [String], labelColumn: String, validationFraction: Double = 0.2
    ) throws -> ExperimentRecord {
        func invalid(_ message: String) -> ModelLabModuleError { .invalidTrainingConfiguration(message) }
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        guard task == .textClassification || task == .tabularClassification else {
            throw invalid("Only text_classification and tabular_classification experiments can be created here.")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw invalid("name is required.") }
        guard validationFraction.isFinite, validationFraction > 0, validationFraction < 1 else {
            throw invalid("validation_fraction must be between 0 and 1.")
        }
        let datasets = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        guard let dataset = try context.fetch(datasets).first else { throw invalid("No dataset with ID \(datasetID).") }
        let inputs = inputColumns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let label = labelColumn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputs.isEmpty, !label.isEmpty else { throw invalid("input_columns and label_column are required.") }
        if task == .textClassification, inputs.count != 1 { throw invalid("A text classifier takes exactly one input column.") }
        let known = Set(dataset.columns)
        if !known.isEmpty {
            let missing = (inputs + [label]).filter { !known.contains($0) }
            guard missing.isEmpty else {
                throw invalid("Unknown column(s) \(missing.joined(separator: ", ")). Dataset columns: \(dataset.columns.joined(separator: ", ")).")
            }
        }
        let record = Self.makeExperimentDraft(name: trimmedName, task: task, datasetID: datasetID,
                                              inputColumnsText: inputs.joined(separator: ","), labelColumnText: label)
        record.hyperparameters["validationFraction"] = String(validationFraction)
        try ExperimentStore(context: context).create(record)
        return record
    }

    /// Copies a produced model out of the library in a portable format, into an existing folder.
    @MainActor
    public func exportArtifact(id: String, format: ModelExporters.ExportFormat, destinationFolder destination: URL) throws -> URL {
        try requireCapabilities([.fileSystemWrite])
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        let descriptor = FetchDescriptor<ModelArtifactRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw ModelLabModuleError.invalidTrainingConfiguration("No model artifact with ID \(id).")
        }
        let absolute = record.format == .mlxHubRepository
            ? nil : ModelLabCore.ArtifactStore().absoluteURL(for: record.localRelativePath, in: .models)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelLabModuleError.invalidTrainingConfiguration("The destination folder \(destination.path) does not exist.")
        }
        return try ModelExporters().export(record: record, absoluteURL: absolute, format: format, to: destination)
    }
}
