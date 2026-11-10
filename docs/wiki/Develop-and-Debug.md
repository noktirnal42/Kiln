# Develop and Debug

**Develop** (⌘4) has Editor, Terminal, Git, Search and MCP tabs.

## Editor

- File navigator (new, rename, trash), Find in Project, Changes list with discard, tabs and a split pane, drag-reorder tabs.
- Native text editing: system undo, find bar, line numbers, auto-indent, syntax colouring, bracket matching, soft wrap, code folding (⌘⌥[ and ⌘⌥]), multi-cursor (⌘D).
- Open Quickly (⌘P), go to line (⌘L), save (⌘S, ⇧⌘S). Unsaved edits survive switching tools; recovery copies are offered back; quitting with unsaved edits asks.
- Files changed on disk by an agent, Git or another editor reload when clean and raise a Reload / Keep mine / Overwrite banner when edited. Binary, over-2 MB and unreadable files are refused with a reason.
- Git gutter markers against HEAD, with Revert Change at the caret.
- VoiceOver can read the gutter (breakpoints, folds, diff and execution markers).

## Language server

sourcekit-lsp for Swift and C-family files: live diagnostics as underlines and in Problems, ⌘-click go to definition, ⌥Esc completion. It degrades to nothing when `xcrun sourcekit-lsp` is unavailable.

## Build, Test, Run

⌘B, ⌘U, ⌘R with scheme and configuration pickers (from `xcodebuild -list` / `swift package describe`, remembered per project), streamed output, `file:line:col: error:` lines and Swift Testing issues as clickable problems, a test list with "Run only this test", and Run for packages and Xcode apps. "Ask the agent to fix the errors" drafts a prompt.

## Debugger

Debug (⌥⌘R) builds the selected target and launches it under LLDB. Toggle file and line breakpoints from the gutter or at the caret (⌘\); continue, pause, step over, into and out; inspect the stack and locals; read program output. Breakpoints persist per project. In narrow panes the debugger shows Stack, Variables and Console tabs.

## Not in Kiln

Debugger attach, conditional breakpoints and watches, SwiftUI previews, language services for languages other than Swift and C-family, and stage-hunk or blame UI. Do not expect Xcode parity.

## Terminal, Git and Search

An embedded terminal, Git status, diff, commit and branch views, and workspace search. The agent has Git, search and shell tools; the agent cannot yet build, test or debug through a dedicated tool (it can run `xcodebuild` through `run_command`).

## MCP tab

Start Kiln's MCP server, manage imported servers, and pair companion devices: see [[MCP Server and Tools]].

---

**Verified status.** Real Swift programs exercised breakpoints, locals, stepping, restart, launch failure, project switching and same-named files on 2026-11-02; folding was checked in the running app. 538 tests then passed, including an installed-Ghidra test. **Not checked:** ⌘D add-cursor Return and Tab behavior, completion quality across large projects, and the debugger on apps other than the verified samples.
