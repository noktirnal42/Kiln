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
        guard [.textClassification, .tabularClassification, .imageClassification].contains(task) else {
            throw invalid("Only text_classification, tabular_classification and image_classification experiments can be created here.")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw invalid("name is required.") }
        guard validationFraction.isFinite, validationFraction > 0, validationFraction < 1 else {
            throw invalid("validation_fraction must be between 0 and 1.")
        }
        let datasets = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        guard let dataset = try context.fetch(datasets).first else { throw invalid("No dataset with ID \(datasetID).") }
        if task == .imageClassification {
            guard dataset.format == .imagesFolder else {
                throw invalid("An image classifier needs a dataset imported from a folder of images (one subfolder per label).")
            }
            let record = Self.makeExperimentDraft(name: trimmedName, task: task, datasetID: datasetID, inputColumnsText: "", labelColumnText: "")
            record.hyperparameters["validationFraction"] = String(validationFraction)
            try ExperimentStore(context: context).create(record)
            return record
        }
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

    /// Runs a trained Create ML text classifier over some inputs. Returns "label (confidence)" per input, in order.
    public static func predict(modelURL: URL, texts: [String]) throws -> [String] {
        let provider = CoreMLClassificationProvider()
        return try texts.map { text in
            let scores = try provider.classify(modelURL: modelURL, text: text)
            guard let top = scores.max(by: { $0.confidence < $1.confidence }) else { return "no prediction" }
            return String(format: "%@ (%.2f)", top.label, top.confidence)
        }
    }

    @MainActor
    public func predict(artifactID id: String, texts: [String]) throws -> [String] {
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        let descriptor = FetchDescriptor<ModelArtifactRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw ModelLabModuleError.invalidTrainingConfiguration("No model artifact with ID \(id).")
        }
        let url = ModelLabCore.ArtifactStore().absoluteURL(for: record.localRelativePath, in: .models)
        guard record.format == .mlmodel || record.format == .mlpackage, FileManager.default.fileExists(atPath: url.path) else {
            throw ModelLabModuleError.invalidTrainingConfiguration("lab_predict runs Core ML classifiers (.mlmodel / .mlpackage) that exist in the model library.")
        }
        return try Self.predict(modelURL: url, texts: texts)
    }

    /// Top label and confidence for each image, in order. An image that cannot be read reports that instead of failing the batch.
    public static func predictImages(modelURL: URL, images: [URL]) throws -> [(label: String, confidence: Double)?] {
        let provider = CoreMLClassificationProvider()
        return images.map { url in
            guard let scores = try? provider.classifyImage(modelURL: modelURL, imageURL: url),
                  let top = scores.max(by: { $0.confidence < $1.confidence }) else { return nil }
            return (top.label, top.confidence)
        }
    }

    @MainActor
    public func predictImages(artifactID id: String, images: [URL]) throws -> [(label: String, confidence: Double)?] {
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        let descriptor = FetchDescriptor<ModelArtifactRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw ModelLabModuleError.invalidTrainingConfiguration("No model artifact with ID \(id).")
        }
        let url = ModelLabCore.ArtifactStore().absoluteURL(for: record.localRelativePath, in: .models)
        guard record.format == .mlmodel || record.format == .mlpackage, FileManager.default.fileExists(atPath: url.path) else {
            throw ModelLabModuleError.invalidTrainingConfiguration("lab_predict_images runs Core ML classifiers (.mlmodel / .mlpackage) that exist in the model library.")
        }
        return try Self.predictImages(modelURL: url, images: images)
    }

    // MARK: Small language model from scratch

    /// The job the GUI and the agent tool both build: a character-level transformer over the whole corpus.
    static func smallLMJob(corpus: String, dimensions: Int, layers: Int, iterations: Int) -> SmallLMPretrainingJob {
        SmallLMPretrainingJob(corpusText: corpus, contextLength: 128, dimensions: dimensions, numHeads: 4, numLayers: layers,
                              mlpDimensions: dimensions * 4, iterations: iterations, learningRate: 1e-3, batchSize: 8,
                              outputName: "run-\(UUID().uuidString)")
    }

    /// Creates a small-LM experiment over a registered text dataset and starts training. Returns the experiment ID.
    /// Bounded for agent use: 10–2000 iterations, 32–256 dimensions (multiple of 4), 1–6 layers, corpus at most 5 MB.
    @MainActor
    public func startSmallLMExperiment(name: String, datasetID: String, iterations: Int = 150, dimensions: Int = 64, layers: Int = 2) throws -> String {
        func invalid(_ message: String) -> ModelLabModuleError { .invalidTrainingConfiguration(message) }
        try requireCapabilities([.fileSystemWrite, .metalCompute])
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        guard (10...2000).contains(iterations) else { throw invalid("iterations must be between 10 and 2000.") }
        guard (32...256).contains(dimensions), dimensions % 4 == 0 else { throw invalid("dimensions must be between 32 and 256 and a multiple of 4.") }
        guard (1...6).contains(layers) else { throw invalid("layers must be between 1 and 6.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalid("name is required.") }
        guard ![createMLCoordinator.runningExperimentID, mlxFineTuningCoordinator.runningExperimentID,
                smallLMCoordinator.runningExperimentID, distillationCoordinator.runningExperimentID].contains(where: { $0 != nil }) else {
            throw invalid("Another training job is running. Wait or cancel that exact experiment first.")
        }
        let datasets = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        guard let dataset = try context.fetch(datasets).first else { throw invalid("No dataset with ID \(datasetID).") }
        let file = try Self.datasetFile(dataset, in: LibraryPaths.datasets)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= 5_000_000 else {
            throw invalid("The dataset is larger than 5 MB; use the GUI for bigger corpora.")
        }
        guard let corpus = try? String(contentsOf: file, encoding: .utf8), !corpus.isEmpty else {
            throw invalid("The dataset could not be read as a UTF-8 text corpus.")
        }
        let job = Self.smallLMJob(corpus: corpus, dimensions: dimensions, layers: layers, iterations: iterations)
        try SmallLMPretrainingProvider.validate(job: job)
        let experiment = ExperimentRecord(name: trimmed, task: .smallLMPretraining, datasetID: datasetID)
        try ExperimentStore(context: context).create(experiment)
        try startSmallLMPretraining(experiment: experiment, job: job)
        return experiment.id
    }

    /// A dataset's file inside the dataset library; rejects traversal and symlinks that leave it.
    static func datasetFile(_ dataset: DatasetRecord, in datasetsRoot: URL) throws -> URL {
        func invalid(_ message: String) -> ModelLabModuleError { .invalidTrainingConfiguration(message) }
        guard let relative = dataset.localRelativePath, !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw invalid("The dataset needs a local file inside the Model Lab dataset library.")
        }
        let root = datasetsRoot.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            throw invalid("The local dataset is missing or outside the dataset library. Import it again before training.")
        }
        return file
    }
}


