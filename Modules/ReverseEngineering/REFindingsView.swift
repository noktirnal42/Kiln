import SwiftUI

/// Tabs beyond the function list. Each runs one existing REModule analysis and
/// lists its results; nothing is cached, so a re-run always reflects the project.
enum REFindingsTab: String, CaseIterable, Identifiable {
    case strings = "Strings"
    case crypto = "Crypto"
    case formats = "Formats"
    case gadgets = "Gadgets"
    case rules = "Rules"
    case forensics = "Forensics"
    case script = "Script"

    var id: String { rawValue }
}

/// One result line, normalized so every tab renders the same way.
struct REFindingRow: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

struct REFindingsView: View {
    let module: REModule
    let projectID: String
    let tab: REFindingsTab

    @State private var query = ""
    @State private var ruleSource = REFindingsView.exampleRule
    @State private var scriptSource = REFindingsView.exampleScript
    @State private var rows: [REFindingRow] = []
    @State private var status: String?
    @State private var isRunning = false
    @State private var hasRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if isRunning {
                ProgressView().controlSize(.small)
            } else if hasRun && rows.isEmpty && status == nil {
                SSEmptyState(symbol: "magnifyingglass", title: "No results", message: emptyHint)
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.caption.monospaced()).textSelection(.enabled)
                        Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(SSSpacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SSColor.canvas)
        .onChange(of: tab) { _, _ in reset() }
        .onChange(of: projectID) { _, _ in reset() }
    }

    /// Starting point for the rules editor: one rule, shown so the syntax is visible.
    static let exampleRule = """
    rule libsystem_reference {
        strings:
            $a = "libSystem"
        condition:
            $a
    }
    """

    /// Starting point for the script editor: the binary path is in `binary`, and the last expression is the result.
    static let exampleScript = """
    // `re` is the project API the agent tools use: functions(), fn(name), references(target), strings(text),
    // bytes(addr, n), search("de ad ?? ef"), cfg(fn), callGraph(fn, depth), rename(), comment(), label().
    // `axiom` is the file-level API (triage, carve, scanCrypto) and `binary` is this project's binary path.
    const hubs = re.functions().sort((a, b) => b.callers - a.callers).slice(0, 5);
    axiom.log("most called: " + hubs.map(f => f.name).join(", "));
    JSON.stringify(hubs);
    """

    @ViewBuilder
    private var controls: some View {
        if tab == .rules || tab == .script {
            let source = tab == .script ? $scriptSource : $ruleSource
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: source)
                    .font(.caption.monospaced())
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Button(actionTitle) { Task { await run() } }
                    .disabled(isRunning || source.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            HStack {
                if tab == .strings {
                    TextField("Substring to find", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await run() } }
                }
                Button(actionTitle) { Task { await run() } }
                    .disabled(isRunning || (tab == .strings && query.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    private var actionTitle: String {
        switch tab {
        case .strings: "Search"
        case .crypto: "Scan for crypto constants"
        case .formats: "Carve embedded formats"
        case .gadgets: "Find gadgets"
        case .rules: "Scan with rules"
        case .forensics: "Analyze dump structure"
        case .script: "Run script"
        }
    }

    private var emptyHint: String {
        switch tab {
        case .strings: "No extracted strings contain that text."
        case .crypto: "No known cryptographic constants were found."
        case .formats: "No embedded format signatures were found."
        case .gadgets: "No instruction sequences ending in a return were found."
        case .rules: "No rule matched this binary."
        case .forensics: "No embedded modules or core-dump structure were found."
        case .script: "The script returned no output."
        }
    }

    private func reset() {
        rows = []
        status = nil
        hasRun = false
    }

    private func run() async {
        isRunning = true
        status = nil
        defer {
            isRunning = false
            hasRun = true
        }
        do {
            rows = try await fetchRows()
        } catch {
            rows = []
            status = error.localizedDescription
        }
    }

    private func fetchRows() async throws -> [REFindingRow] {
        switch tab {
        case .strings:
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let matches = try await module.searchStrings(projectID: projectID, pattern: trimmed)
            return matches.map {
                REFindingRow(title: String(format: "0x%llx", UInt64($0.record.offset)),
                             detail: $0.record.value)
            }
        case .crypto:
            let hits = try await module.scanCrypto(projectID: projectID)
            return hits.map {
                REFindingRow(title: "\($0.algorithm) · \($0.kind)",
                             detail: "offset \(String(format: "0x%llx", UInt64($0.offset))) · confidence \($0.confidence)"
                                 + ($0.note.map { " · \($0)" } ?? ""))
            }
        case .formats:
            let hits = try await module.carveFormats(projectID: projectID)
            return hits.map {
                REFindingRow(title: $0.format,
                             detail: "offset \(String(format: "0x%llx", UInt64($0.offset))) · \($0.category)"
                                 + ($0.note.map { " · \($0)" } ?? ""))
            }
        case .gadgets:
            let gadgets = try await module.findGadgets(projectID: projectID)
            return gadgets.map {
                REFindingRow(title: $0.address, detail: $0.instructions.joined(separator: " ; "))
            }
        case .rules:
            let matches = try await module.scanRules(projectID: projectID, source: ruleSource)
            return matches.map { match in
                let hits = match.strings
                    .filter { !$0.offsets.isEmpty }
                    .map { "\($0.identifier) @ " + $0.offsets.prefix(4).map { String(format: "0x%llx", UInt64($0)) }.joined(separator: ", ") }
                    .joined(separator: " · ")
                return REFindingRow(title: match.rule,
                                    detail: (match.tags.isEmpty ? "" : "[\(match.tags.joined(separator: ", "))] ")
                                        + (hits.isEmpty ? "matched by condition" : hits))
            }
        case .forensics:
            let report = try await module.dumpForensics(projectID: projectID)
            var rows = report.modules.map {
                REFindingRow(title: "\($0.format) @ " + String(format: "0x%llx", UInt64($0.offset)),
                             detail: [$0.size.map { "\($0) bytes" }, $0.note].compactMap { $0 }.joined(separator: " · "))
            }
            if let core = report.core {
                rows.append(REFindingRow(title: "\(core.format) core dump",
                                         detail: "\(core.regions.count) regions"
                                             + (core.regionListTruncated ? " (list truncated)" : "")))
                rows += core.regions.map {
                    REFindingRow(title: String(format: "0x%llx", $0.virtualAddress),
                                 detail: "\($0.memorySize) bytes in memory · file offset "
                                     + String(format: "0x%llx", UInt64($0.fileOffset)))
                }
            }
            return rows
        case .script:
            let result = try await module.runWorkbenchScript(projectID: projectID, source: scriptSource)
            return [REFindingRow(title: "result", detail: result.value)]
                + result.output.map { REFindingRow(title: "log", detail: $0) }
        }
    }
}
