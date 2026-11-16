import SwiftUI
import AppKit
import AxiomCore

// MARK: References

/// Everything that refers to one address, function or string; also where an address gets a comment, label or bookmark.
struct REReferencesSheet: View {
    let module: REModule
    let projectID: String
    let target: String
    let onGo: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [REReference] = []
    @State private var comment = ""
    @State private var label = ""
    @State private var status: String?
    @State private var bookmarked = false

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(SSColor.accent)
                Text("References to").font(SSTypography.headline())
                Text(target).font(SSTypography.mono(13)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if REListing.address(target) != nil {
                HStack {
                    TextField("Comment", text: $comment).textFieldStyle(.roundedBorder)
                    TextField("Label", text: $label).textFieldStyle(.roundedBorder).frame(width: 140)
                    Button("Save") { Task { await save() } }.disabled(comment.isEmpty && label.isEmpty)
                    Button { toggleBookmark() } label: { Image(systemName: bookmarked ? "bookmark.fill" : "bookmark") }.help("Bookmark this address")
                }.controlSize(.small)
            }
            if let status { Text(status).font(SSTypography.caption()).foregroundStyle(.secondary) }
            if rows.isEmpty { SSEmptyState(symbol: "arrow.triangle.branch", title: "No references found", message: "Nothing in the analysed listings refers to this.") }
            else {
                List(rows) { row in
                    Button { if let f = row.fromFunctionAddress { onGo(f); dismiss() } } label: {
                        HStack(spacing: SSSpacing.s) {
                            SSBadge(text: row.kind.rawValue)
                            Text("0x" + REListing.hex(row.from)).font(SSTypography.mono(11)).foregroundStyle(SSColor.accent)
                            Text(row.fromFunction ?? "").font(SSTypography.mono(11)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(row.context).font(SSTypography.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }
        .padding(SSSpacing.m).frame(width: 640, height: 420)
        .task { await load() }
    }

    private func load() async {
        do {
            rows = try await module.references(projectID: projectID, target: target)
            if let w = try? module.workspace(projectID: projectID) { bookmarked = w.bookmarks.contains { $0.address == ProjectStore.normalizedAddress(target) } }
            let analysis = try await module.analysis(projectID: projectID)
            let key = ProjectStore.normalizedAddress(target)
            comment = analysis.addressComments?[key] ?? ""; label = analysis.addressLabels?[key] ?? ""
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        do {
            let revision = try await module.analysis(projectID: projectID).revision
            _ = try await module.editProject(projectID: projectID, expectedRevision: revision, operations: [.addressNote(address: target, comment: comment, label: label)])
            status = "Saved. Undo from the Annotate popover."
        } catch { status = error.localizedDescription }
    }
    private func toggleBookmark() { do { bookmarked = try module.toggleAddressBookmark(projectID: projectID, address: target) } catch { status = error.localizedDescription } }
}

// MARK: Hex

struct REHexView: View {
    let module: REModule
    let projectID: String
    let function: FunctionRecord?
    @State private var rows: [REHexRow] = []
    @State private var start: UInt64 = 0
    @State private var goText = ""
    @State private var searchText = ""
    @State private var hits: [UInt64] = []
    @State private var status: String?
    private let page = 1024

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: "Hex") {
                Button { move(-page) } label: { Label("Previous", systemImage: "chevron.up") }
                Button { move(page) } label: { Label("Next", systemImage: "chevron.down") }
            }
            HStack(spacing: SSSpacing.s) {
                TextField("Go to address (0x…) or offset (o:0x…)", text: $goText).textFieldStyle(.roundedBorder).onSubmit { Task { await go() } }
                TextField("Search: de ad ?? ef  or  \"text\"", text: $searchText).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
            }.controlSize(.small).padding(SSSpacing.s)
            if let status { Text(status).font(SSTypography.caption()).foregroundStyle(.secondary).padding(.horizontal, SSSpacing.m) }
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            Text("\(String(format: "%08llx", row.offset))  \(row.address.map { String(format: "%010llx", $0) } ?? "          ")  \(row.hex.padding(toLength: 47, withPad: " ", startingAt: 0))  \(row.ascii)")
                                .font(SSTypography.mono(11)).textSelection(.enabled)
                        }
                    }.padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading)
                }.background(SSColor.canvas)
                if !hits.isEmpty {
                    Divider()
                    List(hits, id: \.self) { hit in
                        Button(String(format: "0x%llx", hit)) { start = hit & ~0xf; Task { await load() } }.buttonStyle(.link).font(SSTypography.mono(11))
                    }.listStyle(.plain).frame(width: 130)
                }
            }
        }
        .task(id: function?.address) {
            if let function, let a = REListing.address(function.address) { goText = "0x" + REListing.hex(a); await go() } else { await load() }
        }
    }

    private func move(_ delta: Int) { start = delta < 0 ? (start >= UInt64(-delta) ? start - UInt64(-delta) : 0) : start + UInt64(delta); Task { await load() } }

    private func go() async {
        let text = goText.trimmingCharacters(in: .whitespaces)
        do {
            if text.hasPrefix("o:") { start = REListing.address(String(text.dropFirst(2))) ?? 0 }
            else if let address = REListing.address(text), let offset = try await module.addressMap(projectID: projectID).fileOffset(forAddress: address) { start = offset & ~0xf }
            else if !text.isEmpty { status = "That address is not backed by file contents."; return }
            await load()
        } catch { status = error.localizedDescription }
    }
    private func load() async {
        do { rows = try await module.readHex(projectID: projectID, offset: start, length: page); status = nil }
        catch { status = error.localizedDescription }
    }
    private func search() async {
        do {
            hits = try await module.searchBytes(projectID: projectID, pattern: searchText)
            status = hits.isEmpty ? "No matches." : "\(hits.count) match(es); click one to jump."
        } catch { status = error.localizedDescription }
    }
}

