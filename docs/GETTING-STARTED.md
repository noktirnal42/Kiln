# Getting started: from a clean clone to your first contribution

This walkthrough was followed on a clean checkout of `https://github.com/noktirnal42/Kiln.git` (commit `0635855`, 2026-11-02) in a fresh directory with
no signing team configured. Nothing below depends on the maintainer's machine, paths or signing identity.

## 1. What was used

| | |
|---|---|
| macOS | 27.0.1 (deployment target is macOS 15) |
| Xcode | 27.1 (`xcodeVersion` in `project.yml` is `2710`; an older Xcode may not open the project) |
| Swift | 6.4 |
| XcodeGen | 2.46.0 (`brew install xcodegen`) |
| Hardware | Apple silicon. Intel is not covered by the MLX workflows. |
| Signing | None: `CODE_SIGNING_ALLOWED=NO`. No Apple Developer account is needed to build or run the tests. |

## 2. Build

```sh
git clone https://github.com/noktirnal42/Kiln.git
cd Kiln
xcodegen generate            # creates Kiln.xcodeproj (gitignored)
xcodebuild -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

Observed: project generation about a second; **`** BUILD SUCCEEDED **` in 6 minutes 3 seconds** from nothing, including resolving and compiling the Swift packages
(mlx-swift, SwiftTerm and others) with `-jobs 2`. The first build downloads packages; it needs the network and several GB of disk. Run one build at a time.

To run the app locally, either open `Kiln.xcodeproj` in Xcode, pick your own team under Signing & Capabilities for the *Kiln* target (never commit that change; `project.yml`
is the source of truth and regenerating the project discards it), and press Run — or launch the product from DerivedData after the build above.

## 3. Test

```sh
xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 CODE_SIGNING_ALLOWED=NO
```

Observed on the clean checkout: `** TEST SUCCEEDED **`. Live-provider suites (`TEST_RUNNER_KILN_LIVE=1`) stay off unless you ask for them. A green command is not enough on its own:
confirm the suite you care about ran (search the log for its name).

## 4. Optional: providers, without a paid account

Kiln needs no provider to start. For a first chat pick **Apple Foundation Model** (on-device, if Apple Intelligence is available) or **Ollama** (`brew install ollama`,
`ollama pull qwen2.5-coder:3b`, `ollama serve`). Hosted providers (NVIDIA NIM, OpenRouter, Ollama Cloud) have free tiers; paste a key in **Settings → Providers** — it is stored in the
Keychain. Never put a key in source, a fixture, a screenshot or an issue. Small local models can chat but often fail tool use; see `docs/KNOWN-ISSUES.md`.

## 5. A first contribution, end to end

1. Pick an issue labelled `good first issue` or `help wanted`, or a bounded item from `docs/CONTRIBUTION-AREAS.md`. Comment on it so work isn't duplicated.
2. `git switch -c fix/<short-name>`.
3. Make the smallest change that does the job, with a test beside it (`Tests/`). Pure logic is the easiest place to start: `Core/Editor` (diff, diagnostics parsing, highlighting),
   `Core/Integrations` (tool-source importers) and their tests in `Tests/AgentTests/EditorTests.swift` and `ToolSourceImporterTests.swift` show the pattern.
4. Verify just that area first, then everything:
   ```sh
   xcodebuild test -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS,arch=arm64' \
     -only-testing:KilnTests/LineDiffTests CODE_SIGNING_ALLOWED=NO
   ```
5. For anything visible, run the app and look: narrow and wide windows, light and dark, keyboard only. Attach a screenshot without personal paths or keys.
6. `git push` your branch and open a pull request that says what you verified (mocks, a real provider, the GUI) and what you did not. Follow `CONTRIBUTING.md` for the rest.

## 6. Where things live

`Core/` services and agent tools · `Modules/` feature modules (Chat, Model Lab, Reverse Engineering) · `UI/Workstation/` the window, sidebar and Develop tools ·
`Packages/ModelLabCore` the training engine · `docs/11-CURRENT-STATE.md` what exists and how it was checked · `docs/RELEASING.md` signing, notarization and packaging.
