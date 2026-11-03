import SwiftUI
import SwiftData
import ModelLabCore

// MARK: - MLX LoRA / Small LM / Distillation run controls

struct MLXLoRAControls: View {
    @Bindable var module: ModelLabModule
    @Bindable var experiment: ExperimentRecord
    @Environment(\.modelContext) private var modelContext

    @State private var baseModelRepo = "mlx-community/Qwen3-0.6B-4bit"
    @State private var rank = 16
    @State private var iterations = 200
    @State private var learningRate: Float = 1e-4
    @State private var errorText: String?

    var body: some View {
        GroupBox("MLX LoRA Fine-Tune") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Base model (HF repo)", text: $baseModelRepo)
                HStack {
                    Stepper("Rank: \(rank)", value: $rank, in: 1...64)
                    Stepper("Iterations: \(iterations)", value: $iterations, in: 20...5000, step: 20)
                }
                HStack {
                    TextField("Learning rate", value: $learningRate, format: .number)
                        .frame(width: 120)
                    Text("Requires a compatible MLX model and sufficient memory. Validation uses training examples when no separate examples are available.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Start fine-tune") { start() }
                        .disabled(module.mlxFineTuningCoordinator.isRunning)
                    if module.mlxFineTuningCoordinator.runningExperimentID == experiment.id {
                        Button("Cancel", role: .destructive) { module.mlxFineTuningCoordinator.cancel() }
                    }
                }
            }
        }
    }

    private func start() {
        guard let texts = trainingTexts() else {
            errorText = "The experiment's dataset has no text column rows to train on."
            return
        }
        let (train, validation) = split(texts)
        let job = FineTuningJob(
            baseModelRepoID: baseModelRepo,
            trainingTexts: train,
            validationTexts: validation,
            rank: rank,
            numLayers: 8,
            iterations: iterations,
            learningRate: learningRate,
            batchSize: 1,
            outputName: "run-\(UUID().uuidString)"
        )
        do {
            try module.startMLXLoRA(experiment: experiment, job: job)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Plain-text examples: one per line for .txt, the "text" field for
    /// .jsonl, or the experiment's text column for tabular formats — the
    /// same mapping the engine's verified training path uses.
    private func trainingTexts() -> [String]? {
        let context = modelContext
        let datasetID = experiment.datasetID
        let descriptor = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        guard let dataset = try? context.fetch(descriptor).first,
              let relativePath = dataset.localRelativePath else { return nil }
        let url = LibraryPaths.datasets.appendingPathComponent(relativePath)
        switch dataset.format {
        case .txt:
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = contents.split { $0.isNewline }
            return lines.map { String($0) }
        case .jsonl:
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = contents.split { $0.isNewline }
            return lines.compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = object["text"] as? String else { return nil }
                return text
            }
        default:
            guard let textColumn = experiment.textColumn,
                  let table = try? DatasetImporter().table(at: url) else { return nil }
            return table.rows.compactMap { $0[textColumn] }
        }
    }

    private func split(_ texts: [String]) -> ([String], [String]) {
        guard texts.count > 1 else { return (texts, []) }
        let validationCount = max(1, texts.count / 5)
        return (Array(texts.dropLast(validationCount)), Array(texts.suffix(validationCount)))
    }
}

struct SmallLMControls: View {
    @Bindable var module: ModelLabModule
    @Bindable var experiment: ExperimentRecord
    @Environment(\.modelContext) private var modelContext

    @State private var iterations = 500
    @State private var dimensions = 64
    @State private var numLayers = 2
    @State private var errorText: String?

