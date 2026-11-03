# Can the agent operate Kiln itself?

Kiln exposes application services as ordinary tools. The Workstation Agent profile can use the registered `re_*` and `lab_*` tools, alongside file, shell, Git and workspace tools. Each tool still passes through policy and approval checks. The external MCP endpoint uses the same registry and gates.

**The agent cannot yet operate every feature in Kiln.** Shell access is not equivalent to a supported, service-backed application action. The table below distinguishes the two.

| Area | Service-backed agent access | Missing application actions |
| --- | --- | --- |
| Workspace files | Read, write, edit, delete, list, glob and grep; workspace path containment. Files the agent changes appear in the Editor within about two seconds (clean tabs reload; tabs with unsaved edits raise a conflict banner) | Opening a file in the editor at a line from an agent action; agent-edit review (accept/reject hunks) |
| Development | Run/stream/background commands; Git status, diff, commit, branch, log; file-name search | GUI editor navigation, build-target selection, debugger launch/step/breakpoint service adapters and project settings |
| Reverse engineering | `re_import_binary`, `re_analyze_binary` (installed Ghidra; execution approval), `re_analyze_function`, `re_get_disassembly`, `re_get_decompilation`, `re_search_strings`, `re_get_xrefs`, `re_scan_crypto`, `re_auto_decrypt`, `re_find_gadgets`, `re_carve_formats` | Project selection, annotation editing, scan-rule management, forensics/script workflows and device-bench operations need dedicated adapters |
| Model Lab discovery | Hardware report, experiment/dataset lists, Hugging Face model/dataset search; `lab_import_dataset` (local CSV/TSV/JSON/JSONL/TXT or image folder → dataset library, same service as the GUI import) | Model download/library registration and deletion |
| Model Lab experiment control | `lab_get_experiment` reads status, recent metrics and artifact ID; `lab_cancel_training` requests cancellation only for the exact running experiment; `lab_start_training` starts an existing Create ML classifier through shared GUI/job validation; `lab_create_experiment` (draft text/tabular classifier over a registered dataset, columns validated), `lab_predict` (run a trained Create ML text classifier over inputs), `lab_evaluate_predictions` (accuracy/F1/BLEU/ROUGE, same runner as the Evaluation tab), `lab_export_model` (Core ML / MLX package into an existing folder, never overwriting) | `lab_start_small_lm` (create + start a from-scratch character-level language model over a text dataset, bounded); `lab_start_lora` (MLX LoRA over a txt/jsonl dataset; the base model must already be cached, otherwise the call fails without downloading until the user agrees and `allow_download=true` is passed; run end to end in the installed app: SmolLM-135M, 20 iterations, completed after approval); `lab_start_distillation` (teacher "apple" or a cached MLX repo answers seed prompts, then a LoRA student trains on the answers; same download policy for teacher and student; implemented and unit-tested, not yet run end to end); `lab_create_experiment` also accepts `image_classification` over an imported image folder (untested with a real image set) | Training configuration edits, experiment comparison |
| Swarm | Workers use team messaging, shared memory and blocker tools | No ordinary top-level tool yet to create, inspect or cancel another swarm run |
| Chat and artifacts | Shared model registry and tool-run loop underpin chat | Conversation management, artifact creation/rendering/export and provider configuration need explicit tools |
| Audit and approvals | Every agent run records decisions and tool results; writes and execution can require approval | Agent-facing audit queries and verification tools are missing; agents must never approve themselves or alter the approval policy |

## Streaming behavior

Plain chat updates `ChatSession.streamingText` for each provider delta. Agent mode now emits `textDelta` events while its provider stream is still open, instead of waiting for a complete turn. Partial output is cleared when a transient failure triggers a retry, and when a text-only reply is recognized as a tool call. The final persisted response continues to use the completed, redacted turn.

Streaming redaction is heuristic. The accumulated visible text is rechecked as chunks arrive; a previously emitted prefix is replaced if a split secret becomes recognizable. This is not a guarantee that an incomplete secret fragment is never briefly visible. Text content is not written to the audit log.

