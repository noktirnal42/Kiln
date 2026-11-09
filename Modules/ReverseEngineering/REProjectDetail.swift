import SwiftUI
import AxiomCore

/// One analyzed binary. The Functions tab is two columns: function list on the
/// left, the selected function's assembly and decompilation on the right. The
/// other tabs run analyses over the whole binary (see `REFindingsView`).
struct REProjectDetail: View {
    let module: REModule
    let project: REModule.REProject
    let analysis: Analysis
    @Binding var projectsVisible: Bool

    @State private var selectedAddress: String?
    @State private var tab: REViewTab = .functions
    @State private var functionQuery = ""
    @State private var analysisError: String?

    private var selectedFunction: FunctionRecord? {
        guard let selectedAddress else { return nil }
        return analysis.functions.first { $0.address == selectedAddress }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the unpacked Ghidra folder (it contains support/analyzeHeadless)"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        analysisError = module.chooseGhidra(home: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Analyze", symbol: "magnifyingglass.circle") {
                SSTabStrip(tabs: REViewTab.allCases, selection: $tab, title: { $0.rawValue }, symbol: { $0.symbol })
            } trailing: {
                Button { projectsVisible.toggle() } label: { Label(projectsVisible ? "Hide projects" : "Show projects", systemImage: "sidebar.left") }
                    .help(projectsVisible ? "Hide the project list" : "Show the project list")
                if module.isGhidraAnalysisRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel", systemImage: "xmark.circle") { module.cancelGhidraAnalysis() }
                        .help("Stop the analysis. Nothing is changed in this project.")
                }
                analyzeMenu.labelStyle(.titleAndIcon)
            }
            engineStrip
            if let finding = tab.finding {
                REFindingsView(module: module, projectID: project.id, tab: finding)
            } else {
                functionsBody
            }
        }
        .alert("Ghidra analysis failed", isPresented: Binding(get: { analysisError != nil }, set: { if !$0 { analysisError = nil } })) {
            Button("OK") { analysisError = nil }
        } message: { Text(analysisError ?? "") }
    }

    /// Engines the binary can be (re)analyzed with. One menu instead of three buttons plus a status paragraph.
    private var analyzeMenu: some View {
        Menu {
            Button("Analyze with Ghidra", systemImage: "bolt") {
                Task {
                    do { _ = try await module.analyzeWithGhidra(projectID: project.id) }
                    catch is OperationCancelled { analysisError = nil }
                    catch { analysisError = error.localizedDescription }
                }
            }
            .disabled(!module.isGhidraAvailable || module.isGhidraAnalysisRunning)
            Button("Analyze with radare2", systemImage: "hare") {
                Task {
                    do { _ = try await module.analyzeWithRadare2(projectID: project.id) }
                    catch { analysisError = error.localizedDescription }
                }
            }
            .disabled(!module.isRadare2Available || module.isGhidraAnalysisRunning)
            Divider()
            Section("Ghidra installation") {
                ForEach(module.ghidraChoices, id: \.home) { choice in
                    Button {
                        analysisError = module.chooseGhidra(home: choice.home)
                    } label: {
                        if choice.home == module.ghidraHome { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                    }
                }
                if module.ghidraChoices.isEmpty { Text("No Ghidra 11+ found in ~/Applications or /Applications") }
                Button("Choose Ghidra Folder…") { chooseFolder() }
                if module.hasExplicitGhidraChoice { Button("Pick Automatically") { module.chooseGhidraAutomatically() } }
            }
        } label: {
            Label("Analyze", systemImage: "bolt")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Recover functions, pseudocode and references with Ghidra or radare2. Neither runs the binary.")
        .accessibilityLabel("Analyze")
    }

    /// One quiet line under the header: which engine is ready. The full text is the tooltip.
    private var engineStrip: some View {
        HStack(spacing: SSSpacing.s) {
            SSStatusLine(color: module.isGhidraAvailable ? SSColor.success : SSColor.warning, text: module.ghidraStatus)
                .accessibilityLabel(module.isGhidraAvailable ? "Ghidra ready. \(module.ghidraStatus)" : "Ghidra unavailable. \(module.ghidraStatus)")
            Spacer(minLength: 0)
            Text("\(project.binaryURL.lastPathComponent) · \(analysis.format)").font(SSTypography.caption())
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, SSSpacing.m)
        .frame(height: 24)
        .background(SSColor.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(SSColor.hairline).frame(height: 1) }
        .help(module.ghidraStatus)
    }

    private var filteredFunctions: [FunctionRecord] {
        let q = functionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return analysis.functions }
        return analysis.functions.filter { $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q) }
    }

    private var functionsBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SSPaneHeader("Functions", count: analysis.functions.count)
                TextField("Filter", text: $functionQuery)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .padding(SSSpacing.s)
                if analysis.functions.isEmpty {
                    Text("None recovered yet.").font(SSTypography.caption()).foregroundStyle(.tertiary)
                        .padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    List(selection: $selectedAddress) {
                        ForEach(filteredFunctions) { function in
                            Text(function.name)
                                .font(SSTypography.mono(11))
                                .lineLimit(1)
                                .tag(function.address)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 190)
            .background(SSColor.surface)
            Divider()
            Group {
                if let function = selectedFunction {
                    REFunctionDetail(module: module, projectID: project.id, analysis: analysis, function: function) { selectedAddress = $0 }
                } else if analysis.functions.isEmpty {
                    if analysis.format.contains("Mach-O") {
                        REUnlabeledDisassembly(module: module, projectID: project.id)
                    } else {
                        SSEmptyState(symbol: "function", title: "No functions recovered",
                                     message: "Native disassembly supports Mach-O binaries. Use Analyze › Analyze with Ghidra for this format.")
                    }
                } else {
                    SSEmptyState(symbol: "function", title: "No function selected",
                                 message: "Select a function to see its listing and decompilation.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What the Analyze detail can show: the function browser, or one of the whole-binary analyses.
enum REViewTab: String, CaseIterable, Identifiable {
    case functions = "Functions", strings = "Strings", crypto = "Crypto", formats = "Formats"
    case gadgets = "Gadgets", rules = "Rules", forensics = "Forensics", script = "Script"
    var id: String { rawValue }
    var finding: REFindingsTab? { REFindingsTab(rawValue: rawValue) }
    var symbol: String {
        switch self {
        case .functions: "function"
        case .strings: "textformat"
        case .crypto: "key"
        case .formats: "doc.text.magnifyingglass"
        case .gadgets: "link"
        case .rules: "checklist"
        case .forensics: "waveform.path.ecg"
        case .script: "curlybraces"
        }
    }
}

/// Read-only detail for one function: signature, call relationships, and the listing and
/// decompiler panes (side by side when there is room, stacked when there is not).
struct REFunctionDetail: View {
    let module: REModule
    let projectID: String
    let analysis: Analysis
    let function: FunctionRecord
    var onSelectAddress: (String) -> Void = { _ in }
    @State private var showAnnotations = false

    private func isFunction(_ address: String) -> Bool {
        analysis.functions.contains { $0.address == address }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: SSSpacing.xs) {
                HStack(spacing: SSSpacing.s) {
                    Text(function.name).font(SSTypography.mono(14).weight(.semibold)).lineLimit(1).textSelection(.enabled)
                    Text(function.address).font(SSTypography.mono(11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { showAnnotations.toggle() } label: { Label("Annotate", systemImage: "pencil.line") }
                        .buttonStyle(.borderless).controlSize(.small).labelStyle(.iconOnly)
                        .help("Annotate: rename, comment or bookmark this function")
                        .popover(isPresented: $showAnnotations) {
                            REAnnotationControls(module: module, projectID: projectID, analysis: analysis, function: function)
                                .padding(SSSpacing.m).frame(width: 340)
                        }
                }
                if !function.signature.isEmpty {
                    Text(function.signature).font(SSTypography.mono(11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if let error = function.error {
                    Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                }
                if !function.callers.isEmpty || !function.callees.isEmpty {
                    HStack(alignment: .top, spacing: SSSpacing.l) {
                        addressList("Callers", function.callers)
                        addressList("Callees", function.callees)
                    }
                }
            }
            .padding(SSSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SSColor.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(SSColor.hairline).frame(height: 1) }
            GeometryReader { geometry in
                let wide = geometry.size.width >= 640
                let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    codePane("Decompiler", text: function.code,
                             empty: "No decompilation. Use Analyze › Analyze with Ghidra to produce pseudocode.")
                    if wide { Divider() } else { Divider() }
                    codePane("Listing", text: function.assembly, empty: "No assembly recorded for this function.")
                }
            }
        }
    }

    private func addressList(_ title: String, _ addresses: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SSSectionLabel("\(title) (\(addresses.count))")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(addresses.prefix(40), id: \.self) { address in
                        if isFunction(address) {
                            Button(address) { onSelectAddress(address) }
                                .buttonStyle(.link).font(SSTypography.mono(10.5))
                        } else {
                            Text(address).font(SSTypography.mono(10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func codePane(_ title: String, text: String, empty: String) -> some View {
        VStack(spacing: 0) {
            SSPaneHeader(title)
            if text.isEmpty {
                Text(empty).font(SSTypography.caption()).foregroundStyle(.secondary)
                    .padding(SSSpacing.m).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(SSColor.canvas)
            } else {
                SSCodeBlock(text: text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 0) {
            SSPaneHeader("Linear disassembly")
            Text("No named functions were recovered. This listing does not identify function boundaries; run Ghidra for deeper analysis.")
                .font(SSTypography.caption()).foregroundStyle(.secondary).padding(SSSpacing.m)
            if let error {
                ContentUnavailableView("Disassembly unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let listing {
                if truncated { Text("Showing the first 200,000 characters.").font(.caption).foregroundStyle(.secondary) }
                SSCodeBlock(text: listing)
            } else {
                ProgressView("Loading disassembly…")
            }
        }
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
