# Known issues and verification limits

This is the contributor-facing gap list for Kiln's current development state. The [issue tracker](https://github.com/noktirnal42/Kiln/issues) owns assignment, discussion, and implementation status. Specifications describe intended behavior; they are not evidence that a feature is complete.

## Development workspace is not yet a full IDE

**Observed:** Develop exposes terminal, Git, workspace filename search, and MCP panels. It has no source editor and does not provide Xcode-level project, build, debugger, preview, or diagnostics workflows.

**Reproduce:** open Develop and inspect the available tools.

**Needed:** a native editor and coherent project lifecycle, built on shared workspace state. Acceptance should cover opening/editing/saving files, unsaved changes and conflicts, keyboard navigation, diagnostics, and a real build/debug example. Avoid claiming Xcode parity from a text editor or terminal alone.

## Small local model tool use is unreliable

**Observed:** the local `qwen2.5-coder:3b` model can answer plain chat but has failed real tool and swarm fixtures. It has returned simulated function-call JSON, empty output, and incorrect reasoning. The custom OpenAI-compatible route against the same local model has also failed a tool-use fixture. Provider connectivity does not establish model task quality.

**Reproduce:** run the opt-in local swarm fixture or the live provider tool-use scenario on that model. Inspect tool records and produced files, not only the final prose.

**Mitigation:** empty and simulated-call swarm results are blocked instead of reported as completed. A hosted tool-capable model has completed a real read → write → review swarm job. This does not guarantee correctness for arbitrary tasks.

**Needed:** provider/model compatibility coverage, clearer result evidence, and reliable task verification. A pass requires real expected tool execution and validated artifacts; do not loosen approval gates or accept invented results to make a test green.

## Agent access does not cover every GUI feature

**Observed:** agents have file, shell, Git, reverse-engineering, and selected Model Lab tools. Model Lab's existing tools primarily expose hardware, experiment/dataset listings, and model/dataset discovery. Training, lifecycle controls, evaluation/export, and other GUI actions do not all have equivalent service-backed agent actions yet.

**Needed:** a maintained capability matrix and typed, tested tools for missing actions. The GUI and agents should call the same services; writes, execution, network calls, and resource-intensive work must retain applicable approvals, cancellation, and audit behavior. Shell access is not a substitute for complete first-class feature coverage.

## Agent streaming needs visible end-to-end verification

**Observed:** plain chat supports streamed chunks. The agent event model has a text-delta event, but the audited agent turn path accumulated text without emitting it. A fix with regression coverage has since landed; the running GUI has not yet been checked against a real provider.

**Needed:** visible incremental text before the provider finishes, responsive Stop, correct retry/reset behavior, and no duplicated final text. Verify both a deterministic delayed-chunk test and the running GUI with a real provider. Do not equate eventual response delivery with smooth streaming.

## Training works in the standalone runner; GUI lifecycle coverage is incomplete

**Verified:** real from-scratch MLX training saved weights/vocabulary and generated from the artifact. A current-source LoRA smoke run saved an adapter. Those small smoke runs establish execution, not useful model quality.

**Unverified:** the complete GUI flow for every training type, dataset error, cancellation, artifact reload, comparison, inference with the produced model, and export. Model/runtime availability badges are not execution tests.

**Needed:** reproducible datasets and GUI test recipes with expected artifacts, progress, failure, and cancellation behavior. Preserve existing outputs and use unique training artifact paths.

## Reverse-engineering depth depends on external tooling

**Observed:** native Mach-O import and inspection work, including a labeled linear disassembly fallback for stripped binaries. Linear listings do not recover function boundaries or establish decompiler parity. Ghidra is optional and was not configured during this QA pass. The bundled cipher-classifier data is a placeholder, not a trained classifier.

**Needed:** supported Ghidra installation/configuration and real decompilation fixtures; honest capability states; a licensed, evaluated model and dataset if cipher classification is pursued. Do not label placeholder classification as working.

## Export and model compatibility need broader coverage

GGUF conversion depends on external tooling and is not certified by a successful Core ML or MLX export. Model downloads, tokenizer compatibility, memory limits, adapters, and provider account access can fail independently. Tests should reopen the actual exported artifact in the intended runtime.

## Visual and accessibility QA is incomplete

Layout fixes have addressed pane navigation, embedded Search placement, model-picker loading/search, and clipped analysis tabs. A complete pass still needs narrow/wide windows, light/dark appearance, keyboard focus and shortcuts, VoiceOver labels, long data, and loading/error/empty states across every workspace. Nested sidebars and toolbars need particular attention for cohesion and usable space.

## Test-status notes

A full regression run exercised 456 tests and found one nested-path indexing failure. It was reproduced as `/var` versus `/private/var` aliasing; the root and enumerated paths are now normalized, and the focused indexing recheck passed. A later full run passed all 463 tests.

Live tests require compatible providers, credentials, model availability, and sometimes API credits. A listed model may return a payment error even when another model on the same provider works. A command reporting success with zero selected tests is not verification.
