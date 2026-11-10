<p align="center"><img src="Branding/export/kiln-icon-256.png" width="144" alt="Kiln: a glowing ceramic kiln"></p>
<h1 align="center">Kiln</h1>
<p align="center"><strong>One native Mac workspace. Many ways to make.</strong><br>AI agents · development · reverse engineering · model experimentation · browser, devices and media</p>
<p align="center"><a href="https://github.com/noktirnal42/Kiln/releases">Download the preview</a> · <a href="https://noktirnal42.github.io/Kiln/">Website</a> · <a href="https://github.com/noktirnal42/Kiln/wiki">Wiki</a> · <a href="docs/GETTING-STARTED.md">Get started</a> · <a href="docs/KNOWN-ISSUES.md">Known issues</a> · <a href="https://github.com/noktirnal42/Kiln/issues">Help build it</a></p>
<p align="center"><img src="site/assets/kiln-approval-loop.gif" width="640" alt="Screen recording: Kiln on the Mac stops at an approval gate for a shell command, and the same approval appears in the iPhone companion (iOS Simulator)"><br><sub>Real Kiln 0.1.1 on the Mac; the phone is the iOS Simulator companion answering a real approval. Preview software.</sub></p>
<p align="center"><img alt="Platform: macOS" src="https://img.shields.io/badge/platform-macOS-25231e"> <img alt="Status: preview" src="https://img.shields.io/badge/status-preview-ff9d57"> <img alt="Swift 6 and SwiftUI" src="https://img.shields.io/badge/Swift%206-SwiftUI-c4470d"></p>

Kiln is a native macOS workstation, written in Swift and SwiftUI, where an AI agent and a set of professional tools share one foundation. You converse with a model in one window, and the same agent can read and edit code, take a binary apart, train a small model, browse the web, drive a simulator or process media, with every consequential step passing through approvals and a tamper-evident audit record.