    var body: some View {
        GroupBox("Small LM (from scratch)") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper("Iterations: \(iterations)", value: $iterations, in: 100...5000, step: 100)
                Stepper("Dimensions: \(dimensions)", value: $dimensions, in: 32...256, step: 32)
                Stepper("Layers: \(numLayers)", value: $numLayers, in: 1...6)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Train from scratch") { start() }
                        .disabled(module.smallLMCoordinator.isRunning)
                    if module.smallLMCoordinator.runningExperimentID == experiment.id {
                        Button("Cancel", role: .destructive) { module.smallLMCoordinator.cancel() }
                    }
                }
            }
        }
    }

    private func start() {
        guard let corpus = corpusText() else {
            errorText = "The experiment's dataset file could not be read as a text corpus."
            return
        }
        let job = ModelLabModule.smallLMJob(corpus: corpus, dimensions: dimensions, layers: numLayers, iterations: iterations)
        do {
            try SmallLMPretrainingProvider.validate(job: job)
            try module.startSmallLMPretraining(experiment: experiment, job: job)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func corpusText() -> String? {
        let context = modelContext
        let datasetID = experiment.datasetID
        let descriptor = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        guard let dataset = try? context.fetch(descriptor).first,
              let relativePath = dataset.localRelativePath else { return nil }
        return try? String(contentsOf: LibraryPaths.datasets.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

struct DistillationControls: View {
    @Bindable var module: ModelLabModule
    @Bindable var experiment: ExperimentRecord

    @State private var seedPromptsText = "Explain machine learning in one sentence.\nDescribe the water cycle."
    @State private var studentRepo = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    @State private var errorText: String?

    var body: some View {
        GroupBox("Automated Distillation (teacher → jsonl dataset → student LoRA)") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Student base model (HF repo)", text: $studentRepo)
                TextEditor(text: $seedPromptsText)
                    .font(.caption)
                    .frame(minHeight: 70)
                Text("Teacher: Apple Intelligence when available; the harness reports the specific reason if it is not.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Start distillation") { start() }
                        .disabled(module.distillationCoordinator.isRunning)
                    if module.distillationCoordinator.runningExperimentID == experiment.id {
                        Button("Cancel", role: .destructive) { module.distillationCoordinator.cancel() }
                    }
                }
            }
        }
    }

    private func start() {
        let seeds = seedPromptsText.split(whereSeparator: \.isNewline).map(String.init)
        guard !seeds.isEmpty else {
            errorText = "Enter at least one seed prompt."
            return
        }
        let job = DistillationJob(
            seedPrompts: seeds,
            teacherProvider: FoundationModelsInferenceProvider(),
            responseInstructionPrefix: "",
            studentBaseModelRepoID: studentRepo,
            rank: 16,
            numLayers: 8,
            iterations: 200,
            learningRate: 1e-4,
            batchSize: 1,
            datasetOutputName: "distill-\(UUID().uuidString)",
            adapterOutputName: "student-\(UUID().uuidString)"
        )
        do {
            try module.startDistillation(experiment: experiment, job: job)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Comparison view (item 7's comparison half)

struct ExperimentComparisonView: View {
    @Query(sort: \ExperimentRecord.createdAt, order: .reverse) private var experiments: [ExperimentRecord]
    @State private var selectedIDs: Set<String> = []

    private var comparison: ExperimentComparison {
        ExperimentComparison.compare(experiments.filter { selectedIDs.contains($0.id) })
    }

    var body: some View {
        List {
            Section("Runs") {
                ForEach(experiments) { experiment in
                    Button {
                        if selectedIDs.contains(experiment.id) {
                            selectedIDs.remove(experiment.id)
                        } else {
                            selectedIDs.insert(experiment.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.contains(experiment.id) ? "checkmark.circle.fill" : "circle")
                            Text(experiment.name)
                            Spacer()
                            Text(experiment.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if comparison.entries.count >= 2 {
                Section("Comparison (green = best per metric, direction-aware)") {
                    ComparisonGrid(comparison: comparison)
                    ForEach(comparison.metricNames, id: \.self) { metric in
                        if let best = comparison.best(forMetric: metric) {
                            Text("Best \(metric): \(best.name)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section {
                    Text("Select two or more runs to compare metrics side by side. Green is the best value per metric (direction-aware: losses and perplexity are lower-is-better).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Compare")
    }
}

/// The side-by-side run comparison rendered as a Grid (dynamic columns don't
/// fit SwiftUI Table's static column builder).
private struct ComparisonGrid: View {
    let comparison: ExperimentComparison

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Experiment").bold().font(.callout)
                ForEach(comparison.metricNames, id: \.self) { metric in
                    Text(metric).bold().font(.callout)
                }
                Text("Elapsed").bold().font(.callout)
            }
            ForEach(comparison.entries) { entry in
                GridRow {
                    Text(entry.name).font(.callout)
                    ForEach(comparison.metricNames, id: \.self) { metric in
                        ComparisonCell(comparison: comparison, metric: metric, row: entry)
                    }
                    Text(entry.elapsedSeconds.map { String(format: "%.1fs", $0) } ?? "—")
                        .font(.callout)
                }
            }
        }
    }
}

private struct ComparisonCell: View {
    let comparison: ExperimentComparison
    let metric: String
    let row: ExperimentComparisonEntry

    var body: some View {
        let isBest = comparison.best(forMetric: metric)?.id == row.id
        Text(String(format: "%.4g", row.finalMetrics[metric] ?? .nan))
            .font(.callout.monospacedDigit())
            .foregroundStyle(isBest ? .green : .primary)
            .bold(isBest)
    }
}
