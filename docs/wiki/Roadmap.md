# Roadmap

Everything below **Built** is planned or in parallel development and is **not shipped**: none of it is in the current release or the integration branch, and none has been seen working in the app. No dates are promised. The tracker is the place for assignments: [issues](https://github.com/noktirnal42/Kiln/issues). The full list with per-module bars is `docs/17-PARITY-AND-BEYOND.md`.

## Built (integration branch)

- Ten activities declared in one registry, with agent tools or a written reason none exists for each capability
- Agent loop with Ask, Auto and Bypass approvals, compaction, audit chain, loopback MCP server and shared tool configuration
- Develop editor with language server, build, test and an LLDB launch debugger
- Analyze (native inspection, optional Ghidra and radare2), Lab (Create ML, MLX), Browser, Devices, Media
- Voice, and iPhone and Apple Watch companions built from source

## In parallel development (not shipped)

- **Image studio.** A catalog of open image models with licenses and token flags, resumable checksum-verified downloads into the model store, and engines behind one protocol (in-process on Apple silicon, or an installed Draw Things, ComfyUI or AUTOMATIC1111/Forge). A missing backend shows a setup state; nothing fake is shown. Agent and MCP tools (`image_*`).
- **Agent platform.** Slash commands, hooks, memory files, plan mode, checkpoints and rewind, a sessions list with worktree isolation, a usage and cost view, per-tool and per-path permission rules.
- **Develop and Analyze upgrades.** Toward an Xcode and Ghidra bar: symbol outline, refactoring, debugger variables and threads, graph view, structures editor, patching, binary diffing.

## Next

Make the foundation dependable (streaming, tool correctness, clear failures); agent tools for the registry gaps (swarm control, audit queries, build and debug, project selection); companion apps that stay reachable in the background; accessibility and narrow-window layouts.

## Horizon (proposals)

Evidence ledger and signed run bundles; Pinboard context tray; saved workflows; closed-loop app analysis; verifier agent; privacy tiers and local-first routing; time-travel workspace; mission control; project knowledge graph; policy as code; agent-driven QA.

## Waiting on others

Browser passkeys need an Apple entitlement that has been requested but not granted. iCloud sync, push for new features and Private Cloud Compute are not verified in any build. Windows and Linux guests in Devices are a design only.

## Definition of done

A service, a GUI, an agent tool and MCP tool, a palette entry, an audit record, tests, and a screenshot of it working in the app recorded under `docs/qa/`.

---

**Verified status.** Items are copied from `docs/17-PARITY-AND-BEYOND.md`, `docs/20-APPLE-CAPABILITIES.md` and `docs/18-BROWSER-AUTHENTICATION.md`; the "in parallel" list reflects what other work sessions were doing when this page was written and may have moved. **Not checked:** the state of those parallel branches; check the tracker before relying on any of it.
