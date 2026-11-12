# Kiln: instructions for coding agents

Start with `docs/HANDOFF-CODEX-2026-11-12.md` (state, todo in priority order, how to build, test and check the UI, pitfalls), then `docs/LEFTOVERS-2026-11-12.md`, `docs/HANDOFF-MODEL-LIBRARY-2026-11-12.md` (the owner's next big feature) and `docs/30-CHAT-MAPS-LAYOUT-PLAN.md`. The 2026-11-10 handoff is older but its build and GUI-check advice still holds.

- `project.yml` is the source of truth (XcodeGen); run `xcodegen generate` after adding files. `Kiln.xcodeproj` is generated and gitignored.
- Never commit `Packages/ModelLabCore/Package.resolved`. Never read, print or enter API keys. Do not push or publish without the owner.
- Every capability needs a service in `Core/`, a GUI surface, an agent tool and MCP tool, an audit record where state changes, and tests (`docs/17-PARITY-AND-BEYOND.md`).
- Tests that use preferences must use `TestDefaults.suite(...)`; run the full suite only when nothing else is building.
- Run `sh Scripts/check-docs.sh` after docs changes. Kiln is source-available (PolyForm Noncommercial), not open source; do not change the licence.
