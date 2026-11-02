import Foundation
import ModelLabCore

@main
struct ModelLabSmoke {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "lora" {
            await runLoRASmoke()
            return
        }

        if CommandLine.arguments.dropFirst().first == "smalllm" {
            await runSmallLMSmoke()
            return
        }

        if CommandLine.arguments.dropFirst().first == "logitdistill" {
            await runLogitDistillationSmoke()
            return
        }

        let repoID = CommandLine.arguments.dropFirst().first ?? "mlx-community/Qwen3-0.6B-4bit"
        let prompt = CommandLine.arguments.dropFirst(2).first ?? "Reply with one short sentence."
        let provider = MLXInferenceProvider(repoID: repoID)

        print("repo=\(repoID)")
        print("capability=\(provider.capability().isAvailable ? "available" : provider.capability().reason ?? "unavailable")")

        var output = ""
        do {
            for try await chunk in provider.streamRespond(prompt: prompt, history: []) {
                output += chunk
                if output.count >= 180 { break }
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                print("result=failed: empty generation")
                Foundation.exit(2)
            }
            print("result=ok")
            print(trimmed)
        } catch {
            print("result=failed: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    /// Trains a genuine from-scratch small LM (randomly initialized
    /// transformer, character-level tokenizer built from the corpus below)
    /// for a handful of iterations and generates from it, so this real
    /// training loop can be verified outside `swift test` — MLX's default
    /// Metal library isn't reliably found via `swift test`'s bundle layout
    /// on this machine, but is found fine from a plain SwiftPM executable
    /// (see CAPABILITIES.md).
    static func runSmallLMSmoke() async {
        let corpus = String(repeating: """
            Model Lab is a native macOS workbench for training and running AI models on-device. \
            Model Lab supports Create ML training for text, tabular, and image classifiers. \
            Model Lab supports MLX for local large language model inference and LoRA fine-tuning. \

            """, count: 30)

        let provider = SmallLMPretrainingProvider()
        print("capability=\(provider.capability().isAvailable ? "available" : provider.capability().reason ?? "unavailable")")

        let job = SmallLMPretrainingJob(
            corpusText: corpus,
            contextLength: 32,
            dimensions: 64,
            numHeads: 4,
            numLayers: 3,
            mlpDimensions: 256,
            iterations: 150,
            learningRate: 3e-3,
            batchSize: 16,
            outputName: "smoke-small-lm-\(UUID().uuidString)"
        )

        do {
            let result = try await provider.pretrain(job: job) { progress in
                print("[\(progress.phase)] \(progress.message)")
            }
            print("result=ok vocabSize=\(result.vocabSize) finalLoss=\(result.finalLoss.map { String(format: "%.4f", $0) } ?? "n/a")")

            let artifactStore = ArtifactStore()
            let modelDirectory = artifactStore.absoluteURL(for: result.relativePath, in: .models)
            let greedy = try provider.generate(modelDirectory: modelDirectory, prompt: "Model Lab", maxNewTokens: 60)
            print("generated (greedy, temperature=0)=\(greedy)")

            let sampled1 = try provider.generate(modelDirectory: modelDirectory, prompt: "Model Lab", maxNewTokens: 60, temperature: 0.8, topK: 20)
            print("generated (sampled, temperature=0.8, topK=20)=\(sampled1)")
            let sampled2 = try provider.generate(modelDirectory: modelDirectory, prompt: "Model Lab", maxNewTokens: 60, temperature: 0.8, topK: 20)
            print("generated (sampled, temperature=0.8, topK=20, 2nd run)=\(sampled2)")
        } catch {
            print("result=failed: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    /// Exercises a small real LoRA run and saves an adapter for inspection.
    static func runLoRASmoke() async {
        let examples = [
            "The kiln heats clay until it becomes ceramic.",
            "SwiftUI builds native interfaces using declarative views.",
            "A LoRA adapter trains a small set of low-rank weights.",
            "A test should verify behavior with representative inputs."
        ]
        let job = FineTuningJob(
            baseModelRepoID: "mlx-community/Qwen3-0.6B-4bit",
            trainingTexts: examples, validationTexts: [examples[0]], rank: 4,
            numLayers: 2, iterations: 5, learningRate: 1e-4, batchSize: 1,
            outputName: "smoke-lora-\(UUID().uuidString)"
        )
        do {
            let result = try await MLXFineTuningProvider().fineTune(job: job) { progress in
                print("[\(progress.phase)] \(progress.message)")
            }
            print("result=ok adapter=\(result.adapterRelativePath) loss=\(String(describing: result.finalTrainingLoss))")
        } catch {
            print("result=failed: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    /// Real logit-level distillation smoke test: loads two real models of
    /// the same family (so they share a tokenizer/vocabulary), trains a LoRA
    /// adapter on the smaller student to match the larger teacher's softened
    /// output distribution over a tiny real text corpus, and reports whether
    /// the distillation loss actually decreases.
    static func runLogitDistillationSmoke() async {
        let teacherRepoID = CommandLine.arguments.dropFirst().count > 1
            ? CommandLine.arguments[2] : "mlx-community/Llama-3.2-3B-Instruct-4bit"
        let studentRepoID = CommandLine.arguments.dropFirst().count > 2
            ? CommandLine.arguments[3] : "mlx-community/Llama-3.2-1B-Instruct-4bit"

        let provider = LogitDistillationProvider()
        print("capability=\(provider.capability().isAvailable ? "available" : provider.capability().reason ?? "unavailable")")
        print("teacher=\(teacherRepoID) student=\(studentRepoID)")

        let texts = [
            "Model Lab is a native macOS workbench for training and running AI models on-device.",
            "Model Lab supports Create ML training for text, tabular, and image classifiers.",
            "Model Lab supports MLX for local large language model inference and LoRA fine-tuning.",
            "Model Lab keeps datasets, models, and experiments in a local, privacy-first library.",
            "Model Lab was built with SwiftUI, Swift Concurrency, and SwiftData.",
            "Ask Model Lab about your datasets, models, and training runs in the Playground.",
            "Model Lab's Evaluations tab shows accuracy, confusion matrices, and comparisons.",
            "Model Lab respects your Mac's hardware: it detects Apple silicon and unified memory."
        ]

        let job = LogitDistillationJob(
            teacherRepoID: teacherRepoID,
            studentRepoID: studentRepoID,
            trainingTexts: texts,
            rank: 8,
            numLayers: 8,
            iterations: 120,
            learningRate: 1e-3,
            batchSize: 2,
            temperature: 2.0,
            outputName: "smoke-logit-distill"
        )

        do {
            let result = try await provider.distill(job: job) { progress in
                print("[\(progress.phase)] \(progress.message)")
            }
            print("result=ok finalLoss=\(result.finalTrainingLoss.map { String(format: "%.4f", $0) } ?? "n/a")")
            print("metrics=\(result.metrics.map { "\($0.name)=\($0.value)" })")
        } catch {
            print("result=failed: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }
}
