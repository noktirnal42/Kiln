import SwiftUI

/// Tabs beyond the function list. Each runs one existing REModule analysis and
/// lists its results; nothing is cached, so a re-run always reflects the project.
enum REFindingsTab: String, CaseIterable, Identifiable {
    case strings = "Strings"
    case crypto = "Crypto"
    case formats = "Formats"
    case gadgets = "Gadgets"

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
                ContentUnavailableView("No results", systemImage: "magnifyingglass",
                                       description: Text(emptyHint))
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.caption.monospaced()).textSelection(.enabled)
                        Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: tab) { _, _ in reset() }
        .onChange(of: projectID) { _, _ in reset() }
    }

    @ViewBuilder
    private var controls: some View {
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

    private var actionTitle: String {
        switch tab {
        case .strings: "Search"
        case .crypto: "Scan for crypto constants"
        case .formats: "Carve embedded formats"
        case .gadgets: "Find gadgets"
        }
    }

    private var emptyHint: String {
        switch tab {
        case .strings: "No extracted strings contain that text."
        case .crypto: "No known cryptographic constants were found."
        case .formats: "No embedded format signatures were found."
        case .gadgets: "No instruction sequences ending in a return were found."
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
        }
    }
}
