# Debugger and installed Ghidra QA — 2026-11-02

This continuation started from `fea67fa` and preserved Claude's unfinished editor/debugger changes. The first inherited build failed on a mismatched editor-view brace. It was repaired before runtime testing.

## Verified behavior

- LLDB launches a real Swift executable, hits a source breakpoint, reports `n = 20` and `doubled = 40`, steps to the next line, and finishes with `result: 41` and exit code 0.
- Multiple breakpoints retain their correct LLDB IDs when one is removed. Repeated sessions cannot be overwritten by callbacks from the previous LLDB process. Missing programs fail rather than staying at Starting.
- Full source paths identify the correct file when two targets contain `Logic.swift`. POSIX path normalization handles `/var` and `/private/var` aliases; debugger navigation reuses an open document instead of opening a duplicate.
- Project switching stops the previous debugger. Preparing a build saves current-project files and leaves unrelated unsaved drafts untouched.
- Ghidra discovery prefers a valid `GHIDRA_HOME`, otherwise the highest stable release in user/system Applications. The export script is bundled with Kiln.
- The actual `re_analyze_binary` service ran installed Ghidra 12.1.4 with Java 21 on an imported `/usr/bin/true`. It returned one recovered function with nonempty pseudocode and assembly, persisted the project with an incremented revision, retained annotations, retained binary identity, and rejected a concurrent analysis request. The target binary was never executed.
- Separate store tests verify analyst signature overrides survive reanalysis while the recovered engine signature advances.

## Reproduce the app checks

Use Xcode 27.1 on macOS with Xcode's command-line tools selected. `project.yml` is authoritative:

```sh
xcodegen generate
xcodebuild test -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS' -jobs 2 \
  -only-testing:KilnTests/DebugSessionTests
```

For the installed-engine test, first provide a working Ghidra installation and its required JDK, then run:

```sh
TEST_RUNNER_KILN_LIVE_GHIDRA=1 xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS' -jobs 2 \
  -only-testing:KilnTests/GhidraInstallationTests \
  -only-testing:KilnTests/REAgentToolsTests \
  -only-testing:KilnTests/LiveGhidraTests
```

The integrated full app run passed **538 tests in 100 suites**: 537 regular tests and the opt-in live Ghidra test. The new debugger fixture tests build their own disposable Swift packages. Live hosted-provider and training suites remain separately opt-in; this run does not claim those all passed again.

## Limits and contribution opportunities

The debugger currently launches local built executables. Attach, conditional breakpoints, watches, remote/device debugging and SwiftUI previews remain separate work. Shell execution and a GUI debugger do not make every debugger action available to the chat agent.

The Ghidra fixture establishes a real service boundary and persisted decompilation, not complex-binary parity with Ghidra's full application. Broader binaries, architectures, version compatibility, cancellation UI and an explicit installation chooser need coverage. The cipher classifier remains a placeholder.

The GUI pass uses a separately signed local QA bundle and a disposable project. It preserves recovered edits from the normal application profile. The development build is distinct from a notarized public release; it has not been published as a release artifact.
