import SwiftUI
import Foundation
import AppKit

struct REModuleRootView: View {
    @Bindable var module: REModule
    /// The project list gives way to the work when the window is narrow; the header button brings it back.
    @State private var projectsVisible = true
    @State private var decidedInitialLayout = false

    var body: some View {
        // Plain HStack, not NavigationSplitView: this view is itself the detail of the app's
        // split view, and a nested split view squeezed the app sidebar and clipped content.
        GeometryReader { geometry in
        HStack(spacing: 0) {
            if projectsVisible {
                REProjectBrowser(module: module)
                    .frame(width: 220)
                Divider()
            }
            Group {
                if let project = module.selected, let analysis = project.analysis {
                    REProjectDetail(module: module, project: project, analysis: analysis, projectsVisible: $projectsVisible)
                        .id(project.id)
                } else {
                    SSEmptyState(symbol: "cube", title: "No project selected",
                                 message: "Import a binary or download a package from the Projects pane to begin analysis.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !decidedInitialLayout else { return }
            decidedInitialLayout = true
            projectsVisible = geometry.size.width >= 820
        }
        }
        .background(SSColor.canvas)
    }
}

struct REProjectBrowser: View {
    @Bindable var module: REModule
    @State private var importer = false
    @State private var importError: String?
    @State private var showBench = false
    @State private var showPackageIntake = false

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: "Projects", count: module.projects.count) {
                Menu {
                    Button("Import Binary…", systemImage: "arrow.down.doc") { importer = true }
                    Button("Download Package…", systemImage: "shippingbox") { showPackageIntake = true }
                    Divider()
                    Button("Device Bench…", systemImage: "cable.connector") { showBench = true }
                } label: { Label("Add", systemImage: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Add a project")
            }
            HStack(spacing: SSSpacing.s) {
                Button { importer = true } label: { Label("Import…", systemImage: "arrow.down.doc").frame(maxWidth: .infinity) }
                Button { showPackageIntake = true } label: { Label("Download…", systemImage: "shippingbox").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(SSColor.accent)
            }
            .controlSize(.small)
            .padding(SSSpacing.s)
            if module.projects.isEmpty {
                SSEmptyState(symbol: "cube.transparent", title: "No projects yet",
                             message: "Import a Mach-O, ELF or PE binary, or download an IPA or APK.")
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(module.projects) { project in projectRow(project) }
                    }
                    .padding(.horizontal, SSSpacing.s)
                }
            }
            if let importError {
                Text(importError).font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                    .padding(SSSpacing.s).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SSColor.surface)
        .sheet(isPresented: $showBench) { REDeviceBenchView(bench: module.deviceBench) }
        .sheet(isPresented: $showPackageIntake) { REPackageIntakeView(module: module) }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do { _ = try await module.importBinary(at: url) }
                catch { importError = error.localizedDescription }
            }
        }
    }

    private func projectRow(_ project: REModule.REProject) -> some View {
        let selected = module.selected?.id == project.id
        return Button { module.select(projectID: project.id) } label: {
            HStack(spacing: SSSpacing.s) {
                Image(systemName: "cube").foregroundStyle(selected ? SSColor.accent : .secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.binaryURL.lastPathComponent).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(functionSummary(for: project)).font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SSSpacing.s).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SSColor.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.binaryURL.path)
        .contextMenu {
            Button("Delete Project", role: .destructive) { Task { try? await module.deleteProject(id: project.id) } }
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
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
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
        .frame(width: 620, height: results.isEmpty ? 330 : 520, alignment: .top)
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
