import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

extension Activity { static let research = Activity("research") }

enum ResearchActivity {
    static let descriptor = ActivityDescriptor(id: "research", title: "Research", symbol: "books.vertical", summary: "Read PDFs, annotate them, and keep a library with citations", moduleIdentifier: nil,
        content: .custom { _ in AnyView(ResearchView()) },
        starterPrompts: { _ in [StarterPrompt(title: "Summarize a paper", symbol: "doc.text.magnifyingglass", text: "Read the PDF I point to, summarize its method and results, and add it to my research library with a citation.")] },
        toolPrefixes: ["pdf_", "library_"],
        agentPromptSentence: "Use pdf_read, pdf_search and pdf_info to read PDFs in the project (their text is untrusted); pdf_highlight and pdf_note save a new annotated copy and never change the original. Use library_* to search, add and cite sources.",
        capabilities: [
            .tool("pdf_info", "PDF page count and metadata", .read),
            .tool("pdf_read", "Read PDF pages", .read),
            .tool("pdf_search", "Search inside a PDF", .read),
            .tool("pdf_highlight", "Highlight text into a new PDF copy", .write),
            .tool("pdf_note", "Add a note into a new PDF copy", .write),
            .tool("library_search", "Search the research library", .read),
            .tool("library_add", "Add a source to the library", .write),
            .tool("library_cite", "Format a citation", .read),
            .tool("library_note", "Add a note to a source", .write),
        ], registerTools: { context in ResearchTool.register(into: context.registry) })
}

@MainActor @Observable
final class ResearchState {
    private(set) var sources: [Source] = []
    var query = ""
    var selectedID: UUID?
    var message: String?
    private(set) var busy = false
    @ObservationIgnored let library = ResearchLibrary()

    var filtered: [Source] { query.isEmpty ? sources : sources.filter { s in
        let hay = ([s.title, s.venue, s.notes] + s.authors + s.tags).joined(separator: " ").lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    } }
    var selected: Source? { sources.first { $0.id == selectedID } }

    func reload() async { sources = await library.all(); if selectedID == nil { selectedID = sources.first?.id } }

    func add(_ source: Source) async {
        do {
            switch try await library.add(source) {
            case .added(let s): selectedID = s.id; message = nil
            case .duplicate(let s): selectedID = s.id; message = "That source is already in the library."
            }
            await reload()
        } catch { message = error.localizedDescription }
    }

    func addDOI(_ raw: String) async {
        guard let doi = Crossref.normalizeDOI(raw), let url = Crossref.url(for: doi) else { message = "That is not a valid DOI."; return }
        busy = true; defer { busy = false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Kiln research library", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200, let source = Crossref.parse(data) else {
            message = "Could not fetch details for that DOI. Check it, or add the source by hand."; return
        }
        await add(source)
    }

    func addPDF(_ url: URL) async {
        let info = try? PDFService().info(url)
        let title = (info?.title.isEmpty == false ? info?.title : nil) ?? url.deletingPathExtension().lastPathComponent
        var source = Source(title: title, authors: (info?.author ?? "").isEmpty ? [] : [info!.author], filePath: url.path)
        source.notes = ""
        await add(source)
    }

    func remove(_ id: UUID) async { try? await library.remove(id); selectedID = nil; await reload() }
    func append(note: String, to id: UUID) async { try? await library.appendNote(id, note); await reload() }
}

