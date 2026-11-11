# Chat parity, Maps parity and one cohesive layout (plan, 2026-11-10)

Three requests from the owner: (1) the chat at parity with Claude and Codex, (2) Maps at parity with Apple Maps, (3) a rethought layout that feels like
one product (Swarm folded into the chat), better than Claude Code Desktop and the Codex app. Everything here is a plan, not a claim. Status words:
**have** (seen working), **partial**, **missing**. See `17-PARITY-AND-BEYOND.md` for the older platform table; this file supersedes its chat rows.

## 1. The layout idea: chat is the spine, tools are panes beside it

Today every activity is a full screen that replaces the chat, and the chat reappears as a narrow dock (hidden below 1240 pt). Swarm is a separate screen
with its own goal box. That is why it feels like eleven apps.

Proposal ("Thread + Canvas"):

- **One window, one thread list, one spine.** The sidebar lists projects and their threads (pinned, recent, archived). New activity entries become
  *surfaces* opened from a thread, not destinations that leave it.
- **Canvas.** A right-hand tabbed pane (resizable, 40-70% of the window) hosts surfaces: Editor, Terminal, Git/Diff review, Browser, Analyze, Maps, Media,
  Images, Devices, Lab. The agent opens surfaces itself (`ide_open`, `browser_open`, `media_open`, `re_*`) and they appear as tabs, like Artifacts in Claude and the
  review pane in Codex. "Full screen" (⌃⌘F on a tab) keeps today's deep-work screens for Develop and Analyze.
