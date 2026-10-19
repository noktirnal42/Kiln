import SwiftUI
import SwiftData
import ModelLabCore

// MARK: - Experiments: create/train runs + the comparison view (Prompt 5 item 7)

struct ModelLabExperimentsView: View {
    @Bindable var module: ModelLabModule
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExperimentRecord.createdAt, order: .reverse) private var experiments: [ExperimentRecord]
    @State private var selection: ExperimentRecord?
    @State private var showsNewSheet = false
    @State private var showsComparison = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(experiments) { experiment in
                    ExperimentRow(experiment: experiment)
                        .tag(experiment)
                }
                .onDelete { indexes in
                    for experiment in indexes.map({ experiments[$0] }) {
                        try? ExperimentStore(context: modelContext).delete(experiment)
                    }
                }
            }
            .overlay {
                if experiments.isEmpty {
                    ContentUnavailableView("No experiments", systemImage: "flask", description: Text("Create one, or use the built-in demo experiment."))
                }
            }
            .toolbar {
                Button("New Experiment", systemImage: "plus") { showsNewSheet = true }
                Button("Compare runs", systemImage: "rectangle.split.2x1") { showsComparison = true }
            }
            .navigationTitle("Experiments")
        } detail: {
            if let experiment = selection {
                ExperimentDetailView(module: module, experiment: experiment)
            } else {
                ContentUnavailableView("Select an experiment", systemImage: "flask")
            }
        }
        .sheet(isPresented: $showsNewSheet) {
            NewExperimentSheet(module: module)
        }
        .sheet(isPresented: $showsComparison) {
            ExperimentComparisonView()
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}

