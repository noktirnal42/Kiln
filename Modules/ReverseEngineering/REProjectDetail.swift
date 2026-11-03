import SwiftUI
import AxiomCore

/// One analyzed binary. The Functions tab is two columns: function list on the
/// left, the selected function's assembly and decompilation on the right. The
/// other tabs run analyses over the whole binary (see `REFindingsView`).
struct REProjectDetail: View {
    let module: REModule
    let project: REModule.REProject
    let analysis: Analysis

    @State private var selectedAddress: String?
    @State private var tab: REFindingsTab?
    @State private var analysisError: String?

    private var selectedFunction: FunctionRecord? {
        guard let selectedAddress else { return nil }
        return analysis.functions.first { $0.address == selectedAddress }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(module.ghidraStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if module.isGhidraAnalysisRunning { ProgressView().controlSize(.small) }
                Button("Analyze with Ghidra", systemImage: "bolt") {
                    Task {
                        do { _ = try await module.analyzeWithGhidra(projectID: project.id) }
                        catch { analysisError = error.localizedDescription }
                    }
                }
                .disabled(!module.isGhidraAvailable || module.isGhidraAnalysisRunning)
                .help("Recover functions, pseudocode and references. Runs the analysis engine without executing this binary.")
                Button("radare2", systemImage: "hare") {
                    Task {
                        do { _ = try await module.analyzeWithRadare2(projectID: project.id) }
                        catch { analysisError = error.localizedDescription }
                    }
                }
                .disabled(!module.isRadare2Available || module.isGhidraAnalysisRunning)
                .help("Fast function, call-graph and basic-block recovery without a decompiler. Install with brew install radare2.")
            }
            .padding(8)
            Divider()
            ScrollView(.horizontal) {
                Picker("View", selection: $tab) {
                    Text("Functions").tag(REFindingsTab?.none)
                    ForEach(REFindingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(REFindingsTab?.some(tab))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(8)
            }
            .scrollIndicators(.visible)
            Divider()
            if let tab {
                REFindingsView(module: module, projectID: project.id, tab: tab)
            } else {
                functionsBody
            }
        }
        .alert("Ghidra analysis failed", isPresented: Binding(get: { analysisError != nil }, set: { if !$0 { analysisError = nil } })) {
            Button("OK") { analysisError = nil }
        } message: { Text(analysisError ?? "") }
    }

    private var functionsBody: some View {
        HStack(spacing: 0) {
            List(selection: $selectedAddress) {
                Section("Functions (\(analysis.functions.count))") {
                    ForEach(analysis.functions) { function in
                        Text(function.name)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .tag(function.address)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 260)
            Divider()
            Group {
                if let function = selectedFunction {
                    REFunctionDetail(module: module, projectID: project.id, analysis: analysis, function: function)
                } else if analysis.functions.isEmpty {
                    if analysis.format.contains("Mach-O") {
                        REUnlabeledDisassembly(module: module, projectID: project.id)
                    } else {
                        ContentUnavailableView("No functions recovered", systemImage: "function",
                                               description: Text("Native disassembly supports Mach-O binaries. Configure Ghidra to analyze this format."))
                    }
                } else {
                    ContentUnavailableView("No function selected", systemImage: "function",
                                           description: Text("Select a function from the list."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Read-only detail for one function: signature, call relationships, assembly
/// and — when a Ghidra analysis produced it — decompiled pseudocode.
struct REFunctionDetail: View {
    let module: REModule
    let projectID: String
    let analysis: Analysis
    let function: FunctionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                REAnnotationControls(module: module, projectID: projectID, analysis: analysis, function: function)
                VStack(alignment: .leading, spacing: 4) {
                    Text(function.name).font(.title2.monospaced()).textSelection(.enabled)
                    Text(function.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !function.signature.isEmpty {
                        Text(function.signature).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let error = function.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                if !function.callers.isEmpty || !function.callees.isEmpty {
                    HStack(alignment: .top, spacing: 32) {
                        addressList("Callers", function.callers)
                        addressList("Callees", function.callees)
                    }
                }

                codeSection("Decompilation", text: function.code,
                            empty: "No decompilation. Run the Ghidra analysis to produce pseudocode.")
                codeSection("Assembly", text: function.assembly,
                            empty: "No assembly recorded for this function.")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(function.name)
    }

    private func addressList(_ title: String, _ addresses: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(addresses, id: \.self) { address in
                Text(address).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func codeSection(_ title: String, text: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if text.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// A linear listing gives analysts access to stripped code without inventing
/// function boundaries. The visible text is bounded to keep the UI responsive.
private struct REUnlabeledDisassembly: View {
    let module: REModule
    let projectID: String
    @State private var listing: String?
    @State private var error: String?
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Linear disassembly").font(.headline)
            Text("No named functions were recovered. This listing does not identify function boundaries; run Ghidra for deeper analysis.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                ContentUnavailableView("Disassembly unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let listing {
                if truncated { Text("Showing the first 200,000 characters.").font(.caption).foregroundStyle(.secondary) }
                ScrollView([.vertical, .horizontal]) {
                    Text(listing).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("Loading disassembly…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: projectID) {
            listing = nil
            error = nil
            do {
                let text = try await module.linearDisassembly(projectID: projectID)
                truncated = text.count > 200_000
                listing = String(text.prefix(200_000))
            } catch { self.error = error.localizedDescription }
        }
    }
}
