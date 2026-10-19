import SwiftUI
import SwiftData
import ModelLabCore

// MARK: - Datasets: local import + Hugging Face discovery (engine providers)

struct ModelLabDatasetsView: View {
    @Bindable var module: ModelLabModule
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DatasetRecord.createdAt, order: .reverse) private var datasets: [DatasetRecord]

    @State private var showsImporter = false
    @State private var hfQuery = ""
    @State private var hfResults: [DatasetSearchResult] = []
    @State private var hfError: String?
    @State private var hfLoading = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                Button("Import local dataset…", systemImage: "square.and.arrow.down") { showsImporter = true }
                Text("CSV, JSON, JSONL, TXT, or a folder of label-named image subfolders. Files are copied into the Model Lab library; nothing is modified in place.")
                    .font(.caption).foregroundStyle(.secondary)
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Library") {
                ForEach(datasets) { dataset in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(dataset.name)
                            Spacer()
                            Text(dataset.format.rawValue).font(.caption).padding(3)
                                .background(.quinary).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(datasetSubtitle(dataset))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { indexes in
                    for dataset in indexes.map({ datasets[$0] }) {
                        if let relativePath = dataset.localRelativePath {
                            try? ModelLabCore.ArtifactStore().delete(relativePath: relativePath, in: .datasets)
                        }
                        modelContext.delete(dataset)
                    }
                    try? modelContext.save()
                }
            }
            Section("Hugging Face datasets (public API)") {
                HStack {
                    TextField("Search datasets", text: $hfQuery)
                        .onSubmit { searchHF() }
                    Button("Search", action: searchHF).disabled(hfQuery.isEmpty || hfLoading)
                    if hfLoading { ProgressView().controlSize(.small) }
                }
                if let hfError {
                    Text(hfError).font(.caption).foregroundStyle(.red)
                }
                ForEach(hfResults.prefix(15)) { result in
                    VStack(alignment: .leading) {
                        Text(result.name)
                        Text(result.summary ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let downloads = result.downloads {
                            Text("\(downloads.formatted()) downloads").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if hfResults.isEmpty && hfError == nil && !hfLoading {
                    Text("Search lists public dataset repositories. Registering one records its metadata; importing its files for training uses the local import above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Datasets")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            importLocal(result)
        }
    }

    private func searchHF() {
        hfError = nil
        hfLoading = true
        Task { @MainActor in
            do {
                hfResults = try await module.searchHuggingFaceDatasets(query: hfQuery)
            } catch {
                hfError = "Hugging Face search failed: \(error.localizedDescription)"
            }
            hfLoading = false
        }
    }

    private func datasetSubtitle(_ dataset: DatasetRecord) -> String {
        var parts: [String] = []
        if let rows = dataset.rowCount { parts.append("\(rows) rows") }
        if !dataset.columns.isEmpty { parts.append(dataset.columns.joined(separator: ", ")) }
        parts.append(dataset.sourceKind.rawValue)
        return parts.joined(separator: " · ")
    }

    private func importLocal(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let importer = DatasetImporter()
            let format = importer.detectFormat(at: url)
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
            modelContext.insert(record)
            try modelContext.save()
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
}