## Extension contract

A new application action should:

1. Call the same service used by the GUI, rather than drive private view state or simulate clicks.
2. Declare its read/write/execute permission and consequences before registration.
3. Accept stable IDs and bounded parameters; reject missing or ambiguous targets.
4. Return structured status and artifact IDs, including partial, blocked and failed outcomes.
5. Preserve cancellation and report cancellation as requested until the coordinator reaches its final state.
6. Include behavior tests for the real service boundary, permissions and failure handling.

Create ML classifier job construction and dataset validation now live in `ModelLabModule.classifierTrainingJob`, used by both the GUI and `lab_start_training`. The action targets an exact existing draft/failed/cancelled experiment, permits only a local library-contained dataset, validates saved settings, writes a unique artifact, and refuses to start while any training coordinator is active. It reports that training has started, not that it has succeeded; use `lab_get_experiment` to follow the outcome. LoRA/distillation and other start actions still need shared configuration builders and explicit resource limits.

## Current verification

The repository's live QA has exercised file and shell tools, reverse-engineering import/string search, Model Lab hardware reporting over MCP, shared approval gates, and a hosted researcher → implementer → reviewer swarm. Plain chat has answered through Apple Foundation Models, local Ollama, Ollama Cloud, NVIDIA NIM and OpenRouter. A smaller local model has also failed tool-use scenarios; provider connectivity alone does not establish agent reliability.

The new streaming and Model Lab status/cancel adapters have syntax checks and focused regression tests in source. Their runtime test result must be recorded after the integrated Xcode test run completes.

## Classifier training start (2026-11-02)

The `lab_start_training` adapter uses the same `startClassifierExperiment` service as the GUI's Create ML button. It accepts only an experiment ID, so it cannot replace the saved dataset or hyperparameters in the tool call. Starting a job is execution-gated, and only one training coordinator may be active. Completed experiments must be preserved by creating a new experiment rather than restarting them in place.

Six focused regression tests passed for the status/cancel/start tool contracts and classifier job validation, including path traversal, symlink escapes, missing datasets, invalid fractions and unique output paths. This verifies construction and failure handling; a real agent-driven classifier lifecycle through training completion, artifact reload and GUI inspection still requires an end-to-end check. LoRA/distillation start and the remaining lifecycle adapters remain open work; experiment creation, prediction, evaluation and export are described below.

## Dataset → training → evaluation → export, driven by the agent (2026-11-02)

A hosted model (Ollama Cloud `gemma4:31b`, Workstation Agent profile, Kiln Debug build from this commit range) ran the whole lifecycle with `lab_*` tools only: `lab_import_dataset` on a 120-row two-class CSV → `lab_create_experiment` (text classification, `text` → `label`) → `lab_start_training` → `lab_get_experiment` (validation accuracy 1.0) → `lab_export_model` (core_ml) → `lab_evaluate_predictions`. The exported `.mlmodel` was then compiled with `coremlcompiler` and loaded with CoreML outside Kiln, where it classified "Absolutely wonderful, I love it" as positive and "Terrible, a total waste of money" as negative. A first export attempt failed because the tool took a *file* destination while the exporter copies into a *folder*; the tool now takes `destination_folder` and says so. The dataset and experiment remain in the Model Lab library as QA data.

## Small language model from scratch, driven by the agent (2026-11-02)

With `lab_import_dataset` → `lab_start_small_lm` (100 iterations, 64 dimensions, 2 layers over an 11 KB text corpus) → `lab_get_experiment`, a hosted model (Ollama Cloud `gemma4:31b`, Workstation Agent) trained a small transformer on this Mac's GPU to completion (final training loss 0.493, artifact registered). The GUI and the tool build the job through the same `ModelLabModule.smallLMJob` and validator. `lab_start_lora` now exists behind a download policy (`ModelDownloadPolicy`: valid `org/name`, cached or explicitly allowed); `lab_start_distillation` uses the same policy for its teacher ("apple" or a cached MLX repo) and student.
