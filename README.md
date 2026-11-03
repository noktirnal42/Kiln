<p align="center"><img src="Branding/export/kiln-icon-256.png" width="144" alt="Kiln — a glowing ceramic kiln"></p>
<h1 align="center">Kiln</h1>
<p align="center"><strong>One native Mac workspace. Many ways to make.</strong><br>AI agents · development tools · reverse engineering · model experimentation</p>
<p align="center"><a href="https://noktirnal42.github.io/Kiln/">Project website</a> · <a href="https://noktirnal42.github.io/Kiln/docs.html">Get started</a> · <a href="docs/KNOWN-ISSUES.md">Known issues</a> · <a href="https://github.com/noktirnal42/Kiln/issues">Help build it</a></p>
<p align="center"><a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-d8b38a"></a> <img alt="Platform: macOS" src="https://img.shields.io/badge/platform-macOS-25231e"> <img alt="Status: experimental" src="https://img.shields.io/badge/status-experimental-e89b61"></p>

Kiln is an open-source Swift and SwiftUI workstation exploring what happens when conversation, tools, binary analysis, and model creation share a common foundation. Move between disciplines while keeping project context, agent activity, approvals, and audit evidence close to the work.

**This is an ambitious early-stage project.** It has real working capabilities and substantial unfinished areas. It does not yet replace Xcode, Ghidra, or a production model platform. We welcome contributors who want to help close those gaps with reproducible evidence.

## Why Kiln?

- **Bring your models.** Local and hosted providers share a native conversation interface. Use the services and hardware that suit your work.
- **Move across disciplines.** Terminal, Git, workspace search, reverse engineering, and Model Lab live within the same app.
- **Give agents real tools.** File, shell, Git, RE, and selected Lab actions use shared services with policy checks, approvals, and audit records. A loopback MCP server lets external clients use supported actions too.
- **Talk to it, and take it with you.** Dictate to the model, hear replies read aloud, or hold a hands-free spoken conversation. Pair an iPhone or Apple Watch to read the conversation, speak to the agent and approve its tool calls from across the room.
- **Build in the open.** Read the specifications, inspect the implementation, reproduce the tests, and help shape the roadmap. MIT licensed.

## What exists today

> Current state (2026-11-03): see [`docs/11-CURRENT-STATE.md`](docs/11-CURRENT-STATE.md) for what was verified, how to
> build/sign/notarize, and what is still open. The full suite (538 tests) passes.

| Area | Working foundation | Important limits |
|---|---|---|
| Chat | Local/hosted providers, streaming, conversation history, Markdown, artifacts | Provider and model behavior varies; visible streaming/latency QA continues |
| Agent & swarm | Tool orchestration, role-based workers, dependencies, approvals, audit chain | Small-model tool use can fail; task correctness requires evidence |
| Develop | Source editor with Swift/C language server, build/test/run, LLDB launch debugger, folding, multi-cursor, Git gutter, terminal, search, MCP tools | Not Xcode: no previews, debugger attach or other language servers |
| Analyze | Binary import, strings, native Mach-O inspection/disassembly, analysis tools | Ghidra recovery requires setup; cipher classifier is a placeholder |
| Model Lab | Datasets/models, experiments, Create ML and MLX engines, evaluation, LoRA and distillation (also as agent tools) | Full GUI lifecycle/export compatibility coverage remains open |
| Voice | Dictation, spoken replies, hands-free conversation mode | Not yet tried with a real microphone in QA; replies are spoken after they finish |
| Remote control | Encrypted remote protocol and iPhone / Apple Watch companion projects (`Companion/`); optional relay software (`Relay/`) | A candidate completed one physical watch voice round trip via iPhone; approvals and real-Mac relay remain unverified |

**Real QA examples:** the app’s chat layer received correct live responses across five configured providers; a hosted agent created and ran a program; a researcher → implementer → reviewer swarm produced a real summary artifact; MLX from-scratch and LoRA smoke runs saved artifacts. These establish specific workflows, not universal reliability. See the [verification record](docs/12-USER-QA-2026-11-01.md) and [current state](docs/11-CURRENT-STATE.md) for evidence and limits.

## Build from source

Requirements: a Mac, Xcode 27 or newer with matching command-line tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple silicon is recommended for MLX. The generated Xcode project is intentionally not committed.

```sh
git clone https://github.com/noktirnal42/Kiln.git
cd Kiln
brew install xcodegen  # if needed
xcodegen generate
open Kiln.xcodeproj
```

Select the **Kiln** scheme. Use your own signing team for development; `project.yml` is the source of truth and regenerating the project overwrites Xcode-only setting edits. To build a local unsigned development bundle explicitly:

```sh
xcodebuild build -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

The first build compiles substantial Swift/Metal dependencies. Leave adequate free disk space and avoid concurrent builds in the same DerivedData folder. Model downloads and provider accounts are optional and configured separately. Add API keys through Settings; never commit them.

```sh
# Non-live regression suite
xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64'

# Opt-in live QA: uses configured providers and may spend API credits
TEST_RUNNER_KILN_LIVE=1 xcodebuild test \
  -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS,arch=arm64' \
  -only-testing:KilnTests/LiveQATests
```

A reproducible [build/run script](script/build_and_run.sh) and detailed [setup and verification notes](docs/11-CURRENT-STATE.md) are included. Stable signed downloads will be advertised only after a verified release is published.

## Where we need help

Start with [good first issues](https://github.com/noktirnal42/Kiln/issues?q=is%3Aopen+label%3A%22good+first+issue%22), [help wanted](https://github.com/noktirnal42/Kiln/issues?q=is%3Aopen+label%3A%22help+wanted%22), or the [contribution-area guide](docs/CONTRIBUTION-AREAS.md).

The most useful work includes native editing/project workflows; agent access to missing app features; streaming and first-token responsiveness; model-specific tool reliability; real GUI training/export fixtures; Ghidra integration; accessibility; and documentation verified on a clean Mac.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before a pull request. Reports, designs, documentation, testing, and thoughtful reviews are welcome alongside code. Please keep changes focused, preserve approval boundaries, and attach evidence for the behavior you changed.

## Documentation & community

- [Support and troubleshooting](SUPPORT.md) · [ask a question](https://github.com/noktirnal42/Kiln/discussions)
- [Known issues](docs/KNOWN-ISSUES.md) · [work-item index](docs/ISSUE-INDEX.md) · [public issue tracker](https://github.com/noktirnal42/Kiln/issues)
- [Agent capability matrix](docs/13-AGENT-CAPABILITY-MATRIX.md) · [Remote control and companion apps](docs/14-REMOTE-CONTROL.md)
- [Product vision](docs/00-MASTER-SPEC.md) · [architecture](docs/10-LAYERED-ARCHITECTURE.md) · [roadmap](docs/08-ROADMAP.md)
- [Specification index](docs/README.md) · [implementation history](docs/IMPLEMENTATION-HISTORY.md)
- [Security reporting](SECURITY.md) · [code of conduct](CODE_OF_CONDUCT.md)

Specifications include future ambitions; they are not feature-completion claims. The issue tracker is the place for current assignments, reproduction details, and acceptance criteria.

## Support the project

Contributions and donations can help sustain development, test hardware, provider testing, and documentation. Donation account setup is in progress; verified public payment links will be added here and on the site when ready. Until then, a useful issue, a focused pull request, a review, or sharing the project helps.

## License and attribution

[MIT](LICENSE). Respect the licenses and terms of third-party libraries, models, datasets, and services; the project’s license does not override theirs. Kiln is independent and is not affiliated with Apple, Anthropic, OpenAI, or the Ghidra project.