// MARK: Types

struct RETypesView: View {
    let module: REModule
    let projectID: String
    @State private var structures: [REStructure] = []
    @State private var selected: String?
    @State private var source = "struct Example {\n    uint32_t magic;\n    uint16_t version;\n    char name[16];\n    void *next;\n};"
    @State private var status: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SSPaneHeader(title: "Types", count: structures.count) {
                    Button { if (try? module.undoStructures(projectID: projectID)) == true { reload() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    Button { if (try? module.redoStructures(projectID: projectID)) == true { reload() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                }
                List(structures, selection: $selected) { s in
                    Text(s.name).font(SSTypography.mono(11)).tag(s.name).contextMenu { Button("Delete", role: .destructive) { try? module.deleteStructure(projectID: projectID, name: s.name); reload() } }
                }.listStyle(.plain)
            }.frame(width: 180).background(SSColor.surface)
            Divider()
            VStack(spacing: 0) {
                SSPaneHeader("Definition")
                TextEditor(text: $source).font(SSTypography.mono(11.5)).frame(height: 150).scrollContentBackground(.hidden).background(SSColor.canvas)
                HStack {
                    Button("Define") { define() }.buttonStyle(.borderedProminent).tint(SSColor.accent)
                    Text("Apply to a variable from the function's Annotate popover or `re_apply_structure`.").font(SSTypography.caption()).foregroundStyle(.secondary)
                    Spacer()
                }.padding(SSSpacing.s)
                if let status { Text(status).font(SSTypography.caption()).foregroundStyle(status.hasPrefix("Defined") ? Color.secondary : SSColor.danger).padding(.horizontal, SSSpacing.m) }
                if let s = structures.first(where: { $0.name == selected }) {
                    SSPaneHeader("\(s.isUnion ? "union" : "struct") \(s.name) · \(s.size) bytes · align \(s.alignment)")
                    List(s.fields) { f in
                        HStack { Text(String(format: "+0x%x", f.offset)).font(SSTypography.mono(11)).foregroundStyle(SSColor.accent).frame(width: 60, alignment: .leading)
                            Text("\(f.size)").font(SSTypography.mono(11)).frame(width: 40, alignment: .trailing)
                            Text(f.type).font(SSTypography.mono(11)); Text(f.name).font(SSTypography.mono(11).weight(.semibold)) }
                    }.listStyle(.plain)
                } else { Spacer() }
            }
        }
        .task(id: projectID) { reload() }
    }
    private func reload() { structures = (try? module.workspace(projectID: projectID).structures) ?? [] }
    private func define() {
        do { let list = try module.defineStructures(projectID: projectID, source: source); status = "Defined \(list.map(\.name).joined(separator: ", "))"; reload(); selected = list.last?.name }
        catch { status = error.localizedDescription }
    }
}

// MARK: Patches

struct REPatchView: View {
    let module: REModule
    let projectID: String
    let function: FunctionRecord?
    @State private var address = ""
    @State private var mode = 0
    @State private var input = "nop"
    @State private var note = ""
    @State private var patches: [REPatch] = []
    @State private var status: String?
    @State private var exported: String?

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: "Patches", count: patches.count) {
                Button { Task { await export() } } label: { Label("Export patched copy", systemImage: "square.and.arrow.up") }.disabled(patches.isEmpty)
            }
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                HStack {
                    TextField("Address", text: $address).textFieldStyle(.roundedBorder).frame(width: 120)
                    Picker("", selection: $mode) { Text("Assembly").tag(0); Text("Hex bytes").tag(1); Text("NOP bytes").tag(2) }.pickerStyle(.segmented).fixedSize().labelsHidden().accessibilityLabel("Patch input kind")
                    TextField(mode == 0 ? "e.g. mov w0, #0" : mode == 1 ? "1f 20 03 d5" : "4", text: $input).textFieldStyle(.roundedBorder)
                    TextField("Note", text: $note).textFieldStyle(.roundedBorder).frame(minWidth: 70, maxWidth: 160)
                    Button("Add") { Task { await add() } }.buttonStyle(.borderedProminent).tint(SSColor.accent).fixedSize()
                }.controlSize(.small)
                Text("Patches are recorded here and written only to a copy. The original binary is never modified, and the copy is not re-signed or run.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
                if let status { Text(status).font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
                if let exported { Text(exported).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(SSSpacing.m)
            List(patches) { p in
                HStack {
                    Text("0x" + p.address).font(SSTypography.mono(11)).foregroundStyle(SSColor.accent)
                    Text("\(p.original) → \(p.bytes)").font(SSTypography.mono(11))
                    if let a = p.assembly { Text(a).font(SSTypography.mono(11)).foregroundStyle(.secondary) }
                    Text(p.note).font(SSTypography.caption()).foregroundStyle(.secondary)
                    Spacer()
                    if p.applied { SSBadge(text: "exported", tint: SSColor.success) }
                    Button { try? module.removePatch(projectID: projectID, id: p.id); reload() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        .help("Remove this patch").accessibilityLabel("Remove patch at 0x\(p.address)")
                }
            }.listStyle(.plain)
        }
        .task(id: function?.address) { if address.isEmpty || function != nil { address = function.map { "0x" + ProjectStore.normalizedAddress($0.address) } ?? address }; reload() }
    }
    private func reload() { patches = (try? module.workspace(projectID: projectID).patches) ?? [] }
    private func add() async {
        do {
            switch mode {
            case 0: _ = try await module.createPatch(projectID: projectID, address: address, assembly: input, note: note)
            case 1: _ = try await module.createPatch(projectID: projectID, address: address, hex: input, note: note)
            default: _ = try await module.createPatch(projectID: projectID, address: address, nopLength: Int(input), note: note)
            }
            status = nil; reload()
        } catch { status = error.localizedDescription }
    }
    private func export() async {
        do { let r = try await module.exportPatched(projectID: projectID); exported = "Wrote \(r.url.path)  sha256 \(r.sha256)"; status = nil; reload()
            NSWorkspace.shared.activateFileViewerSelecting([r.url]) } catch { status = error.localizedDescription }
    }
}

// MARK: Diff

struct REDiffView: View {
    let module: REModule
    let project: REModule.REProject
    @State private var otherID: String?
    @State private var result: REDiffResult?
    @State private var detail: [String] = []
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader("Binary diff")
            HStack {
                Text("Compare with").font(SSTypography.caption()).foregroundStyle(.secondary)
                Picker("", selection: $otherID) {
                    Text("Choose a project").tag(String?.none)
                    ForEach(module.projects.filter { $0.id != project.id }) { Text($0.binaryURL.lastPathComponent).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 260)
                Button(busy ? "Comparing…" : "Compare") { Task { await compare() } }.disabled(otherID == nil || busy).buttonStyle(.borderedProminent).tint(SSColor.accent)
                if let result { Text("\(result.unchanged) unchanged · \(result.changed.count) changed · \(result.added.count) added · \(result.removed.count) removed").font(SSTypography.caption()).foregroundStyle(.secondary) }
                Spacer()
            }.padding(SSSpacing.s).controlSize(.small)
            if let status { Text(status).font(SSTypography.caption()).foregroundStyle(SSColor.danger).padding(.horizontal, SSSpacing.m) }
            if let result {
                HStack(spacing: 0) {
                    List((result.changed + result.added + result.removed)) { m in
                        Button { Task { await show(m) } } label: {
                            HStack { SSBadge(text: m.status.rawValue, tint: m.status == .changed ? SSColor.warning : m.status == .added ? SSColor.success : SSColor.danger)
                                Text(m.nameA ?? m.nameB ?? "?").font(SSTypography.mono(11)).lineLimit(1); Spacer()
                                if m.status == .changed { Text(String(format: "%.0f%%", m.similarity * 100)).font(SSTypography.caption()).foregroundStyle(.secondary) } }
                        }.buttonStyle(.plain)
                    }.listStyle(.plain).frame(width: 300)
                    Divider()
                    if detail.isEmpty { SSEmptyState(symbol: "arrow.left.arrow.right", title: "Select a changed function", message: "The listing diff shows only real instruction changes; addresses are masked.") }
                    else { SSCodeBlock(text: detail.joined(separator: "\n")) }
                }
            } else { SSEmptyState(symbol: "arrow.left.arrow.right", title: "Diff two projects", message: "Import both builds (or a patched copy) as projects, then compare them here.") }
        }
    }
    private func compare() async {
        guard let otherID else { return }
        busy = true; defer { busy = false }
        do { result = try await module.diff(projectA: project.id, projectB: otherID); status = nil; detail = [] } catch { status = error.localizedDescription }
    }
    private func show(_ m: REDiffResult.Match) async {
        guard let otherID, let a = m.a, let b = m.b, let x = try? await module.analysis(projectID: project.id), let y = try? await module.analysis(projectID: otherID),
              let f = x.functions.first(where: { $0.address == a }), let g = y.functions.first(where: { $0.address == b }) else { detail = []; return }
        detail = REDiff.listingDiff(f, g)
    }
}

// MARK: Package

struct REPackageView: View {
    let module: REModule
    let onFindFunction: (String) -> Void
    @State private var archive: URL?
    @State private var report: REPackageReport?
    @State private var status: String?
    @State private var classQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: archive?.lastPathComponent ?? "Package") {
                Button { choose() } label: { Label("Open IPA or APK", systemImage: "shippingbox") }
            }
            if let status { Text(status).font(SSTypography.caption()).foregroundStyle(SSColor.danger).padding(SSSpacing.s) }
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: SSSpacing.m) {
                        HStack { SSBadge(text: report.kind.rawValue.uppercased()); Text([report.appName, report.identifier, report.version].compactMap { $0 }.joined(separator: " · ")).font(SSTypography.headline()) }
                        ForEach(report.warnings, id: \.self) { Text($0).font(SSTypography.caption()).foregroundStyle(SSColor.warning) }
                        if let exe = report.executable {
                            HStack { Text("Main file").font(SSTypography.caption()).foregroundStyle(.secondary); Text(exe).font(SSTypography.mono(11))
                                Button("Import for analysis") { Task { await importEntry(exe) } }.controlSize(.small) }
                        }
                        section("Properties", report.properties.map { "\($0.key) = \($0.value)" })
                        section("Entitlements", report.entitlements.map { "\($0.key) = \($0.value)" })
                        section("Permissions", report.permissions)
                        section("Components", report.components.map { "\($0.kind): \($0.name)" })
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { SSSectionLabel("Classes (\(report.classes.count)) · \(report.methodCount) methods"); TextField("Filter", text: $classQuery).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 180) }
                            ForEach(report.classes.filter { classQuery.isEmpty || $0.localizedCaseInsensitiveContains(classQuery) }.prefix(200), id: \.self) { name in
                                Button(name) { onFindFunction(name) }.buttonStyle(.link).font(SSTypography.mono(11)).help("Find in the Functions tab")
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            SSSectionLabel("Libraries (\(report.libraries.count))")
                            ForEach(report.libraries, id: \.self) { lib in
                                HStack { Text(lib).font(SSTypography.mono(11)); if lib.hasSuffix(".so") { Button("Import") { Task { await importEntry(lib) } }.controlSize(.mini) } }
                            }
                        }
                        section("Resources (\(report.resources.count))", Array(report.resources.prefix(300)))
                    }.padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { SSEmptyState(symbol: "shippingbox", title: "No package open", message: "Open an IPA or APK (or download one from Projects) to see its manifest, entitlements, classes and resources. Nothing is run.") }
        }
    }
    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !lines.isEmpty { SSSectionLabel(title.contains("(") ? title : "\(title) (\(lines.count))") }
            ForEach(lines.prefix(300), id: \.self) { Text($0).font(SSTypography.mono(11)).textSelection(.enabled) }
        }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.item]; panel.message = "Choose an IPA or APK"
        panel.directoryURL = KilnPackageCatalog.defaultDownloadsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archive = url
        Task { do { report = try await module.inspectPackage(at: url); status = nil } catch { status = error.localizedDescription; report = nil } }
    }
    private func importEntry(_ entry: String) async {
        guard let archive else { return }
        do { _ = try await module.importPackageEntry(archive: archive, entry: entry); status = nil } catch { status = error.localizedDescription }
    }
}

