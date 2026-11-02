# Can the agent operate Kiln itself?

Kiln exposes application services as ordinary tools. The Workstation Agent profile can use the registered `re_*` and `lab_*` tools, alongside file, shell, Git and workspace tools. Each tool still passes through policy and approval checks. The external MCP endpoint uses the same registry and gates.

**The agent cannot yet operate every feature in Kiln.** Shell access is not equivalent to a supported, service-backed application action. The table below distinguishes the two.

| Area | Service-backed agent access | Missing application actions |
| --- | --- | --- |
| Workspace files | Read, write, edit, delete, list, glob and grep; workspace path containment | Native editor/navigation selection and unsaved-document handling |
| Development | Run/stream/background commands; Git status, diff, commit, branch, log; file-name search | Source editor, build-target selection, debugger, breakpoints and project settings |
| Reverse engineering | `re_import_binary`, `re_analyze_function`, `re_get_disassembly`, `re_get_decompilation`, `re_search_strings`, `re_get_xrefs`, `re_scan_crypto`, `re_auto_decrypt`, `re_find_gadgets`, `re_carve_formats` | Project selection, annotation editing, scan-rule management, forensics/script workflows and device-bench operations need dedicated adapters |
| Model Lab discovery | Hardware report, experiment/dataset lists, Hugging Face model/dataset search | Dataset import/validation, model download/library registration and deletion |
| Model Lab experiment control | `lab_get_experiment` reads status, recent metrics and artifact ID; `lab_cancel_training` requests cancellation only for the exact running experiment | Experiment creation, training configuration/start, LoRA/distillation start, evaluation, comparison, inference and export |
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

Training start actions should first centralize job construction and dataset validation in a shared Model Lab service. Currently some configuration lives in SwiftUI controls; copying that logic into a tool would make GUI and agent behavior diverge. Resource-intensive jobs also need explicit iteration/model/memory limits and a single-job concurrency policy.

## Current verification

The repository's live QA has exercised file and shell tools, reverse-engineering import/string search, Model Lab hardware reporting over MCP, shared approval gates, and a hosted researcher → implementer → reviewer swarm. Plain chat has answered through Apple Foundation Models, local Ollama, Ollama Cloud, NVIDIA NIM and OpenRouter. A smaller local model has also failed tool-use scenarios; provider connectivity alone does not establish agent reliability.

The new streaming and Model Lab status/cancel adapters have syntax checks and focused regression tests in source. Their runtime test result must be recorded after the integrated Xcode test run completes.
