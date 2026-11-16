import SwiftUI

extension Activity { static let lab = Activity("lab") }

/// Lab: datasets, training, evaluation and models. Tools are `lab_*` (see `ModelLabAgentTools`).
enum LabActivity {
    static let descriptor = ActivityDescriptor(
        id: "lab", title: "Lab", symbol: "brain.head.profile", summary: "Datasets, training, evaluation and models",
        moduleIdentifier: ModelLabModule.identifier,
        starterPrompts: { _ in
            [StarterPrompts.hardware, StarterPrompts.datasets,
             StarterPrompt(title: "Find a small model", symbol: "magnifyingglass",
                           text: "Search Hugging Face for a small instruction-tuned model that fits this Mac, and compare two good candidates.")]
        },
        toolPrefixes: ["lab_", "models_"],
        agentPromptSentence: "Use the lab_* tools to inspect hardware, experiments and datasets.",
        capabilities: [
            .tool("lab_hardware", "Hardware report", .read),
            .tool("lab_list_experiments", "List experiments", .read),
            .tool("lab_get_experiment", "Experiment status and metrics", .read),
            .tool("lab_create_experiment", "Create an experiment", .write),
            .tool("lab_start_training", "Train with Create ML", .execute),
            .tool("lab_cancel_training", "Cancel training", .write),
            .tool("lab_start_small_lm", "Train a small language model from scratch", .execute),
            .tool("lab_start_lora", "Fine-tune with LoRA", .execute),
            .tool("lab_start_distillation", "Start distillation", .execute),
            .tool("lab_list_datasets", "List datasets", .read),
            .tool("lab_search_datasets", "Search Hugging Face datasets", .execute),
            .tool("lab_import_dataset", "Import a dataset", .write),
            .tool("lab_search_models", "Search Hugging Face models", .execute),
            .tool("lab_list_models", "List models", .read),
            .tool("lab_register_model", "Register a model", .write),
            .tool("lab_delete_model", "Delete a model", .execute),
            .tool("lab_export_model", "Export a model", .write),
            .tool("models_installed", "List installed Ollama models", .read),
            .tool("models_pull", "Download an Ollama model", .write),
            .tool("models_progress", "Progress of model downloads", .read),
            .tool("models_cancel", "Cancel a model download", .write),
            .tool("models_remove", "Remove an installed Ollama model", .admin),
            .tool("lab_predict", "Classify text with a trained model", .read),
            .tool("lab_predict_images", "Classify images with a trained model", .read),
            .tool("lab_evaluate_predictions", "Accuracy, F1, BLEU, ROUGE", .read),
            .exempt("lab.playground", "Playground chat and compare runs", .execute,
                    because: "Gap: prompting a lab model from the playground has no tool yet; the Agent activity chats with the same registry models."),
            .exempt("lab.compute-perplexity", "Compute perplexity", .read,
                    because: "Gap: no tool yet for perplexity or prompt optimization (docs/13, Model Lab)."),
            .exempt("lab.red-team", "Run a red-team assessment", .execute,
                    because: "Gap: no tool yet for red-team assessment or report export (docs/13, Model Lab)."),
            .exempt("lab.model-download", "Download a model into the library", .write,
                    because: "Gap: Hugging Face and MLX model download has no tool yet (docs/13); Ollama models have models_pull; lab_start_lora takes allow_download for its own base model only."),
            .exempt("lab.edit-training-config", "Edit training configuration and compare runs", .write,
                    because: "Gap: training configuration edits and experiment comparison have no tool yet (docs/13)."),
        ],
        registerTools: { context in
            ModelLibraryTool.register(into: context.registry)
            guard let lab = await context.module(ModelLabModule.identifier, as: ModelLabModule.self) else { return }
            ModelLabAgentTools.register(module: lab, into: context.registry)
        })
}
