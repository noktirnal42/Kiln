import AppKit
import SwiftUI

// Pieces of the Develop editor that follow Xcode's layout: the jump bar over the editor, the navigator's Symbols,
// Issues, Tests and References lists, and the activity strip in the status bar. They read `DevelopController`, the same
// service the command palette and the agent's `ide_*` tools use, so what the user sees is what the agent changes.

extension LSPSymbol.Kind {
    var tint: Color {
        switch self {
        case .class, .struct, .enum, .interface: SSColor.accent
        case .function, .method, .constructor: .blue
        case .enumMember: .orange
        case .module, .namespace, .package: .purple
        default: .teal
        }
    }
}

/// A symbol badge like Xcode's: a coloured rounded square with the kind's letter.
struct SymbolBadge: View {
    let kind: LSPSymbol.Kind
    var body: some View {
        Image(systemName: kind.symbolName)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

// MARK: - Jump bar

/// Path and symbol trail above the editor. Each part is a menu of its siblings; ‹ › move through places visited.
struct DevelopJumpBar: View {
    let develop: DevelopController
    let document: EditorDocument
    @State private var showOutline = false

    private var editor: EditorWorkspace { develop.editor }
    private var outline: [LSPSymbol] { develop.outlines[document.id] ?? [] }

    var body: some View {
        HStack(spacing: 2) {
            Button { develop.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!develop.canGoBack).help("Go back (⌃⌘←)").accessibilityLabel("Go back")
            Button { develop.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!develop.canGoForward).help("Go forward (⌃⌘→)").accessibilityLabel("Go forward")
            separator
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, part in
                        if index > 0 { chevron }
                        pathMenu(part)
                    }
                    let trail = LSPSymbol.trail(at: editor.caret.line - 1, in: outline)
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, symbol in
                        chevron
                        symbolMenu(symbol, siblings: index == 0 ? outline : trail[index - 1].children)
                    }
                }
                .padding(.horizontal, 2)
            }
            Spacer(minLength: 0)
            Button { showOutline.toggle() } label: { Image(systemName: "list.bullet.indent") }
                .help("Document items").accessibilityLabel("Document items")
                .popover(isPresented: $showOutline) {
                    DevelopSymbolList(develop: develop, document: document).frame(width: 300, height: 360)
                }
        }
        .buttonStyle(.borderless)
        .font(SSTypography.caption())
        .foregroundStyle(.secondary)
        .padding(.horizontal, SSSpacing.s)
        .frame(height: 24)
        .background(SSColor.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(SSColor.hairline).frame(height: 1) }
    }

    private var separator: some View { Rectangle().fill(SSColor.hairline).frame(width: 1, height: 12).padding(.horizontal, 4) }
    private var chevron: some View { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }

    private struct PathPart { var url: URL; var isFile: Bool }

    private var pathComponents: [PathPart] {
        let file = document.url
        guard let root = editor.root, file.path.hasPrefix(root.path + "/") else { return [PathPart(url: file, isFile: true)] }
        var parts = [PathPart(url: root, isFile: false)]
        var current = root
        let relative = file.path.dropFirst(root.path.count + 1).split(separator: "/")
        for (offset, name) in relative.enumerated() {
            current = current.appendingPathComponent(String(name))
            parts.append(PathPart(url: current, isFile: offset == relative.count - 1))
        }
        return parts
    }

    private func pathMenu(_ part: PathPart) -> some View {
        let directory = part.isFile ? part.url.deletingLastPathComponent() : part.url
        return Menu {
            ForEach(editor.children(of: directory).prefix(80)) { node in
                Button {
                    if node.isDirectory { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } else { editor.open(node.url) }
                } label: { Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text") }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: part.isFile ? "swift" : "folder").font(.system(size: 10))
                Text(part.url.lastPathComponent).lineLimit(1)
            }
            .foregroundStyle(part.isFile && siblingsEmptyTrail ? Color.primary : Color.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var siblingsEmptyTrail: Bool { LSPSymbol.trail(at: editor.caret.line - 1, in: outline).isEmpty }

    private func symbolMenu(_ symbol: LSPSymbol, siblings: [LSPSymbol]) -> some View {
        Menu {
            ForEach(siblings) { sibling in
                Button { editor.pendingLine = (document.id, sibling.line + 1, sibling.column + 1) } label: {
                    Label(sibling.name, systemImage: sibling.kind.symbolName)
                }
            }
        } label: {
            HStack(spacing: 3) {
                SymbolBadge(kind: symbol.kind)
                Text(symbol.name).lineLimit(1)
            }
            .foregroundStyle(Color.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - Symbols

struct DevelopSymbolList: View {
    let develop: DevelopController
    let document: EditorDocument
    @State private var filter = ""

    private var rows: [(symbol: LSPSymbol, depth: Int)] {
        let all = (develop.outlines[document.id] ?? []).flatMap { $0.flattened() }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.symbol.name.localizedCaseInsensitiveContains(filter) }.map { ($0.symbol, 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter symbols", text: $filter)
                .textFieldStyle(.roundedBorder).padding(SSSpacing.xs)
            if rows.isEmpty {
                SSEmptyState(symbol: "list.bullet.indent", title: filter.isEmpty ? "No symbols" : "No match",
                             message: filter.isEmpty ? "This file has no recognised declarations." : "Nothing in \(document.name) matches “\(filter)”.")
            } else {
                List(rows, id: \.symbol.id) { row in
                    Button {
                        develop.editor.pendingLine = (document.id, row.symbol.line + 1, row.symbol.column + 1)
                    } label: {
                        HStack(spacing: 5) {
                            SymbolBadge(kind: row.symbol.kind)
                            Text(row.symbol.name).font(SSTypography.caption()).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(row.symbol.line + 1)").font(SSTypography.mono(10)).foregroundStyle(.tertiary)
                        }
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.symbol.kind.label) \(row.symbol.name), line \(row.symbol.line + 1)")
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Issues

struct DevelopIssuesList: View {
    let develop: DevelopController
    let onAskAgent: () -> Void

    private var editor: EditorWorkspace { develop.editor }

    /// Build problems plus the language server's for every open file, errors first, grouped by file.
    private var groups: [(path: String, items: [Diagnostic])] {
        var list = develop.builder.diagnostics
        for (path, live) in editor.languageServer.diagnostics {
            for item in live {
                list.append(Diagnostic(path: path, line: item.line + 1, column: item.column + 1, severity: item.severity, message: item.message))
            }
        }
        let unique = list.reduce(into: [Diagnostic]()) { result, item in
            if !result.contains(where: { $0.path == item.path && $0.line == item.line && $0.message == item.message }) { result.append(item) }
        }
        return Dictionary(grouping: unique, by: \.path).map { ($0.key, $0.value.sorted { $0.line < $1.line }) }
            .sorted { lhs, rhs in
                let l = lhs.1.contains { $0.severity == .error }, r = rhs.1.contains { $0.severity == .error }
                return l != r ? l : lhs.0 < rhs.0
            }
    }

    var body: some View {
        let groups = groups
        VStack(spacing: 0) {
            HStack {
                Text("\(groups.flatMap(\.items).filter { $0.severity == .error }.count) errors, \(groups.flatMap(\.items).filter { $0.severity == .warning }.count) warnings")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
                Spacer()
                if develop.builder.errorCount > 0 {
                    Button(action: onAskAgent) { Image(systemName: "sparkles") }
                        .buttonStyle(.borderless).help("Ask the agent to fix the build errors").accessibilityLabel("Ask the agent to fix the build errors")
                }
            }
            .padding(SSSpacing.xs)
            if groups.isEmpty {
                SSEmptyState(symbol: "checkmark.seal", title: "No issues", message: "Build with ⌘B; errors and warnings from the build and the language server appear here.")
            } else {
                List {
                    ForEach(groups, id: \.path) { group in
                        Section(editor.displayPath(URL(fileURLWithPath: group.path))) {
                            ForEach(group.items) { item in
                                Button { develop.jump(to: item.path, line: item.line, column: item.column) } label: {
                                    HStack(alignment: .top, spacing: 5) {
                                        Image(systemName: item.severity == .error ? "xmark.octagon.fill" : item.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                            .foregroundStyle(item.severity == .error ? SSColor.danger : item.severity == .warning ? SSColor.warning : .secondary)
                                            .font(.system(size: 11))
                                        Text(item.message).font(SSTypography.caption()).lineLimit(3).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        Text("\(item.line)").font(SSTypography.mono(10)).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.severity.rawValue): \(item.message), line \(item.line)")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

// MARK: - Tests

struct DevelopTestsList: View {
    let develop: DevelopController
    let run: (String?) -> Void

    var body: some View {
        let results = develop.builder.testResults
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { run(nil) } label: { Label("Run All", systemImage: "play.diamond") }
                    .disabled(develop.builder.isRunning || develop.editor.debug.isActive)
                if results.contains(where: { $0.status == .failed }) {
                    Button { run(results.first { $0.status == .failed }?.name) } label: { Label("Re-run First Failure", systemImage: "arrow.counterclockwise") }
                        .disabled(develop.builder.isRunning)
                }
                Spacer()
                Text(results.isEmpty ? "No results yet" : "\(results.filter { $0.status == .passed }.count)/\(results.count) passed")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).font(SSTypography.caption()).padding(SSSpacing.xs)
            if results.isEmpty {
                SSEmptyState(symbol: "checkmark.diamond", title: "No test results", message: "Press ⌘U. Each test's result appears here, with a button to run it alone.")
            } else {
                List(results) { result in
                    HStack(spacing: 6) {
                        Image(systemName: result.status == .passed ? "checkmark.diamond.fill" : result.status == .failed ? "xmark.diamond.fill" : "minus.diamond")
                            .foregroundStyle(result.status == .passed ? SSColor.success : result.status == .failed ? SSColor.danger : .secondary)
                        Text(result.name).font(SSTypography.caption()).lineLimit(2)
                        Spacer(minLength: 0)
                        if let seconds = result.seconds { Text(String(format: "%.2fs", seconds)).font(SSTypography.mono(10)).foregroundStyle(.tertiary) }
                        Button { run(result.name) } label: { Image(systemName: "play.fill").font(.system(size: 9)) }
                            .buttonStyle(.borderless).help("Run only this test").accessibilityLabel("Run \(result.name)")
                            .disabled(develop.builder.isRunning)
                    }
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - References

struct DevelopReferencesList: View {
    let develop: DevelopController
    let title: String
    let places: [DevelopController.Place]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { develop.references = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Clear").accessibilityLabel("Clear results")
            }
            .padding(SSSpacing.xs)
            List(places.indices, id: \.self) { index in
                let place = places[index]
                Button { develop.jump(to: place.path, line: place.line, column: place.column) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.text).font(SSTypography.mono(10)).lineLimit(1)
                        Text("\(develop.editor.displayPath(URL(fileURLWithPath: place.path))):\(place.line)")
                            .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Activity strip

/// The left of the status bar: what the IDE is doing (building, testing, debugging, starting the language server) and
/// the result of the last run, like Xcode's activity viewer.
struct DevelopActivityStrip: View {
    let develop: DevelopController

    var body: some View {
        let builder = develop.builder
        HStack(spacing: 6) {
            if let activity = develop.activity {
                ProgressView().controlSize(.mini)
                Text(activity).foregroundStyle(.primary)
            } else if let status = builder.lastExitStatus {
                let noun = builder.currentKind == .build ? "Build" : builder.currentKind == .test ? "Tests" : "Run"
                Image(systemName: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status == 0 ? SSColor.success : SSColor.danger)
                Text(status == 0 ? "\(noun) succeeded" : "\(noun) failed")
                    .foregroundStyle(.primary)
                if builder.errorCount + builder.warningCount > 0 {
                    Text("· \(builder.errorCount) errors, \(builder.warningCount) warnings")
                }
            } else {
                Text("Ready")
            }
            switch develop.editor.languageServer.state {
            case .running: Text("· SourceKit").help("Language server running")
            case .failed(let reason): Text("· no language server").help(reason)
            default: EmptyView()
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rename

struct DevelopRenameForm: View {
    let develop: DevelopController
    let currentName: String
    let dismiss: () -> Void
    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("Rename “\(currentName)”").font(SSTypography.headline())
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Text("Every use in the project is renamed through the language server, and the changed files are saved.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                Button(working ? "Renaming…" : "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || name == currentName)
            }
        }
        .padding(SSSpacing.m).frame(width: 340)
        .onAppear { name = currentName }
    }

    private func commit() {
        guard !working, !name.isEmpty, name != currentName else { return }
        working = true
        Task {
            await develop.renameAtCaret(to: name)
            working = false
            dismiss()
        }
    }
}