// MARK: Findings

struct REFindingsPane: View {
    let module: REModule
    let projectID: String
    let function: FunctionRecord?
    @State private var findings: [REFinding] = []
    @State private var title = ""
    @State private var summary = ""
    @State private var severity: REFinding.Severity = .medium
    @State private var evidence = ""
    @State private var attachment: String?
    @State private var status: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                SSSectionLabel("New finding")
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Picker("Severity", selection: $severity) { ForEach(REFinding.Severity.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                TextEditor(text: $summary).font(.body).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(SSColor.hairline))
                TextEditor(text: $evidence).font(SSTypography.mono(11)).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 6).stroke(SSColor.hairline))
                    .overlay(alignment: .topLeading) { if evidence.isEmpty { Text("Evidence (listing lines, strings)").font(SSTypography.caption()).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
                if let function { Text("Linked to \(function.name) @ 0x\(ProjectStore.normalizedAddress(function.address))").font(SSTypography.caption()).foregroundStyle(.secondary) }
                HStack {
                    Button { attach() } label: { Label(attachment ?? "Attach screenshot", systemImage: "photo") }.controlSize(.small)
                    Spacer()
                    Button("Add") { add() }.buttonStyle(.borderedProminent).tint(SSColor.accent).disabled(title.isEmpty || summary.isEmpty)
                }
                if let status { Text(status).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
            }.padding(SSSpacing.m).frame(width: 300).background(SSColor.surface)
            Divider()
            VStack(spacing: 0) {
                SSPaneHeader(title: "Findings", count: findings.count) {
                    Button { Task { await exportReport() } } label: { Label("Export report", systemImage: "doc.richtext") }
                }
                if findings.isEmpty { SSEmptyState(symbol: "flag", title: "No findings yet", message: "Record what you found with its evidence, then export a Markdown and HTML report.") }
                else {
                    List(findings) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { SSBadge(text: f.severity.rawValue, tint: f.severity == .critical || f.severity == .high ? SSColor.danger : f.severity == .medium ? SSColor.warning : .secondary)
                                Text(f.title).font(ThemeRuntime.font(12.5, .semibold)); if f.source != "analyst" { SSBadge(text: f.source) }; Spacer()
                                Button { try? module.removeFinding(projectID: projectID, id: f.id); reload() } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                            Text(f.summary).font(SSTypography.caption()).foregroundStyle(.secondary)
                            if let a = f.address ?? f.function { Text(a).font(SSTypography.mono(10.5)).foregroundStyle(SSColor.accent) }
                        }
                    }.listStyle(.plain)
                }
            }
        }
        .task(id: projectID) { reload() }
    }
    private func reload() { findings = (try? module.workspace(projectID: projectID).findings) ?? [] }
    private func add() {
        var f = REFinding(title: title, severity: severity, summary: summary)
        f.function = function?.name; f.address = function.map { "0x" + ProjectStore.normalizedAddress($0.address) }
        f.evidence = evidence.split(separator: "\n").map(String.init); f.attachments = attachment.map { [$0] } ?? []
        do { try module.addFinding(projectID: projectID, finding: f); title = ""; summary = ""; evidence = ""; attachment = nil; status = nil; reload() } catch { status = error.localizedDescription }
    }
    private func attach() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { attachment = try module.addAttachment(projectID: projectID, from: url) } catch { status = error.localizedDescription }
    }
    private func exportReport() async {
        do { let r = try await module.exportReport(projectID: projectID); status = "Report written to \(r.folder.path)"; NSWorkspace.shared.activateFileViewerSelecting([r.html]) }
        catch { status = error.localizedDescription }
    }
}

