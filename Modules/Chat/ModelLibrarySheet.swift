import SwiftUI

/// Add and remove local Ollama models. Downloads run in the background (the picker can be closed) and are listed here and through the `models_*` tools.
/// MLX and Hugging Face downloads are not here yet; Ollama can pull a Hugging Face GGUF with the name `hf.co/<user>/<repo>:<quant>`.
struct ModelLibrarySheet: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var state = ModelLibraryState.shared
    @State private var newName = ""
    @State private var error: String?
    @State private var confirmRemove: OllamaInstalledModel?

    /// A short, dated starting list (2026-11-13), not a catalog: Ollama has no documented listing API. Any name from ollama.com/library works.
    private static let suggestions = ["llama3.2:1b", "llama3.2:3b", "qwen3:4b", "gemma3:4b", "phi4-mini", "smollm2:1.7b"]

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            HStack {
                Text("Local models (Ollama)").font(SSTypography.title())
                Spacer()
                Button("Refresh") { Task { await state.refresh() } }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let message = state.message {
                Text(message).font(SSTypography.caption()).foregroundStyle(SSColor.warning)
            }
            GroupBox("Add a model") {
                VStack(alignment: .leading, spacing: SSSpacing.s) {
                    HStack {
                        TextField("Model name, e.g. llama3.2:3b or hf.co/user/repo:Q4_K_M", text: $newName).textFieldStyle(.roundedBorder).onSubmit(download)
                        Button("Download", action: download).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(Self.suggestions, id: \.self) { name in Button(name) { newName = name }.buttonStyle(.bordered).controlSize(.small) } }
                    }
                    Text("Downloads can be several gigabytes. Kiln checks free disk space once Ollama reports the size and keeps 2 GB spare. Ollama resumes a download if you start it again after cancelling.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    if let error { Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
                }.padding(SSSpacing.xs)
            }
            if !state.pulls.isEmpty {
                GroupBox("Downloads") {
                    VStack(alignment: .leading, spacing: SSSpacing.s) {
                        ForEach(state.pulls) { pull in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(pull.name).font(SSTypography.body())
                                    Spacer()
                                    if pull.phase == .running { Button("Cancel") { state.cancelPull(pull.name) }.controlSize(.small) }
                                }
                                if pull.phase == .running, let fraction = pull.fraction { ProgressView(value: fraction) } else if pull.phase == .running { ProgressView().controlSize(.small) }
                                Text(detail(pull)).font(SSTypography.caption()).foregroundStyle(pull.phase.isFailure ? SSColor.danger : .secondary)
                            }
                        }
                    }.padding(SSSpacing.xs)
                }
            }
            GroupBox("Installed") {
                if state.installed.isEmpty {
                    Text(state.message == nil ? "No models installed in Ollama." : "Nothing to show.").font(SSTypography.caption()).foregroundStyle(.secondary).padding(SSSpacing.xs)
                } else {
                    List(state.installed) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.name)
                                Text(summary(model)).font(SSTypography.caption()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.running.contains(where: { $0.name == model.name }) { Text("loaded").font(SSTypography.caption()).foregroundStyle(.secondary) }
                            Button("Remove…", role: .destructive) { confirmRemove = model }.controlSize(.small)
                        }
                    }.frame(minHeight: 160)
                }
            }
        }
        .padding(SSSpacing.m)
        .frame(minWidth: 520, minHeight: 520)
        .task { await state.refresh() }
        .alert("Remove \(confirmRemove?.name ?? "model")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { model in
            Button("Remove", role: .destructive) { remove(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This deletes the model from Ollama and frees about \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)). You can download it again later.")
        }
    }

    private func summary(_ model: OllamaInstalledModel) -> String {
        // Ollama Cloud entries are a few hundred bytes of metadata; the model itself runs on Ollama's servers.
        if model.sizeBytes < 1_000_000, model.name.contains("cloud") { return "Hosted by Ollama (nothing stored on this Mac)" }
        [ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file), model.parameterSize, model.quantization].compactMap { $0 }.joined(separator: " · ")
    }

    private func detail(_ pull: ModelLibraryState.Pull) -> String {
        if pull.phase == .running, pull.total > 0 {
            return "\(pull.status) · \(ByteCountFormatter.string(fromByteCount: pull.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: pull.total, countStyle: .file))"
        }
        return pull.status
    }

    private func download() {
        error = nil
        do { try state.startPull(newName, audit: session.platformAudit); newName = "" } catch { self.error = error.localizedDescription }
    }

    private func remove(_ model: OllamaInstalledModel) {
        error = nil
        Task { do { try await state.remove(model.name, audit: session.platformAudit) } catch { self.error = error.localizedDescription } }
    }
}

private extension ModelLibraryState.Pull.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
