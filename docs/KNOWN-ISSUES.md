# Known issues and verification limits

See the [public work-item index](ISSUE-INDEX.md) for scoped issues and acceptance criteria.

This is the contributor-facing gap list for Kiln's current development state. The [issue tracker](https://github.com/noktirnal42/Kiln/issues) owns assignment, discussion, and implementation status. Specifications describe intended behavior; they are not evidence that a feature is complete.

## Develop is a capable editor, not Xcode

**Observed:** Develop → Editor has a language server (Swift and C-family only), build/test/run with schemes, git gutter markers and a split pane (see `docs/11-CURRENT-STATE.md`). It now has a launch debugger backed by LLDB: file/line breakpoints, stepping, stack, locals and console. It now has code folding, ⌘D multi-cursor (add-cursor Return/Tab behaviour is untested) and VoiceOver access to the gutter. It has no debugger attach, conditional breakpoints or watches, no SwiftUI previews, no language server for other languages, and no stage-hunk or blame UI in the editor.

**Verified (2026-11-02):** real Swift programs exercised breakpoints, locals, stepping, restart, launch failure, project switching, and same-named files in separate targets. Build actions preserve unrelated projects' unsaved drafts. Broader debugger workflows remain tracked in #16; remaining editor features in #20. Do not describe Kiln as having Xcode parity.

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

**Observed:** native Mach-O import and inspection work, including a labeled linear disassembly fallback for stripped binaries. Linear listings do not recover function boundaries or establish decompiler parity. Ghidra is optional. Kiln now discovers existing stable installations in user/system Applications (or valid `GHIDRA_HOME`), bundles the export script, and exposes GUI and execution-gated agent analysis through the same service. A real installed Ghidra 12.1.4 / Java 21 run imported and decompiled `/usr/bin/true`, persisted pseudocode, preserved annotations and rejected concurrent analysis. The bundled cipher-classifier data is a placeholder, not a trained classifier.

**Needed:** broader Ghidra version/architecture and complex-binary fixtures; cancellation UI and explicit installation chooser; honest capability states; a licensed, evaluated model and dataset if cipher classification is pursued. Do not label placeholder classification as working.

## Export and model compatibility need broader coverage

GGUF conversion depends on external tooling and is not certified by a successful Core ML or MLX export. Model downloads, tokenizer compatibility, memory limits, adapters, and provider account access can fail independently. Tests should reopen the actual exported artifact in the intended runtime.

## Visual and accessibility QA is incomplete

Layout fixes have addressed pane navigation, embedded Search placement, model-picker loading/search, and clipped analysis tabs. A complete pass still needs narrow/wide windows, light/dark appearance, keyboard focus and shortcuts, VoiceOver labels, long data, and loading/error/empty states across every workspace. Nested sidebars and toolbars need particular attention for cohesion and usable space.

## Composer keys

⏎ sends and ⌘⏎ inserts a newline, confirmed with real keystrokes (Codex session, PR #14 QA). IME composition is not verified (tracked in #8).

## History: composer keys and live streaming were unverified

**Observed:** Return should send and ⌘/⇧/⌥-Return should insert a newline at the caret. A first version crashed (`String.index` out of range in `ComposerView.insertNewline`); the current one uses `NSTextView.insertText`. The user reported an intermediate version moved the caret but not the text after it. Neither was exercised with real keystrokes: the available automation delivers Return as an accessibility value change.

**Needed:** a manual or XCUITest check with real key events, including a caret mid-text, IME composition, and Return while a reply is streaming.

## Time to first byte from some hosted models is very long

**Observed:** NVIDIA NIM `google/gemma-4-31b-it` and `z-ai/glm-5.3-flash` showed no response headers for 25 s to 90 s+ while the endpoint itself answered `/models` in under a second. The UI only shows "Working", then "Still waiting for the model to start responding" after 15 s.

**Mitigation (2026-11-02):** a 90 s first-chunk watchdog in `OpenAICompatibleTransport.stream` now fails with "No response after 90 s… try again or pick another model" instead of waiting for the 180 s transport timeout.

**Still needed:** find out whether this is the provider's queue or a request-shape problem (reasoning fields for NIM), then add a configurable first-token timeout with a clear error and a retry/other-model suggestion.

## Local model store scan is slow on external drives

`UniversalModelStore.installed()` stats every weight file and takes minutes on a USB/HDD store. It no longer blocks other work, but the model picker waits on it and it re-runs on every open. **Mitigation (2026-11-02):** `installedOffPool()` caches the scan for 120 s (invalidated when the store folder changes; Settings reload forces it).

**Still needed:** cache more cleverly, stat lazily, and show store models progressively.

## Standing grants and approval sheet

The Approval Queue sheet now has a Done button and a scrolling grants list; this was checked only by build, not in the running app.

## Test-status notes

A full regression run exercised 456 tests and found one nested-path indexing failure. It was reproduced as `/var` versus `/private/var` aliasing; the root and enumerated paths are now normalized, and the focused indexing recheck passed. A later full run passed all 463 tests; the suite is now 466.

Live tests require compatible providers, credentials, model availability, and sometimes API credits. A listed model may return a payment error even when another model on the same provider works. A command reporting success with zero selected tests is not verification.

The suite was 520 tests and passing on 2026-11-02.

## Latest debugger and Ghidra verification

The 2026-11-02 continuation passed **538 tests in 100 suites**, including one opt-in installed-Ghidra integration test (537 regular tests). See [the QA record](14-DEBUGGER-AND-GHIDRA-QA.md) for scope and remaining limits. A passing app suite does not certify every provider/model, every model-training lifecycle or full Xcode/Ghidra parity.

## Voice and remote control (new, 2026-11-03)

**Voice:** dictation, spoken replies and a hands-free conversation mode are in the Mac composer, but were not tried with a real microphone in QA, replies are spoken only after they finish, and speech output uses system voices. **Remote control:** a candidate completed a physical watch-to-phone-to-Mac voice round trip, and the physical iPhone sent Deny and Allow once decisions to the Mac. The watch also sent one Deny and one Allow once through the iPhone; broader approval and reconnect coverage remains open. All paired devices share one key. An operator-deployed relay completed an encrypted handshake with the real Mac, and a relay-only physical iPhone carried a watch message through it; a previous phone relay reconnect timed out and reliability remains under test. Earlier unexpected standing approvals remain under investigation. See `docs/14-REMOTE-CONTROL.md`.

## Computer use (experimental, 2026-11-03)

Accessibility-based, so it only sees what an app exposes; no screenshots, coordinate clicks, keyboard or scrolling yet. Indices are valid only for the latest `inspect` of one app. Calendar and Messages have been read this way; other apps are untested. Read-only use is safe to automate; `press` and `set_value` act in other apps, so they still ask in Ask and Auto. Pre-existing Accessibility entries from builds signed differently do not apply to a new build.
