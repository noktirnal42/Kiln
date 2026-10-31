import SwiftUI

struct REModuleRootView: View {
    @Bindable var module: REModule

    var body: some View {
        // Plain HStack, not NavigationSplitView: this view is itself the detail of the app's
        // split view, and a nested split view squeezed the app sidebar and clipped content.
        HStack(spacing: 0) {
            REProjectBrowser(module: module)
                .frame(width: 240)
            Divider()
            Group {
                if let project = module.selected, let analysis = project.analysis {
                    REProjectDetail(module: module, project: project, analysis: analysis)
                        .id(project.id)
                } else {
                    ContentUnavailableView("No project", systemImage: "cube",
                                           description: Text("Import a binary to begin analysis."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct REProjectBrowser: View {
    @Bindable var module: REModule
    @State private var importer = false
    @State private var importError: String?
    @State private var showBench = false

    var body: some View {
        List {
            Section("Projects") {
                ForEach(module.projects) { project in
                    Button {
                        module.select(projectID: project.id)
                    } label: {
                        HStack {
                            Image(systemName: "cube")
                            VStack(alignment: .leading) {
                                Text(project.binaryURL.lastPathComponent)
                                    .font(.headline)
                                Text(project.folder.lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(functionSummary(for: project))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { module.projects[$0].id }
                    Task {
                        for id in ids { try? await module.deleteProject(id: id) }
                    }
                }
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
        }
        .toolbar {
            Button("Device Bench…", systemImage: "cable.connector") { showBench = true }
            Button("Import Binary…", systemImage: "arrow.down.doc") { importer = true }
        }
        .sheet(isPresented: $showBench) {
            REDeviceBenchView(bench: module.deviceBench)
        }
        .navigationTitle("Projects")
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do {
                    _ = try await module.importBinary(at: url)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func functionSummary(for project: REModule.REProject) -> String {
        guard let analysis = project.analysis else { return "—" }
        return "\(analysis.functions.count) functions"
    }
}