// MARK: Debugger

struct REDebugView: View {
    let module: REModule
    let projectID: String
    let function: FunctionRecord?
    @State private var addresses = ""
    @State private var mode: REDebugPlan.Mode = .inspect
    @State private var plan: REDebugPlan?
    @State private var output = ""
    @State private var status: String?
    @State private var confirmLaunch = false

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader("Debugger (lldb)")
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                HStack {
                    TextField("Breakpoint addresses, comma separated", text: $addresses).textFieldStyle(.roundedBorder)
                    Picker("", selection: $mode) { Text("Load only").tag(REDebugPlan.Mode.inspect); Text("Launch").tag(REDebugPlan.Mode.launch) }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
                    Button("Plan") { Task { await makePlan() } }
                    Button("Run in lldb") { if mode == .launch { confirmLaunch = true } else { Task { await run() } } }.buttonStyle(.borderedProminent).tint(SSColor.accent).disabled(plan == nil)
                }.controlSize(.small)
                Text("Load only resolves breakpoints without running anything. Launch runs the program on this Mac under lldb, stopped at its entry point and killed at the end, and asks first.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
                if let status { Text(status).font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
            }.padding(SSSpacing.m)
            if let plan { SSPaneHeader("Commands"); SSCodeBlock(text: plan.script).frame(height: 130) }
            SSPaneHeader("Output")
            SSCodeBlock(text: output.isEmpty ? "No output yet." : output)
        }
        .task(id: function?.address) { if let function { addresses = "0x" + ProjectStore.normalizedAddress(function.address); await makePlan() } }
        .confirmationDialog("Run the program under lldb?", isPresented: $confirmLaunch) {
            Button("Launch and stop at entry") { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This executes the analysed binary on this Mac. Only do this for software you are authorised to analyse.") }
    }
    private func makePlan() async {
        do { plan = try await module.debugPlan(projectID: projectID, mode: mode, addresses: addresses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }); status = nil }
        catch { status = error.localizedDescription }
    }
    private func run() async {
        await makePlan()
        guard let plan else { return }
        do { output = try await module.runDebugPlan(plan); status = nil } catch { status = error.localizedDescription }
    }
}
