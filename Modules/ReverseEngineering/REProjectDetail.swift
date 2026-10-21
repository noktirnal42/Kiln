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

    private var selectedFunction: FunctionRecord? {
        guard let selectedAddress else { return nil }
        return analysis.functions.first { $0.address == selectedAddress }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Functions").tag(REFindingsTab?.none)
                ForEach(REFindingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(REFindingsTab?.some(tab))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            if let tab {
                REFindingsView(module: module, projectID: project.id, tab: tab)
            } else {
                functionsBody
            }
        }
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
                    ContentUnavailableView("No functions recovered", systemImage: "function",
                                           description: Text("Native inspection found no named code symbols. "
                                               + "The binary is probably stripped. Strings, crypto, format and "
                                               + "gadget analyses still work; Ghidra can recover stripped functions."))
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
