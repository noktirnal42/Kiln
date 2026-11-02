# Where Kiln needs help

Kiln's direction is one native workspace where development, inspection, model work, and agents share context. Contributions are most valuable when they complete a real workflow and preserve that cohesion.

Start with the [known issues](KNOWN-ISSUES.md), then pick an [open issue](https://github.com/noktirnal42/Kiln/issues). For larger work, agree on an issue with observable acceptance criteria before implementing it. These are contribution areas, not promises of delivery dates.

| Area | Useful contributions | Evidence of completion |
| --- | --- | --- |
| Native IDE workflows | Source editing, project navigation, diagnostics, build/run/debug integration, unsaved-state handling | Build and debug a real small macOS GUI app; verify file conflicts, shortcuts, and failure states |
| Agent feature coverage | Typed service-backed tools for training, cancellation, evaluation, artifacts, exports, and missing workspace actions | A capability matrix plus tests proving GUI/tool equivalence, approval behavior, cancellation, and audit records |
| Streaming and agent UX | Incremental responses, tool activity, clear progress, retry/reset, responsive Stop | Delayed-chunk regression tests and visible real-provider streaming without duplicate text |
| Swarm correctness | Model compatibility, result verification, task evidence, blocker recovery, durable run history | Real workers use tools, produce expected artifacts, and independently review them; malformed output fails honestly |
| Model Lab | Reproducible datasets, GUI training lifecycle QA, artifact reload/inference, model/export compatibility | Train, save, reopen, evaluate, and export a real artifact; cover cancellation and invalid input |
| Reverse engineering | Ghidra setup, real binary fixtures, function/xref navigation, safer scripts, meaningful findings | Known-answer binaries with recorded engine/tool versions and verifiable outputs |
| macOS design and accessibility | Cohesive panes/toolbars, adaptive width, keyboard focus, VoiceOver, light/dark polish | Running-app screenshots and keyboard/accessibility QA on representative workflows |
| Providers | Catalog accuracy, streaming protocol handling, tool calls, reasoning controls, cancellation/error mapping | Redacted live checks plus deterministic malformed-stream and transport-failure tests |
| Documentation and onboarding | Accurate setup, troubleshooting, tutorials, specification-to-implementation mapping | A fresh contributor follows the instructions successfully without hidden local assumptions |
| Build and release | Reproducible project generation, dependency management, signing/notarization instructions, CI | A clean checkout builds/tests; signing credentials and account-specific configuration remain private |

## Smaller starting points

- Reproduce a documented visual issue at a narrow window size and propose a focused fix.
- Improve an empty/error state so it explains the next useful action.
- Add a synthetic, redistributable fixture that demonstrates a real failure.
- Correct a stale claim in a guide and link to the owning source or observed result.
- Test keyboard navigation or VoiceOver in one complete workflow.
- Expand a provider failure test without requiring a live key.

## Review principles

Keep user-facing claims proportional to the evidence. A demo, a linked runtime, a successful compile, a model's answer, and a verified end-to-end workflow are different things. Document the difference in a PR.

Do not use private binaries, proprietary datasets, secrets, or model weights that cannot be redistributed as public fixtures. Keep downloaded weights and generated build/training output out of Git. Follow [CONTRIBUTING](../CONTRIBUTING.md) and [SECURITY](../SECURITY.md).
