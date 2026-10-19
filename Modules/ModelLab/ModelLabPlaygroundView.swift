import SwiftUI
import SwiftData
import ModelLabCore

// MARK: - Playground: streaming chat across the engine's real backends

struct ModelLabPlaygroundView: View {
    @Bindable var module: ModelLabModule

    private enum Backend: String, CaseIterable, Identifiable {
        case appleIntelligence = "Apple Intelligence (on-device)"
        case mlxLocal = "MLX (local repo)"
        case trainedSmallLM = "Trained Small LM (local)"
        case coreMLClassifier = "Core ML classifier (local)"

        var id: String { rawValue }
    }

    @State private var backend: Backend = .appleIntelligence
    @State private var mlxRepo = "mlx-community/Qwen3-0.6B-4bit"
    @State private var history: [ChatTurn] = []
    @State private var prompt = ""
    @State private var streaming = false
    @State private var streamText = ""
    @State private var errorText: String?
    @State private var coreMLResult: [(label: String, confidence: Double)] = []
    @State private var loadProgress: Double = 0

    // Kept resident per session, like the engine's AILab playground.
    @State private var mlxProvider: MLXInferenceProvider?
    @State private var smallLMProvider: TinyLMInferenceProvider?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Backend", selection: $backend) {
                ForEach(Backend.allCases) { candidate in
                    Text(candidate.rawValue).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            if backend == .mlxLocal {
                HStack {
                    TextField("HF repo (e.g. mlx-community/Qwen3-0.6B-4bit)", text: $mlxRepo)
                        .onSubmit { mlxProvider = nil; loadProgress = 0 }
                    if loadProgress > 0 && loadProgress < 1 {
                        ProgressView(value: loadProgress).frame(width: 120)
                    }
                }
                .padding(.horizontal)
            }

            if backend == .coreMLClassifier {
                CoreMLClassifierPanel(result: $coreMLResult, errorText: $errorText)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(history) { turn in
                                Text(turn.text)
                                    .padding(8)
                                    .background(turn.role == "user" ? Color.blue.opacity(0.12) : Color.green.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .frame(maxWidth: .infinity, alignment: turn.role == "user" ? .trailing : .leading)
                                    .id(turn.id)
                            }
                            if !streamText.isEmpty {
                                Text(streamText + "▌").padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let errorText {
                                Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: history.count) { _, _ in
                        if let last = history.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                HStack {
                    TextField("Prompt", text: $prompt)
                        .onSubmit(send)
                    Button("Send", action: send).disabled(prompt.isEmpty || streaming)
                }
                .padding(8)
            }
        }
        .navigationTitle("Playground")
    }

    private func send() {
        let currentPrompt = prompt
        prompt = ""
        errorText = nil
        history.append(ChatTurn(role: "user", text: currentPrompt))
        streaming = true
        streamText = ""

        Task { @MainActor in
            do {
                let provider = try await resolveProvider()
                for try await chunk in provider.streamRespond(prompt: currentPrompt, history: history) {
                    streamText += chunk
                    if backend == .mlxLocal {
                        loadProgress = await mlxProvider?.loadProgress ?? 1
                    }
                }
                history.append(ChatTurn(role: "assistant", text: streamText))
                streamText = ""
            } catch {
                errorText = "Backend error: \(error.localizedDescription)"
                if !streamText.isEmpty {
                    history.append(ChatTurn(role: "assistant", text: streamText))
                    streamText = ""
                }
            }
            streaming = false
        }
    }

    private func resolveProvider() throws -> any InferenceProvider {
        switch backend {
        case .appleIntelligence:
            return FoundationModelsInferenceProvider()
        case .mlxLocal:
            if let mlxProvider { return mlxProvider }
            let provider = MLXInferenceProvider(repoID: mlxRepo)
            mlxProvider = provider
            return provider
        case .trainedSmallLM:
            if let smallLMProvider { return smallLMProvider }
            guard let record = newestScratchModel(),
                  let directory = scratchModelDirectory(for: record) else {
                throw InferenceError.unavailable(reason: "No trained small LM artifact exists yet — train one under Experiments first.")
            }
            let provider = try TinyLMInferenceProvider(modelDirectory: directory)
            smallLMProvider = provider
            return provider
        case .coreMLClassifier:
            throw InferenceError.unavailable(reason: "The Core ML classifier backend uses the panel above, not chat streaming.")
        }
    }

    private func newestScratchModel() -> ModelArtifactRecord? {
        guard let context = module.mainContext else { return nil }
        let scratchFormatRaw = ModelFormat.mlxScratchModel.rawValue
        let descriptor = FetchDescriptor<ModelArtifactRecord>(
            predicate: #Predicate { $0.formatRaw == scratchFormatRaw },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try? context.fetch(descriptor).first
    }

    private func scratchModelDirectory(for record: ModelArtifactRecord) -> URL? {
        ModelLabCore.ArtifactStore().absoluteURL(for: record.localRelativePath, in: .models)
    }
}

private struct CoreMLClassifierPanel: View {
    @Binding var result: [(label: String, confidence: Double)]
    @Binding var errorText: String?

    @State private var input = ""
    @State private var modelPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Classify text with a Create ML text-classifier artifact (.mlmodel).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Model file path (from a Create ML run in Experiments)", text: $modelPath)
            TextField("Text to classify", text: $input)
            Button("Classify") { classify() }.disabled(input.isEmpty || modelPath.isEmpty)
            ForEach(result, id: \.label) { pair in
                HStack {
                    Text(pair.label)
                    ProgressView(value: pair.confidence).frame(width: 180)
                    Text(String(format: "%.1f%%", pair.confidence * 100)).font(.caption)
                }
            }
        }
        .padding()
    }

    private func classify() {
        errorText = nil
        result = []
        do {
            let url = URL(fileURLWithPath: (modelPath as NSString).expandingTildeInPath)
            result = try CoreMLClassificationProvider().classify(modelURL: url, text: input)
        } catch {
            errorText = "Classification failed: \(error.localizedDescription)"
        }
    }
}