- **Swarm becomes a thread feature.** When the planner or the agent spawns workers, the thread shows a **Team card** (live rows: worker, task, status, cost, last
  tool call; click a row to open that worker's transcript in the canvas). Mission control (running agents, downloads, trainings, devices, approvals) is one popover
  on the status strip. The goal box on the Swarm screen goes away; `/swarm <goal>` and a composer "Team" toggle replace it. Same `swarm_*` tools, same MCP.
- **One composer everywhere.** Model, effort, mode (Ask/Auto/Plan), profile, attachments, context meter in one bar; no second copy in a dock.
- **One header language** (done in part: `SSActivityHeader`, `SSPaneHeader`, `SSEmptyState`, `SSMasterDetail`); add `SSInspector`, `SSTabBar` (document tabs with
  close and drag), `SSCard` (thread cards: Team, Plan, Diff, Approval, Download) so cards look the same everywhere.
- **Better than Claude and Codex because everything shares context:** pin a function, a page selection, a device frame, a map region or a dataset slice into
  the next message (Pinboard); one approvals inbox across modules; one timeline of what the agent did across tools (with rewind).

Cost: large. Order matters: composer and thread first (no layout change), then Canvas host, then move one activity at a time into it (Browser, Media, Maps are
the easiest; Develop and Analyze keep a full-screen mode). Each step ships behind the old layout until the next is ready.

## 2. Chat parity table (Claude Code Desktop, Codex app)

| Area | Status | Gap |
|---|---|---|
| Streaming markdown, reasoning block, tool-call groups, copy/regenerate/fork/delete | have | Syntax-highlighted code blocks with Copy / Open in Editor; tables and math; edit-and-resubmit a user message |
| Plan mode with approve/edit/reject; checkpoints and rewind; slash commands; memory; hooks; sessions; usage; schedules | have (seen 2026-11-10) | Palette entries exist; add inline `/` help card |
| Attachments: images, PDFs, files; paste and drag and drop | **missing** | Composer chips, thumbnail strip, vision to capable models, `@file` and `@folder` pickers with fuzzy search, `@symbol`, `@page`, `@device` |
| Diff review: accept/reject hunks, comment on a line, send comments back | partial (Git tab) | Diff card in the thread after each edit; review pane in the canvas; "apply" and "revert" per file |
| Task list / todo panel the agent maintains | **missing** | `todo_write` tool, card pinned above the composer, shown in the Team card |
| Queue the next message while a run is going; interrupt with guidance | **missing** (send is blocked while streaming) | Queue chips, "steer" message injected at the next step |
| Parallel threads and background runs | partial (sessions list; only the open thread runs) | Runs continue in the background; Dock badge and notification (partly there); per-thread worktree |
| Subagents shown in the thread | partial (swarm separate) | Team card (section 1) |
| Thread management: rename, pin, archive, search across threads, folders by project | partial (auto-title, delete) | Sidebar search, pin, archive, rename, project grouping |
| Git/PR flow: branch, commit message, PR, CI status, review comments | partial | `gh`-backed PR card and tools, CI chip in the status strip |
| Model/effort quick menu, per-thread profile, fast/slow toggle | partial (picker, profile menu) | One compact menu in the composer |
| Citations: file:line links open the editor at the line; URLs open the Browser surface | partial | Link handler for `path:line` in markdown |
| Inline images and media in replies (generated images, screenshots, maps) | partial | Render `image_generate`, `device_screenshot`, `browser_screenshot`, map snapshots as thread cards |
| Voice | partial | Push-to-talk, streaming speech |
| Keyboard: ⌘K palette, ⌘N, ⌘⇧[ ] threads, ⌘/ focus composer, ↑ edit last message, Esc to interrupt | partial | Full set and a shortcuts sheet |
| Notifications, approvals inbox | partial | Done for Dock badge; add inbox and per-thread status dots |

Suggested order: attachments and `@` mentions, diff card, todo card, queue and steer, thread management, Team card, background runs, PR flow.

**Built so far (2026-11-10, commit `91a78bf`, unit-tested, seen working on screen):** `@file` mentions with a ranked picker (Tab completes), attachments through the paperclip,
drag and drop (code added, not exercised on screen) and chips in the thread, a message queue while the agent works (paused by Stop, "Send now"), a 60 s slow-reply hint.
Files are expanded into the message as read-only context with size limits; binary files and paths outside the project are refused with a note; **images are attached by path only,
because no provider path carries pixels yet** (next: a `ChatMessage` image part for OpenAI-compatible and Ollama vision models). Not yet: paste of images from the clipboard, `@symbol`/`@page`/`@device`,
steering a running agent mid-step, diff card, todo card.

## 3. Maps parity table (Apple Maps; limits of MapKit noted)

State of the code: `Modules/Maps` (Codex) has map, place search, directions from the map centre, pins, USGS historical maps, layers (standard/satellite/hybrid),
GPX import/export, bookmarks, `maps_*` tools. Not seen or tested here beyond Codex's own QA notes (`docs/29-VISUAL-QA-2026-11-10.md`).

| Apple Maps feature | Status | Notes |
|---|---|---|
| Search with live suggestions, recents, categories (food, fuel, hotels) | partial | `MKLocalSearchCompleter`, `MKLocalPointsOfInterestRequest` |
| Place card: photos, hours, phone, website, rating, share, save | missing | `MKMapItem` has phone and URL; hours, photos, ratings are **not in MapKit** (no public API) |
| Directions: driving, walking, transit, cycling; alternatives; ETA; step list; send to Messages | partial | `MKDirections` gives routes, ETA, steps; transit routing by `.transit` gives ETA only on macOS |
| Look Around | missing | `MKLookAroundSceneRequest` and `MKLookAroundViewController` are public |
| Flyover and 3D, elevation | missing | `MKMapConfiguration` `.imagery(elevationStyle: .realistic)` and `MKMapCamera` |
| Traffic, transit and POI filters, map styles | partial | `showsTraffic`, `MKStandardMapConfiguration` emphasis and filters |
| Guides, favourites, collections, share a place or route | partial (bookmarks) | Local collections with export; share sheet |
| Offline maps | **not available** | No public MapKit API; offer GPX and tile packs of USGS maps instead |
| Indoor maps, Siri, turn-by-turn voice navigation | **not available** | Not public APIs |
| Agent and MCP | have | Keep `maps_*` parity; add `maps_lookaround`, `maps_place_details`, `maps_routes` (alternatives) |
| Thread integration | missing | Map snapshot cards in chat; "show this on the map" opens the Maps surface in the canvas |

Order: search suggestions and categories, place card (what MapKit gives), multi-route directions with ETA and steps, Look Around, Flyover, traffic and filters,
collections and share, then thread cards. Anything the table calls "not available" is shown honestly in the UI, never faked.

## 4. Visual polish backlog for the cohesive look

1. A written visual spec (type scale, 4/8 pt spacing, radii, elevation, motion, ember accent usage, dark and light tokens, density) in `UI/DesignSystem`.
2. Shared components for cards, tab bar, inspector, toolbar groups, badges, progress, toasts; remove one-off styling in Lab, Swarm, Audit and Browser.
3. Sidebar: projects and threads first; activities as a compact icon rail when a thread is open; search; status dots.
4. Motion: 150 ms ease for panes, no layout jumps while streaming, respect Reduce Motion.
5. Accessibility pass (VoiceOver rotor, focus order, contrast in light mode, Increase Contrast) with a checklist per screen.
6. First-run flow (model, project, a first task) and a Home that is a thread list plus suggestions, not a dashboard.

## 5. Decisions needed before the big move

- Is the Thread + Canvas layout the direction (chat as the spine, activities as panes)? It changes where Develop, Analyze and Browser live.
- Keep full-screen Develop and Analyze as a mode of a canvas tab (recommended), or only canvas?
- Maps: accept that hours, photos, ratings, offline maps and indoor maps cannot be done with public APIs, and treat them as links or non-goals?
- Who builds in parallel: chat composer and thread (attachments, mentions, diff, todo, queue), Maps, and the layout host touch different files except `MainWindow`,
  `WorkstationModel`, `WorkstationSidebar`, `AgentDockView` and `ChatRootView`; the layout work should own those and the others should wait for its Canvas host.

## 6. Owner todo, added 2026-11-10 (do these once the current chat slices are done)

Everything in the chat needs to be checked and verified against Claude and Codex, and missing features and functions implemented. Specific items:

1. **Chat display and tool calls (first pass done 2026-11-10, see below).** The owner does not like how the thread and especially tool calls look; the ChatGPT, Codex and Claude desktop apps are much better.
   Redesign the thread: calmer message layout, tool calls as compact, expandable steps with a clear running/done/failed state, inline command output, file edits as diff cards
   (started: the diff card), a single "worked for 42 s" summary line, streaming that never jumps, code blocks with Copy and Open in Editor, tables and math.
   Method: screenshot Claude, Codex and ChatGPT desktop side by side with Kiln, list the differences, then build shared `SSCard`/`SSStep` components.
2. **Tool-call round limit.** The agent pauses after a fixed number of model rounds (`AgentOrchestrator.roundLimit`, default 200, "Paused after N steps; say continue").
   Make it a visible, per-profile setting (Settings and a composer menu), allow "keep going" without typing, show round count and cost in the Team/step line,
   and raise or remove the cap for long runs while keeping the budget gate and Stop button as the real limits.
3. **(Fixed 2026-11-10, see below) Multi-line input (Shift+Return) was reported as not working.** The code path is `ComposerReturn.decide` plus `insertNewline()` in `ChatRootView`
   (`NSApp.keyWindow?.firstResponder as? NSTextView` then `insertNewlineIgnoringFieldEditor`), covered by logic tests only; it has never been checked with real keystrokes
   (background automation sends Return through accessibility). Reproduce with real key events (full-screen control or a UI test), check the Agent view and the dock,
   and replace `TextEditor` with an `NSTextView` wrapper if SwiftUI's `onKeyPress` does not see Shift+Return. Add a UI test with synthesized `keyDown` events.
4. **Audit the whole chat** against the parity table in section 2 and verify each row on screen; the rows marked have/partial are not all verified.
5. **Visual QA of Claude and Codex against Kiln** (owner request, 2026-11-10): first pass done for Codex in `31-CHAT-VISUAL-COMPARISON.md`; repeat for Claude Code Desktop and ChatGPT with a session
   that can address their windows, and re-compare after each change until Kiln matches or beats them.

**Composer card and keyboard (2026-11-10):** the message box is now one rounded card (`ComposerView` in `ChatRootView.swift`): text, then "+" (attach, @ file, / command), voice and send; the model, Agent, Plan, profile and permission chips sit under the card.
`TextEditor` was replaced by an `NSTextView` wrapper (`Modules/Chat/ComposerTextView.swift`) so keys are decided at the AppKit level: **Return** sends (queues while the agent works), **Shift/Option/Control+Return** add a line break,
**⌘Return** sends/queues (as in Claude Code), **Tab** completes an `@` file or a `/` command. 29 tests, including real `keyDown` events sent to the real text view (`ComposerTextViewTests`); the card, a three-line draft
and the picker were seen on screen. Real keystrokes through the running app were not typed (background control), so one manual check of Shift+Return in the app is still worth doing.
Still open from section 6: tool-call and thread display redesign, the round limit setting, the full chat audit.

**Thread and tool-call pass (2026-11-10):** `Core/Chat/ToolActivitySummary.swift` gained `ToolPhrase` (a step reads as a verb and what it touched: *Ran* `swift test`, *Edited* `Pagination.swift`; live line in the progressive tense)
and summaries are sentences ("Ran 4 commands, edited 2 files and read 6 files"). The live view is now Claude Code's: finished steps fold into one grey sentence-line with a chevron, only an approval that needs you stays in view,
and one live line says what is happening with elapsed time (`LiveStatusLine`). Step rows show a verb and the object, with an icon only for steps that waited, failed or were blocked. A reply that is only a tool call written as text no longer
shows raw JSON: a notice says nothing ran, with Show text and Try again. Reply actions stay visible at half strength. `TextToolCall.parseAll` lets small local models run several calls written in a row
(all or nothing; unknown tools, prose between calls, truncated calls and more than eight calls run none). 15 new tests; the replacement of raw JSON was seen on screen; the live line was **not** seen on screen because the local model
used here (qwen2.5-coder:7b) invented an `echo` tool and so ran nothing. Still to do from this section: Codex-style "Worked for X" option, file-name chips that open the editor, code-block Copy, per-burst sentence-lines between the assistant's sentences
(needs per-round text stored with the reply), the round-limit setting, and the full chat audit.
