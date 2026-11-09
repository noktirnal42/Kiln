import SwiftUI
import Foundation
import AppKit

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
    @State private var showPackageIntake = false

    var body: some View {
        List {
            Section("Projects") {
                HStack(spacing: SSSpacing.s) {
                    Button { importer = true } label: {
                        Label("Import…", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
                    }
                    Button { showPackageIntake = true } label: {
                        Label("Download…", systemImage: "shippingbox").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SSColor.accent)
                }
                .controlSize(.small)

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
            Button("Get Package…", systemImage: "shippingbox") { showPackageIntake = true }
        }
        .sheet(isPresented: $showBench) {
            REDeviceBenchView(bench: module.deviceBench)
        }
        .sheet(isPresented: $showPackageIntake) {
            REPackageIntakeView(module: module)
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

/// Kiln-branded package intake that feeds the existing AxiomCore import path.
struct REPackageIntakeView: View {
    @Bindable var module: REModule
    @Environment(\.dismiss) private var dismiss
    @State private var source: KilnPackageSource = .aptoide
    @State private var query = ""
    @State private var results: [KilnPackageResult] = []
    @State private var searching = false
    @State private var urlText = ""
    @State private var expectedMD5: String?
    @State private var expectedMD5URL: String?
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            HStack(spacing: SSSpacing.s) {
                Image("KilnMark").resizable().scaledToFit().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get a package").font(SSTypography.headline())
                    Text("Bring an authorized IPA, APK, DEB, or native bundle into Kiln.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
            }
            Divider()
            Picker("Source", selection: $source) {
                ForEach(KilnPackageSource.allCases) { source in
                    Label(source.title, systemImage: source.icon).tag(source)
                }
            }
            .pickerStyle(.segmented)
            Text(source.helpText).font(SSTypography.caption()).foregroundStyle(.secondary)
            HStack {
                TextField(source == .direct ? "https://…/package.ipa" : "App name or bundle identifier", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button(searching ? "Searching…" : "Search") { search() }
                    .buttonStyle(.borderedProminent).tint(SSColor.accent)
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SSSpacing.s) {
                        ForEach(results) { result in
                            HStack(spacing: SSSpacing.s) {
                                Image(systemName: result.directURL == nil ? "arrow.up.right.square" : "arrow.down.circle.fill")
                                    .foregroundStyle(result.directURL == nil ? .secondary : SSColor.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name).font(SSTypography.body())
                                    Text(result.detail).font(SSTypography.caption()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(result.directURL == nil ? "Open listing" : "Download") { handle(result) }
                                    .buttonStyle(.bordered)
                            }
                            .padding(SSSpacing.s)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            Divider()
            TextField("Direct package URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { download() }
            HStack {
                Text("Downloaded packages remain local and enter the read-only RE pipeline.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
                Spacer()
                Button(busy ? "Downloading…" : "Download and inspect") { download() }
                    .buttonStyle(.borderedProminent).tint(SSColor.accent)
                    .disabled(busy || (try? KilnPackageCatalog.downloadableURL(urlText)) == nil)
            }
            if let status { Text(status).font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
        }
        .padding(SSSpacing.l)
        .frame(width: 620, height: 560)
    }

    private func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !searching else { return }
        searching = true; status = nil; results = []
        Task {
            do {
                let found = try await KilnPackageCatalog.search(source: source, query: value)
                await MainActor.run { results = found; searching = false; status = found.isEmpty ? "No packages found." : nil }
            } catch {
                await MainActor.run { searching = false; status = error.localizedDescription }
            }
        }
    }

    private func handle(_ result: KilnPackageResult) {
        guard let url = result.directURL else { NSWorkspace.shared.open(result.listingURL); return }
        urlText = url.absoluteString
        expectedMD5 = result.md5
        expectedMD5URL = url.absoluteString
        download()
    }

    private func download() {
        guard !busy, (try? KilnPackageCatalog.downloadableURL(urlText)) != nil else { return }
        busy = true; status = nil
        Task {
            do {
                let url = try KilnPackageCatalog.downloadableURL(urlText)
                let saved = try await KilnPackageCatalog.download(
                    url, into: KilnPackageCatalog.defaultDownloadsFolder,
                    expectedMD5: urlText == expectedMD5URL ? expectedMD5 : nil)
                _ = try await module.importBinary(at: saved)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { busy = false; status = error.localizedDescription }
            }
        }
    }
}