// MARK: LoRA fine-tuning with an explicit download policy

/// Decides whether a base model may be used without a network download. Pure, so it is tested without a GPU.
public enum ModelDownloadPolicy {
    /// `org/name` with conservative characters; nothing that could escape a cache directory.
    public static func isValidRepoID(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    /// Where a swift-transformers / Hugging Face cache would hold the repo.
    public static func cacheCandidates(repo: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent("Documents/huggingface/models/\(repo)"),
         home.appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--"))]
    }

    public static func isCached(repo: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        cacheCandidates(repo: repo, home: home).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// nil when allowed; otherwise the reason the agent must report to the user.
    public static func refusal(repo: String, allowDownload: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard isValidRepoID(repo) else { return "base_model must look like org/name (letters, digits, - _ .)." }
        if isCached(repo: repo, home: home) { return nil }
        if allowDownload { return nil }
        return "\(repo) is not cached on this Mac, so training would download it from huggingface.co. Nothing was downloaded. Ask the user, then retry with allow_download=true (the approval prompt shows that flag), or pick a model that is already cached."
    }
}

extension ModelLabModule {
    /// Creates an MLX LoRA fine-tune experiment over a registered text/JSONL dataset and starts it.
    /// Bounded: 10–1000 iterations, rank 1–32, at most 20,000 examples. The base model must already be cached unless
    /// `allowDownload` is set, which the agent sets only after the user agreed; the approval sheet shows the flag.
    @MainActor
    public func startLoRAExperiment(name: String, datasetID: String, baseModel: String, iterations: Int = 100, rank: Int = 8,
                                    allowDownload: Bool = false) throws -> String {
        func invalid(_ message: String) -> ModelLabModuleError { .invalidTrainingConfiguration(message) }
        try requireCapabilities(allowDownload ? [.fileSystemWrite, .metalCompute, .networkClient] : [.fileSystemWrite, .metalCompute])
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        guard (10...1000).contains(iterations) else { throw invalid("iterations must be between 10 and 1000.") }
        guard (1...32).contains(rank) else { throw invalid("rank must be between 1 and 32.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalid("name is required.") }
        if let reason = ModelDownloadPolicy.refusal(repo: baseModel, allowDownload: allowDownload) { throw invalid(reason) }
        guard ![createMLCoordinator.runningExperimentID, mlxFineTuningCoordinator.runningExperimentID,
                smallLMCoordinator.runningExperimentID, distillationCoordinator.runningExperimentID].contains(where: { $0 != nil }) else {
            throw invalid("Another training job is running. Wait or cancel that exact experiment first.")
        }
        let datasets = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        guard let dataset = try context.fetch(datasets).first else { throw invalid("No dataset with ID \(datasetID).") }
        let file = try Self.datasetFile(dataset, in: LibraryPaths.datasets)
        guard [.txt, .jsonl].contains(dataset.format) else { throw invalid("LoRA needs a .txt (one example per line) or .jsonl (\"text\" field) dataset.") }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= 20_000_000,
              let contents = try? String(contentsOf: file, encoding: .utf8) else {
            throw invalid("The dataset could not be read as UTF-8 text or is larger than 20 MB.")
        }
        let texts = Self.loraTexts(contents: contents, format: dataset.format)
        guard texts.count >= 2 else { throw invalid("The dataset needs at least 2 examples.") }
        guard texts.count <= 20_000 else { throw invalid("More than 20,000 examples; use the GUI for bigger sets.") }
        let validationCount = max(1, texts.count / 5)
        let job = FineTuningJob(baseModelRepoID: baseModel, trainingTexts: Array(texts.dropLast(validationCount)),
                                validationTexts: Array(texts.suffix(validationCount)), rank: rank, numLayers: 8,
                                iterations: iterations, learningRate: 1e-5, batchSize: 1, outputName: "run-\(UUID().uuidString)")
        let experiment = ExperimentRecord(name: trimmed, task: .mlxFineTuning, datasetID: datasetID)
        experiment.baseModelID = baseModel
        try ExperimentStore(context: context).create(experiment)
        try startMLXLoRA(experiment: experiment, job: job)
        return experiment.id
    }

    /// Creates a distillation experiment (teacher answers the seed prompts, a student LoRA trains on the answers) and starts it.
    /// `teacher` is "apple" (Apple Intelligence) or an MLX repo that must already be cached; the student follows the same download rule.
    /// Bounded: 1–200 seed prompts, 10–1000 iterations, rank 1–32.
    @MainActor
    public func startDistillationExperiment(name: String, seedPrompts: [String], teacher: String, studentModel: String,
                                            iterations: Int = 100, rank: Int = 8, allowDownload: Bool = false) throws -> String {
        func invalid(_ message: String) -> ModelLabModuleError { .invalidTrainingConfiguration(message) }
        try requireCapabilities(allowDownload ? [.fileSystemWrite, .metalCompute, .networkClient] : [.fileSystemWrite, .metalCompute])
        guard let context = mainContext else { throw ModelLabModuleError.storeUnavailable("The Model Lab store is unavailable.") }
        guard (10...1000).contains(iterations) else { throw invalid("iterations must be between 10 and 1000.") }
        guard (1...32).contains(rank) else { throw invalid("rank must be between 1 and 32.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalid("name is required.") }
        let seeds = seedPrompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...200).contains(seeds.count) else { throw invalid("Provide between 1 and 200 non-empty seed prompts.") }
        let teacherProvider: any InferenceProvider
        if teacher.lowercased() == "apple" {
            teacherProvider = FoundationModelsInferenceProvider()
        } else {
            if let reason = ModelDownloadPolicy.refusal(repo: teacher, allowDownload: allowDownload) { throw invalid("Teacher: " + reason) }
            teacherProvider = MLXInferenceProvider(repoID: teacher)
        }
        if let reason = ModelDownloadPolicy.refusal(repo: studentModel, allowDownload: allowDownload) { throw invalid("Student: " + reason) }
        guard ![createMLCoordinator.runningExperimentID, mlxFineTuningCoordinator.runningExperimentID,
                smallLMCoordinator.runningExperimentID, distillationCoordinator.runningExperimentID].contains(where: { $0 != nil }) else {
            throw invalid("Another training job is running. Wait or cancel that exact experiment first.")
        }
        let job = DistillationJob(seedPrompts: seeds, teacherProvider: teacherProvider, studentBaseModelRepoID: studentModel,
                                  rank: rank, numLayers: 8, iterations: iterations, learningRate: 1e-4, batchSize: 1,
                                  datasetOutputName: "distill-\(UUID().uuidString)", adapterOutputName: "student-\(UUID().uuidString)")
        let experiment = ExperimentRecord(name: trimmed, task: .distillation, datasetID: "")
        experiment.baseModelID = studentModel
        try ExperimentStore(context: context).create(experiment)
        try startDistillation(experiment: experiment, job: job)
        return experiment.id
    }

    nonisolated static func loraTexts(contents: String, format: DatasetFileFormat) -> [String] {
        let lines = contents.split { $0.isNewline }.map(String.init)
        guard format == .jsonl else { return lines }
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["text"] as? String
        }
    }
}
