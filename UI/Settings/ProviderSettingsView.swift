import SwiftUI
import ApplicationServices

/// Drives the provider-key rows: what is stored, what is being typed, and what the last action said.
@MainActor
@Observable
final class ProviderSettingsModel {
    struct Row: Equatable {
        var draft = ""
        var stored = false
        var lastFour: String?
        var message: String?
        var isError = false
    }

    private(set) var rows: [String: Row] = [:]
    var baseURL = ""
    private let store: ProviderKeyStore

    init(store: ProviderKeyStore = ProviderKeyStore()) {
        self.store = store
        reload()
    }

    func reload() {
        for entry in ProviderKeyEntry.all {
            var row = rows[entry.id] ?? Row()
            row.stored = store.hasKey(entry.id)
            row.lastFour = store.lastFour(entry.id)
            rows[entry.id] = row
        }
    }

    func setDraft(_ text: String, for id: String) { rows[id, default: Row()].draft = text }

    /// Saves the draft. Returns true on success so the caller can refresh the model list.
    @discardableResult
    func save(_ id: String) -> Bool {
        var row = rows[id] ?? Row()
        do {
            try store.save(row.draft, for: id)
            row.draft = ""
            row.message = "Saved. Models from this provider will load shortly."
            row.isError = false
            rows[id] = row
            reload()
            return true
        } catch {
            row.message = String(describing: error)
            row.isError = true
            rows[id] = row
            return false
        }
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        var row = rows[id] ?? Row()
        do {
            try store.remove(id)
            row.message = "Removed."
            row.isError = false
            rows[id] = row
            reload()
            return true
        } catch {
            row.message = String(describing: error)
            row.isError = true
            rows[id] = row
            return false
        }
    }
}

