# Getting Started

Two ways in: download the preview, or build from source.

## Option 1: the preview download

1. Open the [Releases page](https://github.com/noktirnal42/Kiln/releases) and download the latest preview.
2. The build is Developer ID signed, notarized and stapled. Check the checksum with `shasum -a 256 -c` against the published `.sha256` file.
3. Move Kiln to Applications and open it. There is no in-app updater; to update, download a newer build and replace the app. Your data lives in `~/Library/Application Support/Kiln`, so nothing is lost.

The published preview (0.1.1) is far behind the current source: it predates Maps, News, Images, Mail through GitHub, on-demand tool loading and most of the interface work. Build from source to try them. The iPhone and Apple Watch apps are not in the download; see [[Building and Signing]].

## Option 2: build from source

Requirements: a Mac, Xcode 27 or newer with command-line tools, and XcodeGen. Apple silicon is recommended; the MLX workflows do not cover Intel.

```sh
git clone https://github.com/noktirnal42/Kiln.git
cd Kiln
brew install xcodegen
xcodegen generate
xcodebuild -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

A clean checkout built in about six minutes with `-jobs 2` in the walkthrough, including several GB of package downloads. Run one build at a time.

## First run

Kiln needs no provider to start, but a chat needs a model. The Home activity shows a *Get started* checklist: connect a model, choose a project folder, run a first supervised task.

1. **Connect a model** (see [[Providers and Keys]]). Quickest options: Apple Foundation Models (on-device, if Apple Intelligence is available) or Ollama (`brew install ollama`, `ollama pull qwen2.5-coder:3b`, `ollama serve`). Small local models can chat but often fail tool use.
2. **Choose a project folder.** The project is the folder the agent works in. File tools stay inside it.
3. **Ask for something small** in the Agent activity, with the Workstation Agent profile. Reads run freely; the first write or command opens an approval sheet. Read [[Agent and Approvals]] before switching to Auto or Bypass.

## Moving around

The toolbar opens Chat, Code, Browser, Maps and Devices; the Work menu lists the other activities, and Home shows a card for each, grouped as Work, Communication, and Files and knowledge. Shortcuts follow registry order: ⌘1 Home, ⌘2 Agent, ⌘3 Swarm, ⌘4 Develop, ⌘5 Analyze, ⌘6 Lab, ⌘7 Audit, ⌘8 Browser, ⌘9 Devices, ⌘0 Media; the other eleven activities have no shortcut. ⌘K opens the command palette (type "Mail" and Go to Mail comes first) and ⌘, opens Settings. A packaged preview can have a different layout. See [[Activities]].

---

**Verified status.** The build command and walkthrough follow `docs/GETTING-STARTED.md`, which was followed on a clean checkout (503 tests then; the suite has more than 1,000 now) with no signing team. Shortcut order comes from the registry code and its test. **Not checked:** the preview download steps on a fresh Mac in this documentation pass, and Intel Macs.
