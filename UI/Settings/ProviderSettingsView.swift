import SwiftUI

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
            }
            .padding(SSSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 700)
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