/// Settings (⌘,): API keys for hosted model providers, each with a link to the page that issues one.
struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var model = ProviderSettingsModel()
    @AppStorage("computerUse.enabled") private var computerUseEnabled = false
    @AppStorage("provider.firstChunkTimeout") private var firstChunkTimeout = 90.0
    @AppStorage(ToolSummaryStyle.defaultsKey) private var toolSummaryStyle = ToolSummaryStyle.sentence.rawValue
    /// Live: macOS can say "Kiln: on" for another copy of Kiln while this copy is not trusted, so show what this copy sees.
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SSSpacing.l) {
                VStack(alignment: .leading, spacing: SSSpacing.xs) {
                    Text("Model providers").font(SSTypography.title())
                    Text("Keys are stored in your macOS Keychain, not in Kiln's files. They are sent only to the provider they belong to, and Kiln never shows a saved key again.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                ForEach(ProviderKeyEntry.all) { entry in
                    row(entry)
                }
                VStack(alignment: .leading, spacing: SSSpacing.xs) {
                    Picker("Appearance", selection: Binding(get: { app.themeManager.appearance }, set: { app.themeManager.apply($0) })) {
                        ForEach(ThemeManager.Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Text("Kiln follows the system by default. Light, Dark and High Contrast apply to every window.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: SSSpacing.xs) {
                    Picker("Finished steps in chat", selection: $toolSummaryStyle) {
                        ForEach(ToolSummaryStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Text("After a run, the steps fold into one line: what it did (\"Ran 2 commands and read 3 files\") or how long it worked (\"Worked for 42s\"). Click the line to see each step.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: SSSpacing.xs) {
                    Stepper(value: $firstChunkTimeout, in: 10...600, step: 15) {
                        Text("Wait for a first reply: \(Int(firstChunkTimeout)) s")
                    }
                    Text("Hosted models sometimes queue a request for a minute or more before answering. A request with no reply by then is reported as stalled instead of hanging.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                if let session = app.chatSession {
                    VStack(alignment: .leading, spacing: SSSpacing.xs) {
                        Text("Agent step limits").font(SSTypography.headline())
                        ForEach(session.agentProfiles, id: \.name) { profile in
                            Stepper(value: Binding(get: { session.roundLimit(for: profile) }, set: { session.setRoundLimit($0, for: profile) }), in: AgentRoundLimits.allowed, step: 50) {
                                Text("\(profile.name): \(session.roundLimit(for: profile)) steps")
                            }
                        }
                        Text("Each run pauses at its profile's limit. Changes apply to the next run; approvals and budgets still apply.")
                            .font(SSTypography.caption()).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: SSSpacing.xs) {
                    Toggle("Computer use", isOn: $computerUseEnabled)
                    Text("Allow the agent to inspect and interact with running apps. Each action asks for approval and macOS Accessibility permission is required.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(accessibilityTrusted ? SSColor.success : SSColor.danger)
                        Text(accessibilityTrusted ? "Accessibility is granted to this copy of Kiln." : "Accessibility is NOT granted to this copy of Kiln.")
                            .font(SSTypography.caption())
                    }
                    Text(Bundle.main.bundlePath).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled)
                    if !accessibilityTrusted {
                        Text("If Kiln already shows as ON in System Settings, that entry belongs to a different build (for example an earlier or development copy). Select Kiln in the list, press the minus button to remove it, press plus, choose the Kiln above, switch it on, then relaunch Kiln.")
                            .font(SSTypography.caption()).foregroundStyle(SSColor.warning)
                    }
                    HStack {
                        Button("Request Accessibility access") {
                            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                        }
                        Button("Open Accessibility settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                        }
                        Button("Relaunch Kiln") { Self.relaunch() }
                    }
                }
                ModelStoreCard()
                Divider()
                AboutKilnView()
            }
            .padding(SSSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 700)
        .task {
            // Re-check while Settings is open, so granting it in System Settings shows up without reopening this window.
            while !Task.isCancelled {
                accessibilityTrusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .background(SSColor.canvas)
        .task { model.baseURL = await app.settings.get("providers.custom.baseURL", as: String.self, fallback: "") }
    }

    private func row(_ entry: ProviderKeyEntry) -> some View {
        let state = model.rows[entry.id] ?? .init()
        return VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack(spacing: SSSpacing.s) {
                Text(entry.name).font(SSTypography.headline())
                SSBadge(text: state.stored ? "Saved · …\(state.lastFour ?? "")" : "Not set",
                        tint: state.stored ? SSColor.success : .secondary)
                Spacer()
                if let page = entry.keysPage {
                    Button { openURL(page) } label: {
                        Label("Get an API key", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.link)
                    .help(page.absoluteString)
                }
            }
            Text(entry.note).font(SSTypography.caption()).foregroundStyle(.secondary)
            if entry.needsBaseURL {
                TextField("Base URL, e.g. http://localhost:1234/v1", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await applyBaseURL() } }
            }
            HStack {
                SecureField(entry.keyPrefixHint.map { "Paste key (\($0)…)" } ?? "Paste key",
                            text: Binding(get: { state.draft }, set: { model.setDraft($0, for: entry.id) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save(entry) } }
                Button("Save") { Task { await save(entry) } }
                    .disabled(state.draft.isEmpty && !entry.needsBaseURL)
                if state.stored {
                    Button("Remove", role: .destructive) { Task { await remove(entry) } }
                }
            }
            if let message = state.message {
                Text(message).font(SSTypography.caption())
                    .foregroundStyle(state.isError ? SSColor.danger : .secondary)
            }
        }
        .padding(SSSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ssPanel()
    }

    private func save(_ entry: ProviderKeyEntry) async {
        if entry.needsBaseURL { await applyBaseURL() }
        let draft = model.rows[entry.id]?.draft ?? ""
        // A custom endpoint may be saved with only a URL; every other provider needs a key.
        if entry.needsBaseURL && draft.isEmpty { return }
        if model.save(entry.id) { await app.reloadProviders() }
    }

    private func remove(_ entry: ProviderKeyEntry) async {
        if model.remove(entry.id) { await app.reloadProviders() }
    }

    private func applyBaseURL() async {
        let url = model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await app.settings.set(url, forKey: "providers.custom.baseURL")
        await app.reloadProviders()
    }
}


/// Points Kiln at the shared model store (Hugging Face cache layout), usually on an external drive. Kiln is
/// sandboxed, so it can only read the folder after you choose it here; your models are never copied or moved.
struct ModelStoreCard: View {
    @Environment(AppModel.self) private var app
    @State private var path: String?
    @State private var count: Int?
    @State private var scanning = false
    @State private var message: String?

    private var location: ModelStoreLocation { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack(spacing: SSSpacing.s) {
                Text("Local model store").font(SSTypography.headline())
                if scanning {
                    ProgressView().controlSize(.small)
                } else if let count {
                    SSBadge(text: count == 1 ? "1 language model" : "\(count) language models",
                            tint: count > 0 ? SSColor.success : .secondary)
                } else {
                    SSBadge(text: "Not set", tint: .secondary)
                }
                Spacer()
            }
            Text("Models you already downloaded (the shared Hugging Face cache, with its models--org--repo folders) appear under “MLX (Local)” in the model picker and run on this Mac. Choose the folder that holds them, usually the hub folder inside your huggingface cache. Kiln only reads it.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            if let path {
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Choose Folder…") { choose() }
                if location.hasChoice { Button("Clear", role: .destructive) { clear() } }
            }
            if let message { Text(message).font(SSTypography.caption()).foregroundStyle(.secondary) }
        }
        .padding(SSSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ssPanel()
        .task { await refresh() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that contains your models--org--repo folders (the Hugging Face hub folder)."
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".cache/huggingface")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try location.choose(url)
            message = nil
            Task { await refresh(reload: true) }
        } catch {
            message = "Could not remember that folder: \(error.localizedDescription)"
        }
    }

    private func clear() {
        location.clear()
        message = nil
        Task { await refresh(reload: true) }
    }

    /// Counting walks every weight file to total its size, which is slow on an external drive: off the main thread.
    private func refresh(reload: Bool = false) async {
        scanning = true
        let found: (String?, Int?)
        if let folder = ModelStoreLocation.shared.folder {
            let store = UniversalModelStore(root: ModelStoreLocation.hubDirectory(in: folder))
            found = (store.root.path, await store.installedOffPool(forceRefresh: reload).filter(\.isLanguageModel).count)
        } else {
            found = (nil, nil)
        }
        path = found.0
        count = found.1
        scanning = false
        if let count, count == 0 {
            message = "No language models were found there. Pick the folder that directly contains the models--org--repo folders."
        }
        if reload { await app.reloadProviders() }
    }
}


extension ProviderSettingsView {
    /// Opens a fresh copy of this app and quits this one, so a newly granted permission is picked up.
    @MainActor static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
