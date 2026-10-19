import SwiftUI
import AppKit
import ModelLabCore

// MARK: - Evaluation (item 8) + AutoPrompt (item 9)

struct ModelLabEvaluationView: View {
    @Bindable var module: ModelLabModule

    @State private var predictionsText = "the cat sat on the mat"
    @State private var referencesText = "the cat sat on the mat"
    @State private var outcome: EvaluationRun?
    @State private var evalError: String?
    @State private var perplexityNLLs = "1.2, 1.0, 0.8"
    @State private var perplexityValue: MetricOutcome?

    // Auto-prompt optimizer state
    @State private var taskDescription = "Answer support questions concisely"
    @State private var seedPrompts = "Answer the user's question in one short paragraph."
    @State private var iterations = 3
    @State private var optimization: AutoPromptEngine.OptimizationResult?
    @State private var optimizing = false
    @State private var scoredEvaluatorNote: String?

    var body: some View {
        List {
            Section("Text metrics — predictions (one per line) vs references (one per line)") {
                TextEditor(text: $predictionsText).font(.system(.caption, design: .monospaced)).frame(minHeight: 70)
                TextEditor(text: $referencesText).font(.system(.caption, design: .monospaced)).frame(minHeight: 70)
                Button("Run accuracy, F1, BLEU, ROUGE-1/2/L") { runMetrics() }
                if let evalError {
                    Text(evalError).font(.caption).foregroundStyle(.red)
                }
                if let outcome {
                    ForEach(outcome.outcomes) { metric in
                        HStack {
                            Text(metric.metricName)
                            Spacer()
                            Text(String(format: "%.4g", metric.value)).monospacedDigit()
                            Text(metric.lowerIsBetter ? "lower is better" : "higher is better")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Perplexity — from per-token negative log-likelihoods") {
                Text("A backend that scores tokens supplies NLLs; the formula is the standard exp(mean NLL). Line format: comma- or newline-separated NLL values.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("NLLs", text: $perplexityNLLs)
                Button("Compute perplexity") { runPerplexity() }
                if let perplexityValue {
                    HStack {
                        Text("perplexity")
                        Spacer()
                        Text(String(format: "%.4g", perplexityValue.value)).monospacedDigit()
                        Text("lower is better").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Auto-prompt optimization (templates + mutation; hill-climb against an evaluator)") {
                TextField("Task description", text: $taskDescription)
                TextEditor(text: $seedPrompts).font(.caption).frame(minHeight: 50)
                Stepper("Iterations: \(iterations)", value: $iterations, in: 1...10)
                HStack {
                    Button("Optimize prompt") { optimizePrompt() }
                        .disabled(optimizing)
                    if optimizing { ProgressView().controlSize(.small) }
                }
                if let scoredEvaluatorNote {
                    Text(scoredEvaluatorNote).font(.caption).foregroundStyle(.secondary)
                }
                if let optimization {
                    LabeledGrid(rows: [
                        ("Best prompt", optimization.bestPrompt),
                        ("Best score", String(format: "%.4g", optimization.bestScore)),
                        ("Candidates evaluated", "\(optimization.candidatesEvaluated)"),
                    ])
                }
            }
        }
        .navigationTitle("Evaluation")
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func runMetrics() {
        evalError = nil
        outcome = nil
        do {
            outcome = try EvaluationRunner().evaluate(
                modelName: "manual",
                predictions: lines(predictionsText),
                references: lines(referencesText),
                metrics: [
                    AccuracyMetric(), F1Metric(), BLEUMetric(),
                    ROUGEMetric(.rouge1), ROUGEMetric(.rouge2), ROUGEMetric(.rougeL),
                ]
            )
        } catch {
            evalError = error.localizedDescription
        }
    }

    private func runPerplexity() {
        evalError = nil
        perplexityValue = nil
        let nlls = perplexityNLLs
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        do {
            perplexityValue = try EvaluationRunner().perplexityOutcome(nlls: nlls)
        } catch {
            evalError = error.localizedDescription
        }
    }

    /// The evaluator for offline optimization: exact-match rate against the
    /// references pane, so the optimizer demonstrably climbs a real signal.
    /// When the app's ModelRegistry is available the module can wire an LLM
    /// judge instead; this view says which one ran.
    private func optimizePrompt() {
        optimizing = true
        optimization = nil
        let task = AutoPromptEngine.Task(
            description: taskDescription,
            seedPrompts: lines(seedPrompts)
        )
        let references = Set(lines(referencesText))
        scoredEvaluatorNote = "Evaluator: overlap with the reference lines (character-bigram F1). Offline deterministic — an LLM judge can be wired in later phases."
        Task { @MainActor in
            let engine = AutoPromptEngine()
            optimization = await engine.optimizePrompt(
                initial: task.seedPrompts.first ?? task.description,
                task: task,
                evaluator: { candidate in
                    OfflinePromptEvaluator.overlapScore(candidate, references: references)
                },
                iterations: iterations
            )
            optimizing = false
        }
    }
}

/// Nonisolated so it can run inside the evaluator closure the optimization
/// loop hops across.
enum OfflinePromptEvaluator {
    static func overlapScore(_ candidate: String, references: Set<String>) -> Double {
        let candidateGrams = characterBigrams(candidate)
        var best: Double = 0
        for reference in references {
            let referenceGrams = characterBigrams(reference)
            guard !candidateGrams.isEmpty && !referenceGrams.isEmpty else { continue }
            let overlap = Double(candidateGrams.intersection(referenceGrams).count)
            let precision = overlap / Double(candidateGrams.count)
            let recall = overlap / Double(referenceGrams.count)
            if precision + recall > 0 {
                best = max(best, 2 * precision * recall / (precision + recall))
            }
        }
        return best
    }

    static func characterBigrams(_ text: String) -> Set<String> {
        let characters = Array(text.lowercased())
        guard characters.count > 1 else { return [] }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }
}

// MARK: - Red Team (item 10)

struct ModelLabRedTeamView: View {
    @Bindable var module: ModelLabModule

    private enum Target: String, CaseIterable, Identifiable {
        case appleIntelligence = "Apple Intelligence"
        case mlxLocal = "MLX (local repo)"
        var id: String { rawValue }
    }

    @State private var target: Target = .appleIntelligence
    @State private var mlxRepo = "mlx-community/Qwen3-0.6B-4bit"
    @State private var running = false
    @State private var report: RedTeamHarness.Report?
    @State private var reportURL: URL?
    @State private var errorText: String?

    var body: some View {
        List {
            Section("Target") {
                Picker("Backend", selection: $target) {
                    ForEach(Target.allCases) { candidate in Text(candidate.rawValue).tag(candidate) }
                }
                if target == .mlxLocal {
                    TextField("HF repo", text: $mlxRepo)
                }
                HStack {
                    Button("Run red-team assessment") { run() }
                        .disabled(running)
                    if running { ProgressView().controlSize(.small) }
                }
                Text("Suites: jailbreak, prompt injection, system-prompt extraction, PII leakage, harmful content. Every finding keeps the raw transcript; the judge's reason names what it matched.")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            if let report {
                Section("Summary — \(report.modelName)") {
                    LabeledGrid(rows: [
                        ("Blocked", "\(report.blockedCount)"),
                        ("Leaked", "\(report.leakedCount)"),
                        ("Inconclusive", "\(report.inconclusiveCount)"),
                        ("Robustness score", String(format: "%.0f%%", report.robustnessScore * 100)),
                    ])
                }
                Section("Findings") {
                    ForEach(report.findings) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: verdictIcon(finding.verdict))
                                    .foregroundStyle(verdictColor(finding.verdict))
                                Text(finding.category.displayName).font(.headline)
                                Spacer()
                                Text(finding.verdict.rawValue).font(.caption)
                            }
                            Text(finding.prompt).font(.caption).foregroundStyle(.secondary)
                            Text(finding.reason).font(.caption)
                        }
                    }
                }
                Section {
                    Button("Export report (JSON)") { exportReport() }
                    if let reportURL {
                        Text("Saved: \(reportURL.path)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Red Team")
    }

    private func run() {
        running = true
        errorText = nil
        report = nil
        Task { @MainActor in
            let provider: any InferenceProvider
            switch target {
            case .appleIntelligence:
                provider = FoundationModelsInferenceProvider()
            case .mlxLocal:
                provider = MLXInferenceProvider(repoID: mlxRepo)
            }
            let harness = RedTeamHarness()
            report = await harness.runAssessment(
                modelName: target.rawValue,
                target: { prompt in
                    var text = ""
                    for try await chunk in provider.streamRespond(prompt: prompt, history: []) {
                        text += chunk
                    }
                    return text
                }
            )
            running = false
        }
    }

    private func exportReport() {
        guard let report else { return }
        let encoder = JSONEncoder.prettyEncoder
        guard let data = try? encoder.encode(report) else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "redteam-report.json"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            reportURL = url
        } catch {
            errorText = "Export failed: \(error.localizedDescription)"
        }
    }

    private func verdictIcon(_ verdict: RedTeamHarness.Verdict) -> String {
        switch verdict {
        case .blocked: "checkmark.shield.fill"
        case .leaked: "exclamationmark.shield.fill"
        case .inconclusive: "questionmark.shield"
        }
    }

    private func verdictColor(_ verdict: RedTeamHarness.Verdict) -> Color {
        switch verdict {
        case .blocked: .green
        case .leaked: .red
        case .inconclusive: .orange
        }
    }
}