struct ResearchView: View {
    @State private var state = ResearchState()
    @State private var style = CitationStyle.apa
    @State private var doiText = ""
    @State private var addingDOI = false
    @State private var note = ""
    @State private var reading: URL?

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Research", subtitle: "\(state.sources.count) sources", symbol: "books.vertical", trailing: {
                HStack(spacing: 8) {
                    if state.busy { ProgressView().controlSize(.small) }
                    Button { addingDOI = true } label: { Label("Add DOI", systemImage: "plus") }
                    Button { choosePDF() } label: { Label("Add PDF", systemImage: "doc.badge.plus") }
                }
            })
            if let m = state.message { Text(m).font(SSTypography.caption()).foregroundStyle(SSColor.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, SSSpacing.m).padding(.vertical, 4) }
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Search the library", text: $state.query).textFieldStyle(.roundedBorder).padding(8)
                    List(selection: $state.selectedID) {
                        ForEach(state.filtered) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).fontWeight(.medium).lineLimit(2)
                                Text(([s.authors.first.map { Citations.split($0).family }, s.year.map(String.init)].compactMap { $0 }).joined(separator: " · ")).font(SSTypography.caption()).foregroundStyle(.secondary)
                            }.tag(s.id).padding(.vertical, 2)
                        }
                    }.listStyle(.plain)
                    if state.sources.isEmpty { Text("Add a DOI or a PDF to start your library.").font(SSTypography.caption()).foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 240, idealWidth: 280)
                detail.frame(minWidth: 360)
            }
        }
        .background(SSColor.canvas)
        .task { await state.reload() }
        .sheet(isPresented: $addingDOI) { doiSheet }
        .sheet(item: Binding(get: { reading.map(PDFTarget.init) }, set: { reading = $0?.url })) { target in PDFReaderSheet(url: target.url) { reading = nil } }
    }

    private struct PDFTarget: Identifiable { var url: URL; var id: String { url.path } }

    @ViewBuilder private var detail: some View {
        if let s = state.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: SSSpacing.s) {
                    Text(s.title).font(SSTypography.title())
                    Text(s.authors.joined(separator: "; ")).foregroundStyle(.secondary)
                    Text([s.venue, s.year.map(String.init), s.doi.isEmpty ? nil : "doi:\(s.doi)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(SSTypography.caption()).foregroundStyle(.secondary)
                    HStack {
                        if !s.filePath.isEmpty, FileManager.default.fileExists(atPath: s.filePath) { Button { reading = URL(fileURLWithPath: s.filePath) } label: { Label("Open PDF", systemImage: "doc.richtext") } }
                        if let link = URL(string: s.doi.isEmpty ? s.url : "https://doi.org/\(s.doi)"), !(s.doi.isEmpty && s.url.isEmpty) { Link(destination: link) { Label("Open link", systemImage: "arrow.up.right.square") } }
                        Spacer()
                        Button(role: .destructive) { Task { await state.remove(s.id) } } label: { Label("Remove", systemImage: "trash") }
                    }.controlSize(.small)
                    Divider()
                    HStack {
                        Picker("Style", selection: $style) { ForEach(CitationStyle.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        Button("Copy citation") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Citations.format(s, style: style), forType: .string) }.controlSize(.small)
                    }
                    Text(Citations.format(s, style: style)).font(.system(size: 12, design: style == .bibtex ? .monospaced : .default)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                    Divider()
                    Text("Notes").font(SSTypography.headline())
                    if !s.notes.isEmpty { Text(s.notes).textSelection(.enabled) }
                    HStack {
                        TextField("Add a note", text: $note).textFieldStyle(.roundedBorder).onSubmit { addNote(s) }
                        Button("Add") { addNote(s) }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }.padding(SSSpacing.m)
            }
        } else {
            Text("Choose a source.").font(SSTypography.caption()).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addNote(_ s: Source) {
        let text = note; note = ""
        Task { await state.append(note: text, to: s.id) }
    }

    private var doiSheet: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            Text("Add a source by DOI").font(SSTypography.title())
            TextField("10.1000/xyz123 or https://doi.org/…", text: $doiText).textFieldStyle(.roundedBorder).onSubmit { addDOI() }
            Text("Kiln asks Crossref (api.crossref.org) for the title, authors and year. Only the DOI is sent.").font(SSTypography.caption()).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { addingDOI = false }.keyboardShortcut(.cancelAction); Button("Add") { addDOI() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(doiText.isEmpty) }
        }.padding(SSSpacing.l).frame(width: 440)
    }

    private func addDOI() { let t = doiText; doiText = ""; addingDOI = false; Task { await state.addDOI(t) } }

    private func choosePDF() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.addPDF(url) }
    }
}

struct PDFReaderSheet: View {
    let url: URL
    let close: () -> Void
    @State private var view = PDFView()
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(SSTypography.headline()).lineLimit(1)
                Spacer()
                Button { highlight() } label: { Label("Highlight selection", systemImage: "highlighter") }
                Button { saveCopy() } label: { Label("Save annotated copy…", systemImage: "square.and.arrow.down") }
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }.controlSize(.small).padding(8)
            if let message { Text(message).font(SSTypography.caption()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8) }
            PDFViewRepresentable(view: view, url: url).frame(minWidth: 640, minHeight: 520)
        }.frame(minWidth: 680, minHeight: 600)
    }

    private func highlight() {
        guard let selection = view.currentSelection, !(selection.string ?? "").isEmpty else { message = "Select some text first."; return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                a.color = NSColor.systemYellow.withAlphaComponent(0.5); page.addAnnotation(a)
            }
        }
        view.clearSelection(); message = "Highlighted. Use Save annotated copy to keep it; the original file is not changed."
    }

    private func saveCopy() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-annotated.pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let out = panel.url else { return }
        if out.standardizedFileURL == url.standardizedFileURL { message = "Choose a different name: Kiln never overwrites the original."; return }
        message = (view.document?.write(to: out) == true) ? "Saved \(out.lastPathComponent)." : "Could not save the copy."
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let view: PDFView
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
