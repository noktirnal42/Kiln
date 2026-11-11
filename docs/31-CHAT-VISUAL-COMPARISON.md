# Chat visual comparison: Codex, Claude, Kiln (2026-11-10)

The owner wants Kiln's chat to look and work like the Codex and Claude desktop apps, and better. This is the first pass of that comparison and the list of changes it
produces. Sources: the Codex desktop app (`com.openai.codex`, shown as "ChatGPT") opened on an existing thread, read only; Claude Code Desktop from the well-known layout
(its app could not be addressed from this session, so nothing below claims a pixel measurement of it); Kiln from screenshots in `docs/qa/final-polish/`.
Reference screenshots of Codex contain the owner's own threads, so they are kept outside the repository, in the session notes folder (`visual-qa/`).

## What Codex does (observed)

1. **The run is one quiet line.** All tool work of a turn collapses to a hairline with "Worked for 27m 3s ›" (expandable). The reply that follows is plain text. Tool
   calls are never listed between messages unless asked for.
2. **The reply reads like a document.** Plain paragraphs and bullets, inline code, file names as small link chips with an icon ("Kiln-Verified.app", "REModuleRootView.swift")
   that open the file.
3. **Changes are a card, not a log.** "Edited 2 files +12 −2" with **Undo** and **View changes**, then one row per file with +/−; long paths are middle-truncated with the file name kept.
4. **Message actions sit under the reply**, small and always findable: copy, good/bad, read aloud, more.
5. **Composer is one calm card** docked at the bottom of a centred ~620 pt column: "+" (attach and more), a **permission pill** ("Full access", orange when broad), model and effort
   picker on the right, mic and a voice button. On the empty thread it also shows the project and "This computer" (where it runs).
6. **Frame:** a thin icon rail (Home, Images, Scheduled, Library, Plugins, Code Review, Sites), a project-first sidebar (Pinned, Projects, threads under each), a title bar with the
   thread title, and a collapsible right panel ("Outputs": generated images and files). Unread and running threads carry a small dot.
7. **Home** asks "What should we build in <project>?" and puts the composer under it; no dashboard.

## What Claude Code Desktop does (from its known behaviour)

Grouped tool calls ("Ran 4 commands, edited 2 files, read 6 files") that expand to the steps, each step with a status icon and its output; a todo list pinned above the composer;
a diff review pane with line comments sent back as feedback; a plan card with approve and edit; permission mode switch next to the composer; sessions with a status dot in the sidebar;
side panel for the file or preview the agent is working on.

## Where Kiln differs today

| Area | Kiln now | Target |
|---|---|---|
| Run summary | Live rows during the run, then "Ran 4 commands · edited 2 files" that expands | Keep the idea, add the duration ("Worked for 42 s"), one hairline, and show steps as quiet text rows with status icons only when expanded |
| Reply text | Markdown, 760 pt column | Same column; add file-name chips that open the Editor at the line, inline code styling, copy buttons on code blocks |
| Changes | Diff card with per-file Revert (new) | Header "Edited 2 files +12 −2" with **Undo all** and **View changes** (opens the Canvas diff), middle-truncated paths; matches Codex |
| Message actions | Hover only (copy, regenerate, fork, delete) | Always-visible small row under the reply: copy, regenerate, fork, read aloud, more |
| Composer | Row of controls (mode bar, model, Agent, Plan, profile, Ask, meter) above a text box, plus voice buttons beside it | One rounded card: "+" menu (attach, mention, commands), permission pill (Ask / Auto / Bypass, coloured), model with effort, meter inside the card, send. Mode bar chips (Agent, Plan, profile) move into the "+" menu and a single mode pill |
| Frame | Sidebar of chats on top, tools beneath, dock to the right | Project-first sidebar (projects with their threads), thin icon rail for surfaces, Canvas on the right (see `30-CHAT-MAPS-LAYOUT-PLAN.md`) |
| Home | Dashboard of panels | "What should we work on in <project>?" with the composer, recent threads, three starter prompts |
| Status | Bottom bar with agent state, model, audit, tripwires | Keep the bar, but move model to the composer card; show a dot on sidebar threads (running, waiting for approval, unread) |
| Empty states, spacing | Mixed | One spacing scale; 16 pt gutters; 8/12/16 pt rhythm inside the column |

## Concrete changes, in order

1. Composer card redesign (Shift+Return fix included; see the owner todo in doc 30 section 6): one `ComposerCard` component used by the Agent view, the dock and Home.
2. Thread: "Worked for X" run line with duration and expandable steps; always-visible action row; file chips; code block Copy.
3. Diff card header and "View changes" / "Undo all".
4. Sidebar: project-first grouping, status dots, thread rename/pin/archive.
5. Home as a composer-first screen.
6. Canvas (right panel) with Outputs and the diff review.

Each step ships with a before/after screenshot in `docs/qa/final-polish/` and a note here. Visual QA of Claude Code Desktop should be repeated by a session that can address its window.
