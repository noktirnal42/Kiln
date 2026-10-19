import SwiftUI
import SwiftData
import ModelLabCore

// MARK: - Models: artifact library + HF model discovery with memory-aware
// compatibility verdicts + export (Prompt 5 items 5/6/11)

struct ModelLabModelsView: View {
    @Bindable var module: ModelLabModule
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ModelArtifactRecord.createdAt, order: .reverse) private var models: [ModelArtifactRecord]

    @State private var selection: ModelArtifactRecord?
    @State private var showsExporter = false
    @State private var exportDestination: URL?

    @State private var hfQuery = "mlx-community"
    @State private var hfResults: [ModelSearchResult] = []
    @State private var hfError: String?
    @State private var hfLoading = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    ForEach(models) { record in
                        HStack {
                            Image(systemName: icon(for: record.format))
                            VStack(alignment: .leading) {
                                Text(record.name)
                                Text(record.format.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let size = record.sizeBytes {
                                Text(HardwareProfile.formatBytes(size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(record)
                    }
                    .onDelete { indexes in
                        for record in indexes.map({ models[$0] }) {
                            try? ModelLabCore.ModelRegistry(context: modelContext).delete(record)
                        }
                    }
                }
                Section("Hugging Face models") {
                    HStack {
                        TextField("Search models", text: $hfQuery).onSubmit(searchHF)
                        Button("Search", action: searchHF).disabled(hfQuery.isEmpty || hfLoading)
                        if hfLoading { ProgressView().controlSize(.small) }
                    }
                    if let hfError {
                        Text(hfError).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(hfResults.prefix(15)) { result in
                        HFModelRow(module: module, result: result)
                    }
                }
            }
            .navigationTitle("Models")
        } detail: {
            if let record = selection {
                ModelArtifactDetailView(module: module, record: record)
            } else {
                ContentUnavailableView("Select a model", systemImage: "cube")
            }
        }
    }

    private func searchHF() {
        hfError = nil
        hfLoading = true
        Task { @MainActor in
            do {
                hfResults = try await module.searchHuggingFaceModels(query: hfQuery)
            } catch {
                hfError = "Hugging Face search failed: \(error.localizedDescription)"
            }
            hfLoading = false
        }
    }

    private func icon(for format: ModelFormat) -> String {
        switch format {
        case .mlmodel, .mlpackage: "cylinder.split.1x2"
        case .mlxHubRepository: "arrow.down.circle"
        case .mlxFolder, .mlxScratchModel: "folder"
        case .mlxLoraAdapter: "slider.horizontal.3"
        case .gameAgentPolicy: "gamecontroller"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

private struct HFModelRow: View {
    @Bindable var module: ModelLabModule
    let result: ModelSearchResult
    @Environment(\.modelContext) private var modelContext
    @State private var verdictText: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(result.name)
                HStack(spacing: 8) {
                    if let downloads = result.downloads {
                        Text("↓ \(downloads.formatted())").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let likes = result.likes {
                        Text("♥ \(likes)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let pipeline = result.pipelineTag {
                        Text(pipeline).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if let verdictText {
                Text(verdictText).font(.caption2).foregroundStyle(verdictText.contains("fits") ? .green : .orange)
            }
            Button("Register") { register() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .task {
            // Memory-aware verdict from the repo's real file sizes, per
            // HardwareProfile; nil → "unknown size" is shown honestly.
            do {
                let details = try await HuggingFaceModelProvider().fetchDetails(id: result.id)
                let weightBytes = details.files
                    .filter { $0.path.hasSuffix(".safetensors") || $0.path.hasSuffix(".gguf") || $0.path.hasSuffix(".bin") }
                    .compactMap(\.sizeBytes)
                    .reduce(0, +)
                if weightBytes == 0 {
                    verdictText = nil
                } else {
                    switch module.hardware.canLoad(weightsBytes: weightBytes, forTraining: false) {
                    case .fits: verdictText = "Fits (\(HardwareProfile.formatBytes(weightBytes)) weights)"
                    case .tight: verdictText = "Tight on \(module.hardware.memoryGB) GB (\(HardwareProfile.formatBytes(weightBytes)) weights)"
                    case .doesNotFit: verdictText = "Too large for \(module.hardware.memoryGB) GB (\(HardwareProfile.formatBytes(weightBytes)) weights)"
                    }
                }
            } catch {
                verdictText = nil
            }
        }
    }

    private func register() {
        _ = try? ModelLabCore.ModelRegistry(context: modelContext).registerHuggingFaceMLXRepository(id: result.id)
    }
}

private struct ModelArtifactDetailView: View {
    @Bindable var module: ModelLabModule
    @Bindable var record: ModelArtifactRecord

    @State private var exportMessage: String?
    @State private var showsFolderPicker = false
    @State private var pendingFormat: ModelExporters.ExportFormat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Artifact") {
                    LabeledGrid(rows: [
                        ("Name", record.name),
                        ("Format", record.format.displayName),
                        ("Size", record.sizeBytes.map { HardwareProfile.formatBytes($0) } ?? "unknown"),
                        ("Path", record.localRelativePath),
                        ("Origin", record.origin.rawValue),
                        ("Notes", record.notes),
                    ])
                }

                GroupBox("Export") {
                    VStack(alignment: .leading, spacing: 8) {
                        exportRow(.coreML)
                        exportRow(.mlxPackage)
                        exportRow(.gguf)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle(record.name)
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let destination) = result {
                export(to: destination)
            }
        }
    }

    private func absoluteURL() -> URL? {
        switch record.format {
        case .mlxHubRepository:
            return nil
        default:
            return ModelLabCore.ArtifactStore().absoluteURL(for: record.localRelativePath, in: .models)
        }
    }

    private func exportStatus(_ format: ModelExporters.ExportFormat) -> CapabilityStatus {
        let exporters = ModelExporters()
        switch format {
        case .coreML: return exporters.coreMLCapability(for: record, absoluteURL: absoluteURL())
        case .mlxPackage: return exporters.mlxPackageCapability(for: record, absoluteURL: absoluteURL())
        case .gguf: return ModelExporters.ggufCapability()
        }
    }

    @ViewBuilder
    private func exportRow(_ format: ModelExporters.ExportFormat) -> some View {
        let status = exportStatus(format)
        HStack {
            VStack(alignment: .leading) {
                Text(format.displayName)
                if let reason = status.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Export…") {
                pendingFormat = format
                showsFolderPicker = true
            }
            .disabled(!status.isAvailable)
            .help(status.reason ?? "Export a copy of this artifact.")
        }
        if let exportMessage {
            Text(exportMessage).font(.caption)
        }
    }

    private func export(to destination: URL) {
        guard let format = pendingFormat else { return }
        let securityScoped = destination.startAccessingSecurityScopedResource()
        defer { if securityScoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            let url = try ModelExporters().export(record: record, absoluteURL: absoluteURL(), format: format, to: destination)
            exportMessage = "Exported to \(url.path)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
