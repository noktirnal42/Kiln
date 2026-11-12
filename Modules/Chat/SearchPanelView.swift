import SwiftUI

struct SearchPanelView: View {
    let service: FileIndexService
    /// The current project folder; indexed automatically when nothing else has been opened.
    var projectRoot: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var indexedRoot: String?
    @State private var resultCount = 0

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: "Workspace search") {
                if let root = indexedRoot {
                    Text(root).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Button("Open Folder…") { openFolder() }
            }
            HStack {
                TextField("Search file names…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || indexedRoot == nil)
            }
            .padding(SSSpacing.m)
            if searching {
                ProgressView().padding(SSSpacing.s)
            }
            Divider()
            if hits.isEmpty {
                SSEmptyState(symbol: "magnifyingglass",
                             title: indexedRoot == nil ? "No folder open" : (query.isEmpty ? "Search file names" : "No results"),
                             message: indexedRoot == nil ? "Open a project folder to index its file names." : (query.isEmpty ? "Type part of a file name and press Return." : "Nothing matched “\(query)”."))
            } else {
                Text("\(resultCount) results — merged from FTS5 index and Spotlight")
                    .font(SSTypography.caption())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SSSpacing.m)
                    .padding(.vertical, SSSpacing.xs)
                List(hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: SSSpacing.xs) {
                            Text(hit.file.name).font(SSTypography.body())
                            ForEach(hit.sources, id: \.self) { source in
                                Text(source.rawValue.uppercased())
                                    .font(SSTypography.caption())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(hit.file.size), countStyle: .file))
                                .font(SSTypography.caption())
                                .foregroundStyle(.tertiary)
                        }
                        Text(hit.file.absolutePath)
                            .font(SSTypography.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(minHeight: 320)
        .task(id: projectRoot) {
            indexedRoot = await service.indexedRootPath()
            if let projectRoot, indexedRoot != projectRoot {
                try? await service.index(root: projectRoot)
                indexedRoot = await service.indexedRootPath()
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            try? await service.index(root: url.path)
            indexedRoot = await service.indexedRootPath()
            search()
        }
    }

    private func search() {
        guard indexedRoot != nil else { return }
        searching = true
        Task {
            let results = await service.search(query, limit: 50)
            hits = results
            resultCount = results.count
            searching = false
        }
    }
}