private struct ExperimentRow: View {
    let experiment: ExperimentRecord

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading) {
                Text(experiment.name)
                Text(experiment.task.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let elapsed = experiment.elapsedSeconds {
                Text(String(format: "%.1fs", elapsed)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        switch experiment.status {
        case .draft, .queued: "circle.dashed"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }

    private var statusColor: Color {
        switch experiment.status {
        case .completed: .green
        case .failed: .red
        case .running: .blue
        default: .secondary
        }
    }
}

private struct ExperimentDetailView: View {
    @Bindable var module: ModelLabModule
    @Bindable var experiment: ExperimentRecord
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = experiment.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                if let phase = currentPhase {
                    Label(phase.message, systemImage: "arrow.triangle.2.circlepath")
                }

                GroupBox("Run") {
                    LabeledGrid(rows: [
                        ("Task", experiment.task.displayName),
                        ("Status", experiment.status.rawValue.capitalized),
                        ("Dataset", experiment.datasetID),
                        ("Base model", experiment.baseModelID ?? "—"),
                        ("Columns", experiment.textColumn.map { "text: \($0)" } ?? experiment.labelColumn.map { "label: \($0)" } ?? "—"),
                        ("Elapsed", experiment.elapsedSeconds.map { String(format: "%.1fs", $0) } ?? "—"),
                        ("Artifact", experiment.producedArtifactID ?? "—"),
                    ])
                }

                if !experiment.hyperparameters.isEmpty {
                    GroupBox("Hyperparameters") {
                        LabeledGrid(rows: experiment.hyperparameters.keys.sorted().map { ($0, experiment.hyperparameters[$0] ?? "") })
                    }
                }

                if !experiment.metricsHistory.isEmpty {
                    GroupBox("Metric history") {
                        let finals = ExperimentComparison.finalMetrics(from: experiment.metricsHistory)
                        LabeledGrid(rows: finals.keys.sorted().map { ($0, String(format: "%.4g", finals[$0] ?? 0)) })
                    }
                }

                startControls
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle(experiment.name)
    }

    private var currentPhase: TrainingProgress? {
        if module.createMLCoordinator.runningExperimentID == experiment.id { return module.createMLCoordinator.latestPhase }
        if module.mlxFineTuningCoordinator.runningExperimentID == experiment.id { return module.mlxFineTuningCoordinator.latestPhase }
        if module.smallLMCoordinator.runningExperimentID == experiment.id { return module.smallLMCoordinator.latestPhase }
        if module.distillationCoordinator.runningExperimentID == experiment.id { return module.distillationCoordinator.latestPhase }
        return nil
    }

    @ViewBuilder
    private var startControls: some View {
        switch experiment.task {
        case .textClassification, .tabularClassification, .imageClassification:
            HStack {
                Button("Train with Create ML") { startCreateML() }
                    .disabled(runningCoordinator != nil)
                if module.createMLCoordinator.runningExperimentID == experiment.id {
                    Button("Cancel", role: .destructive) { module.createMLCoordinator.cancel() }
                }
            }
        case .mlxFineTuning:
            MLXLoRAControls(module: module, experiment: experiment)
        case .smallLMPretraining:
            SmallLMControls(module: module, experiment: experiment)
        case .distillation:
            DistillationControls(module: module, experiment: experiment)
        case .textGeneration, .logitDistillation, .gameAgentTraining:
            Label("Use the Playground for inference; logit distillation and game agents are engine smoke-test paths.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runningCoordinator: String? {
        [module.createMLCoordinator.runningExperimentID,
         module.mlxFineTuningCoordinator.runningExperimentID,
         module.smallLMCoordinator.runningExperimentID,
         module.distillationCoordinator.runningExperimentID]
            .compactMap { $0 }.first
    }

    private func startCreateML() {
        guard let dataset = datasetRecord(for: experiment) else { return }
        let job = TrainingJob(
            task: experiment.task,
            datasetFileURL: LibraryPaths.datasets.appendingPathComponent(dataset.localRelativePath ?? ""),
            textOrFeatureColumns: experiment.textColumn.map { [$0] } ?? experiment.featureColumns,
            labelColumn: experiment.labelColumn ?? "",
            validationFraction: Double(experiment.hyperparameters["validationFraction"] ?? "0.2") ?? 0.2,
            outputName: sanitizedOutputName(experiment.name)
        )
        do {
            try module.startCreateMLTraining(experiment: experiment, job: job)
        } catch {
            experiment.errorMessage = error.localizedDescription
        }
    }

    private func datasetRecord(for experiment: ExperimentRecord) -> DatasetRecord? {
        let context = modelContext
        let datasetID = experiment.datasetID
        let descriptor = FetchDescriptor<DatasetRecord>(predicate: #Predicate { $0.id == datasetID })
        return try? context.fetch(descriptor).first
    }

    private func sanitizedOutputName(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
    }
}

// MARK: - New experiment sheet

private struct NewExperimentSheet: View {
    @Bindable var module: ModelLabModule
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var datasets: [DatasetRecord]

    @State private var name = ""
    @State private var task: TaskType = .textClassification
    @State private var datasetID: String?
    @State private var textColumn = "text"
    @State private var labelColumn = "label"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Experiment").font(.headline)
            TextField("Name", text: $name)
            Picker("Task", selection: $task) {
                ForEach(TaskType.allCases.filter { supportedTasks.contains($0) }) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            Picker("Dataset", selection: $datasetID) {
                Text("None").tag(String?.none)
                ForEach(datasets) { dataset in
                    Text("\(dataset.name) (\(dataset.format.rawValue))").tag(String?.some(dataset.id))
                }
            }
            if task == .textClassification || task == .tabularClassification {
                TextField("Text/feature column", text: $textColumn)
                TextField("Label column", text: $labelColumn)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Create") { create() }.disabled(name.isEmpty || datasetID == nil)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            if datasetID == nil { datasetID = datasets.first?.id }
            if name.isEmpty, let first = datasets.first { name = "\(first.name) Classifier" }
        }
    }

    private var supportedTasks: [TaskType] {
        [.textClassification, .tabularClassification, .imageClassification, .mlxFineTuning, .smallLMPretraining, .distillation]
    }

    private func create() {
        let record = ExperimentRecord(
            name: name,
            task: task,
            datasetID: datasetID ?? "",
            textColumn: task == .textClassification ? textColumn : nil,
            labelColumn: (task == .textClassification || task == .tabularClassification) ? labelColumn : nil
        )
        do {
            try ExperimentStore(context: modelContext).create(record)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Shared labeled grid helper

struct LabeledGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}
