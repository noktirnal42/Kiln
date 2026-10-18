import SwiftUI
import WebKit

struct ArtifactsBrowserView: View {
    let artifactStore: ArtifactStore
    @Environment(\.dismiss) private var dismiss
    @State private var artifacts: [ArtifactSummary] = []
    @State private var selected: ArtifactSummary?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Artifacts").font(SSTypography.title())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(SSSpacing.m)
            Divider()
            if let errorText {
                Text(errorText).font(SSTypography.caption()).foregroundStyle(SSColor.warning).padding(SSSpacing.s)
                Divider()
            }
            HSplitView {
                List(artifacts) { artifact in
                    Button {
                        selected = artifact
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: SSSpacing.xs) {
                                Image(systemName: icon(for: artifact.kind))
                                Text(artifact.title).font(SSTypography.body()).lineLimit(1)
                            }
                            Text("\(artifact.kind.rawValue) · v\(artifact.version) · \(artifact.byteCount) B")
                                .font(SSTypography.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected?.id == artifact.id ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .frame(minWidth: 240, idealWidth: 280)

                if let selected {
                    ArtifactDetailView(store: artifactStore, summary: selected, onChanged: { refresh() })
                } else {
                    ContentUnavailableView("No Artifact Selected", systemImage: "shippingbox")
                        .frame(minWidth: 400)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .task { refresh() }
    }

    private func refresh() {
        Task {
            do {
                artifacts = try await artifactStore.artifacts()
                errorText = nil
            } catch {
                errorText = "Could not load artifacts: \(error)"
            }
        }
    }

    private func icon(for kind: ArtifactKind) -> String {
        switch kind {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .markdown: return "doc.richtext"
        case .html: return "globe"
        case .mermaid: return "flowchart"
        case .data: return "tablecells"
        }
    }
}

struct ArtifactDetailView: View {
    let store: ArtifactStore
    let summary: ArtifactSummary
    let onChanged: () -> Void

    @State private var content = ""
    @State private var versions: [ArtifactVersionSnapshot] = []
    @State private var selectedVersion: Int?
    @State private var errorText: String?
    @State private var table: DataTableParser.Table?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SSSpacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(SSTypography.headline())
                    Text("\(summary.kind.rawValue)\(summary.language.map { " · \($0)" } ?? "") · \(summary.byteCount) B")
                        .font(SSTypography.caption())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Version", selection: $selectedVersion) {
                    Text("latest (\(summary.version))").tag(Int?.none)
                    ForEach(versions) { version in
                        Text("v\(version.version)").tag(Int?.some(version.version))
                    }
                }
                .frame(width: 160)
                Button("Export…") { export() }
                Button("Delete", role: .destructive) { delete() }
            }
            .padding(SSSpacing.m)
            Divider()
            if let errorText {
                Text(errorText).font(SSTypography.caption()).foregroundStyle(SSColor.danger).padding(SSSpacing.s)
                Divider()
            }
            contentView
        }
        .task { await load() }
        .onChange(of: selectedVersion) { _, _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch summary.kind {
        case .code:
            ScrollView {
                CodeSpanView(spans: CodeHighlighter.highlight(content, language: summary.language))
                    .padding(SSSpacing.m)
            }
        case .markdown:
            ScrollView {
                MarkdownBlockView(text: content).padding(SSSpacing.m)
            }
        case .html:
            SandboxedHTMLView(html: content)
        case .mermaid:
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                Label("Mermaid rendering needs a diagram engine; showing source honestly rather than a broken picture.", systemImage: "info.circle")
                    .font(SSTypography.caption())
                    .foregroundStyle(SSColor.warning)
                    .padding(.horizontal, SSSpacing.m)
                    .padding(.top, SSSpacing.s)
                ScrollView {
                    CodeSpanView(spans: CodeHighlighter.highlight(content, language: "mermaid"))
                        .padding(SSSpacing.m)
                }
            }
        case .data:
            if let table {
                DataTableView(table: table)
            } else {
                Text("Data could not be parsed as JSON or CSV.").foregroundStyle(.secondary).padding(SSSpacing.m)
            }
        }
    }

    private func load() async {
        errorText = nil
        table = nil
        do {
            let data: Data
            if let selectedVersion {
                data = try await store.content(of: summary.id, version: selectedVersion)
            } else {
                data = try await store.content(of: summary.id)
            }
            content = String(decoding: data, as: UTF8.self)
            if summary.kind == .data {
                table = try? DataTableParser.parse(data)
            }
            versions = try await store.versions(of: summary.id)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = summary.title
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await store.content(of: summary.id)
                try data.write(to: url, options: .atomic)
                errorText = nil
            } catch {
                errorText = "Export failed: \(error)"
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await store.delete(summary.id)
                onChanged()
            } catch {
                errorText = "Delete failed: \(error)"
            }
        }
    }
}

struct SandboxedHTMLView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.isElementFullscreenEnabled = false
        configuration.preferences = preferences
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

struct DataTableView: View {
    let table: DataTableParser.Table

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(table.columns, id: \.self) { column in
                        Text(column)
                            .font(SSTypography.caption().weight(.semibold))
                            .frame(width: 160, alignment: .leading).frame(minHeight: 24)
                            .padding(.horizontal, SSSpacing.xs)
                    }
                }
                .background(Color.secondary.opacity(0.1))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(SSTypography.mono(11))
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading).frame(minHeight: 22)
                                .padding(.horizontal, SSSpacing.xs)
                        }
                    }
                    .background(index % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                }
            }
        }
    }
}