**Kiln is early-stage software.** It has real, verified capabilities and substantial unfinished areas. It does not replace Xcode, Ghidra or a production model platform. This README describes what is built; anything planned is under [Roadmap](#roadmap) and is not claimed as shipped.

## Contents

[What Kiln is](#what-kiln-is) · [Screenshots](#screenshots) · [The ten activities](#the-ten-activities) · [Agent and MCP integration](#agent-and-mcp-integration) · [Providers](#providers) · [Safety model](#safety-model) · [Install](#install) · [Build from source](#build-from-source) · [Documentation](#documentation) · [Roadmap](#roadmap) · [Contributing](#contributing) · [License](#license)

## What Kiln is

- **One window, one conversation.** A sidebar of activities, a project folder the agent works in, and a composer shared by the Agent view and the panel beside every tool.
- **Agents with real tools.** File, shell, Git, reverse-engineering, Model Lab, browser, device, media and (opt-in) computer-use tools run through shared services, policy gates and approvals.
- **Bring your models.** Apple Foundation Models, MLX, Ollama (local and cloud), NVIDIA NIM, OpenRouter and any OpenAI-compatible endpoint, with keys in the macOS Keychain.
- **Supervised by design.** Ask, Auto and Bypass approval modes, a behavior monitor, tripwires and a hash-chained audit log you can verify from the app.
- **Take it with you.** Talk to the agent, hear replies, and approve tool calls from an iPhone or Apple Watch companion (built from source) over an encrypted link.
- **Open.** Specifications, implementation and tests are in this repository.

## Screenshots

<p align="center"><img src="site/assets/shots/agent.jpg" width="720" alt="Kiln's Agent activity: a three-bullet project summary with the last agent run listed as read-only tool calls (list_directory, read_file), the Workstation Agent profile and the Auto permission mode shown in the composer"></p>
<p align="center"><sub>Agent: every tool call of a run is listed, here with the Workstation Agent profile.</sub></p>

<p align="center"><img src="site/assets/shots/audit-chain.png" width="520" alt="The Audit activity's audit chain card: event count, head hash and the Verify now, Export and Refresh buttons"></p>
<p align="center"><sub>Audit: the chain of recorded events can be re-verified on demand.</sub></p>

<p align="center"><img src="site/assets/shots/iphone-approval.png" width="260" alt="Kiln Remote on iPhone showing a pending tool approval with Allow once and Deny buttons"></p>
<p align="center"><sub>Companion: an approval answered from the iPhone app (iOS Simulator capture).</sub></p>

## The ten activities

The sidebar order is also the shortcut order (⌘1 to ⌘9, then ⌘0), and the registry in [`Core/Registry/`](Core/Registry/) is the single place an activity is declared.

| Shortcut | Activity | What it is for | Honest limits |
|---|---|---|---|
| ⌘1 | **Home** | Overview, a get-started checklist, tiles for each activity | Overview only |
| ⌘2 | **Agent** | Chat with a model, with tools; compaction, context meter, voice | Small local models often fail tool use |
| ⌘3 | **Swarm** | Give a goal to a team of agents (planner, parallel workers, blockers, shared bus) | No top-level tool yet to create or cancel a run from the agent |
| ⌘4 | **Develop** | Editor, terminal, Git, search, build/test/run, LLDB launch debugger, MCP servers and the Kiln MCP server | A capable editor, not Xcode: no previews, debugger attach or non-Swift/C language servers |
| ⌘5 | **Analyze** | Reverse engineering: import, strings, Mach-O inspection, Ghidra and radare2 engines, decompiler, xrefs, crypto scan, package downloader | Ghidra is separate software you install; the cipher classifier is a placeholder |
| ⌘6 | **Lab** | Datasets, models, experiments, Create ML and MLX training, LoRA, distillation, evaluation, export | Full GUI lifecycle and export coverage still open |
| ⌘7 | **Audit** | What agents did, and whether the record is intact | Agents cannot yet query the audit record |
| ⌘8 | **Browser** | Tabbed WebKit browser the agent can read and drive | Sign-in, autofill and passkeys are unverified; see [browser authentication](docs/18-BROWSER-AUTHENTICATION.md) |
| ⌘9 | **Devices** | iOS simulators and Android emulators: boot, view, install, launch, logs, record | Apple simulator input is not possible through `simctl`; Windows/Linux is design only |
| ⌘0 | **Media** | Viewer for video, images and audio; text to speech, speech to text, image generation hooks | Image generation needs Apple Image Playground or a configured endpoint (endpoint path unverified) |

Details for each are in the [wiki](https://github.com/noktirnal42/Kiln/wiki) (source in [`docs/wiki/`](docs/wiki/Activities.md)) and on the [website](https://noktirnal42.github.io/Kiln/activities.html).

## Agent and MCP integration

Application services are registered as ordinary tools with a declared permission level (read, write or execute). The in-app agent and Kiln's own MCP server use the same registry and gates.

- **Agent profiles:** Research Assistant (read-only), Coding Agent, and Workstation Agent (adds `re_*`, `lab_*`, `browser_*`, `device_*`, `media_*` and others).
- **Kiln as an MCP server:** Develop → MCP → Start. Loopback only, bearer-token protected, with reads free and everything else waiting for approval in Kiln. External calls are audited as "External: <client>".
- **Kiln as an MCP client:** it reads, never copies, MCP servers and skills already configured for Claude Code, Codex and OpenCode. Each imported server still needs "Approve & Connect".
- **Tool families:** `re_*` (reverse engineering), `lab_*` (Model Lab), `browser_*`, `device_*`, `media_*`, `swarm_*`, Git, search, shell and file tools, `list_skills` / `read_skill`, and opt-in `computer_use`.

The [agent capability matrix](docs/13-AGENT-CAPABILITY-MATRIX.md) lists what is covered and, as importantly, the registry gaps that have no agent tool yet.

## Providers

Chat was verified with real calls against each provider below on 2026-11-01 (see [current state](docs/11-CURRENT-STATE.md)). Provider connectivity is not evidence of reliable agent behavior.

| Provider | Chat | Tool use | Notes |
|---|---|---|---|
| Apple Foundation Models | yes | no | On-device |
| Ollama (local) | yes | yes | Only models the running server knows |
| Ollama Cloud | yes | yes | Some models need paid credits |
| NVIDIA NIM | yes | yes | Some models are slow to first token |
| OpenRouter | yes | yes | Free models come and go |
| Custom endpoint | yes | yes | Any OpenAI-compatible URL |
| MLX (local) | yes | no | Models from the shared Hugging Face cache |

An Apple Private Cloud Compute provider is **in development and untested** (it needs macOS 27, a managed entitlement and a qualifying distribution route); do not assume it works. See [Apple capabilities](docs/20-APPLE-CAPABILITIES.md).

## Safety model

- **Approvals.** Reads run freely. Writes, commands and network calls open an approval sheet. Modes: **Ask** (default), **Auto** (routine, in-project, non-destructive calls only) and **Bypass** (red, confirmed first). A mode answers once, never creates a standing grant, and resets to Ask whenever Kiln launches. "Always Allow" standing grants are made at the Mac and are revocable.
- **Policy and monitoring.** Two policy gates, a behavior monitor and tripwires sit around every agent and swarm tool call.
- **Audit chain.** Agent runs, decisions and tool results are recorded in a tamper-evident hash chain that Audit → Verify now recomputes. Every human or mode answer is logged with how it was given.
- **Not sandboxed.** Since 2026-11-02 Kiln is **not** App Sandboxed, so the agent can run real git, package managers and shells. The hardened runtime and notarization still apply. File tools are confined to the project root, but `run_command` is not: a command can touch anything your user account can. Treat approvals as the boundary.
- **Secrets.** Provider keys live in the Keychain. Browser tools refuse password, card and one-time-code fields; page content is labelled untrusted.
- **Remote control.** Phone and watch can allow once or deny; they cannot grant standing access or change settings. Frames are ChaCha20-Poly1305 encrypted. See [remote control](docs/14-REMOTE-CONTROL.md).

## Install

A Developer ID signed, notarized and stapled **preview** build is on the [Releases page](https://github.com/noktirnal42/Kiln/releases). Read each release's notes for what was and was not verified. It is a preview, not a stable release, and there is no in-app updater: download a new build and replace the app (data lives in `~/Library/Application Support/Kiln`). The iPhone and Apple Watch apps are not in the download; build them from [`Companion/`](Companion/) with your own signing team. The published preview predates some development-branch features (Browser, Devices, Media and the registry); build from source to try them.

## Build from source

Requirements: a Mac, Xcode 27 or newer with matching command-line tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple silicon is recommended (MLX workflows need it). The generated Xcode project is not committed.

```sh
git clone https://github.com/noktirnal42/Kiln.git
cd Kiln
brew install xcodegen  # if needed
xcodegen generate
open Kiln.xcodeproj
```

Select the **Kiln** scheme and your own signing team; `project.yml` is the source of truth and regenerating the project discards Xcode-only edits. To build an unsigned development bundle:

```sh
xcodebuild build -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

```sh
# Non-live regression suite
xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64'
```

Opt-in live QA suites spend provider credits; see [CONTRIBUTING.md](CONTRIBUTING.md). Add API keys only through Settings and never commit them. A [build/run script](script/build_and_run.sh), a [clean-clone walkthrough](docs/GETTING-STARTED.md) and [signing and release notes](docs/RELEASING.md) are included. A clean-checkout build took about six minutes in the walkthrough; first builds download several GB of packages.

**Test status:** the integration branch's last full Mac run was 772 passing tests at commit `15b90a4`, as reported by the maintainers' session; older documents quote earlier counts. A passing suite does not certify every provider, model or workflow.

## Documentation

| Where | What |
|---|---|
| [Website](https://noktirnal42.github.io/Kiln/) | Overview, activities, agent and MCP tools, roadmap |
| [Wiki](https://github.com/noktirnal42/Kiln/wiki) | Task-oriented guides (source in [`docs/wiki/`](docs/wiki/Home.md)) |
| [Current state](docs/11-CURRENT-STATE.md) | What exists, how it was checked, what is open |
| [Known issues](docs/KNOWN-ISSUES.md) | Verification limits and gaps |
| [Agent capability matrix](docs/13-AGENT-CAPABILITY-MATRIX.md) | What agents can and cannot operate |
| [Docs map](docs/DOCS-MAP.md) | Which document is authoritative for what |
| [Specification index](docs/README.md) | Vision, architecture and design specs |

Specifications include future ambitions; they are not feature-completion claims.

## Roadmap

The following is **planned or in parallel development and is not in the current release or integration branch.** Nothing here has been verified in the running app yet. The full list with per-module bars is in [Parity and beyond](docs/17-PARITY-AND-BEYOND.md).

- **Image studio:** a catalog of open image models, resumable downloads into the model store, and engines behind one protocol (in-process on Apple silicon, or an installed Draw Things, ComfyUI or AUTOMATIC1111/Forge); agent and MCP image tools.
- **Agent platform:** slash commands, hooks, memory files, plan mode, checkpoints and rewind, a sessions list, a usage and cost view, and editable permission rules.
- **Develop and Analyze upgrades:** toward an Xcode and Ghidra bar (symbol outline, refactoring, debugger variables and threads, graph view, structure editor, patching, binary diffing).
- **Beyond parity:** evidence ledger and signed run bundles, a Pinboard context tray, saved workflows, closed-loop app analysis, a verifier agent, privacy tiers and local-first routing, and policy as code.
- **Platform work with outside dependencies:** passkeys in the Browser need an Apple entitlement that has been requested and not granted; iCloud sync, push and Private Cloud Compute are not implemented or verified; no dates are promised.

## Contributing

Start with [good first issues](https://github.com/noktirnal42/Kiln/issues?q=is%3Aopen+label%3A%22good+first+issue%22), [help wanted](https://github.com/noktirnal42/Kiln/issues?q=is%3Aopen+label%3A%22help+wanted%22) or the [contribution areas](docs/CONTRIBUTION-AREAS.md). Read [CONTRIBUTING.md](CONTRIBUTING.md) before a pull request: keep changes focused, preserve approval boundaries, and attach evidence (and say what you did not verify). Questions go to [Discussions](https://github.com/noktirnal42/Kiln/discussions); security reports follow [SECURITY.md](SECURITY.md); see [SUPPORT.md](SUPPORT.md) and the [code of conduct](CODE_OF_CONDUCT.md).

Donation account setup is in progress; verified payment links will be added here and on the site when ready.

## License

Kiln is **source-available**, not open source. The source and builds are licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE), copyright FreeRange Labs: free for personal,
hobby, research, educational and charitable use. **Using Kiln for work or for a business needs a
commercial license**: see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md) or write to
freerangelabs@drumnbus.com.

- Releases up to `v0.1.1` were published under MIT and stay MIT for those copies; see [LICENSE-HISTORY.md](LICENSE-HISTORY.md).
- Contributions are accepted under the [contributor agreement](CLA.md).
- The name and logo are not licensed; see [TRADEMARKS.md](TRADEMARKS.md).
- Third-party licenses: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The license does not override the terms of models, datasets or services you use with Kiln.

Respect the licenses and terms of third-party libraries, models, datasets and services; the project's license does not override theirs. Kiln is independent and is not affiliated with Apple, Anthropic, OpenAI or the Ghidra project.
