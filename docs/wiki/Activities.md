# Activities

Kiln's activities are declared once in the activity registry (`Core/Registry/`), which also determines their shortcuts. The toolbar has buttons for Chat, Code, Browser, Maps and Devices; the Work menu and the command palette (⌘K) reach the rest. On wider windows, Chat stays in the center beside Browser, Maps, Devices, Media and News; Develop and Analyze keep a larger central workspace with a compact chat panel. The sidebar holds New chat, Scheduled tasks, your project and your conversations.

An unsent message follows the conversation between the center and the compact dock. Draft text and attachments are kept separately for each conversation while Kiln is open; they are not persisted across relaunches.

There are 22 activities. Ten have shortcuts:

| Shortcut | Activity | One line |
|---|---|---|
| ⌘1 | [Home](#home) | Overview, get-started checklist, a card for every activity |
| ⌘2 | [Agent](#agent) | Chat with a model, with tools |
| ⌘3 | [Swarm](#swarm) | A goal handed to a team of agents |
| ⌘4 | [Develop](#develop) | Editor, terminal, Git, search, MCP |
| ⌘5 | [Analyze](#analyze) | Reverse engineering |
| ⌘6 | [Lab](#lab) | Datasets, training, evaluation, models |
| ⌘7 | [Audit](#audit) | What agents did, and whether the record is intact |
| ⌘8 | [Browser](#browser) | Tabbed browser the agent can read |
| ⌘9 | [Devices](#devices) | iOS simulators and Android emulators |
| ⌘0 | [Media](#media) | Video, images and audio |

The other twelve have no shortcut and are in the Work menu and the palette: [Images](#images), [Maps](#maps-and-news), [News](#maps-and-news), [Mail](#mail), [Messages](#messages), [Slack](#slack), [Contacts](#contacts), [Calendar](#calendar), [Notes](#notes), [Cloud Drives](#cloud-drives), [Research](#research) and [GitHub](#github).

## Home
An overview with a *Get started* checklist and a card for each activity, grouped as **Work**, **Communication** and **Files and knowledge**.

## Agent
Converse with a model that has tools. The composer has the model picker, an Agent toggle, a profile menu, a Permissions menu (Ask, Auto, Bypass), a reasoning control (the brain button, greyed out when the model offers no options), a context meter and a compact button, and voice controls (dictate, read replies aloud, hands-free conversation). Finished runs collapse to a one-line summary of tool calls; file names in replies are chips that open the editor; you can edit an earlier message and resend it. Kiln has more than 200 tools, so a run starts with the basics and the agent loads the others by asking (`kiln_tool_search`); the thread says how many tools are loaded. See [[Agent and Approvals]].
**Limits:** small local models often fail tool use. On-demand loading was seen working with one hosted model; a model that ignores the search tool will lack the module tools.

## Swarm
Give a goal to a team: a planner (JSON plan, or a fixed research, implement, review fallback), parallel workers over a coordination bus, blockers reported rather than retried, every call through the same gates.
**Limits:** a hosted model completed a real read, write, review job; a small local model failed. The agent cannot yet create, inspect or cancel a run through a tool. Workers get all their tools up front (no on-demand loading).

## Develop
Editor, Terminal, Git, Search and MCP tabs, with a language server (Swift and C-family), build, test and run, and an LLDB launch debugger. Agents have `ide_*` tools for most of it. See [[Develop and Debug]] and [[MCP Server and Tools]].
**Limits:** a capable editor, not Xcode. Many newer Develop views were unit-tested and not yet looked at in the running app.

## Analyze
Reverse engineering: import, strings, disassembly, Ghidra and radare2 engines, decompiler, cross-references, control-flow and call graphs, patching on a copy, binary diffing, package inspection, crypto scan, package downloader. See [[Reverse Engineering Workflow]].

## Lab
Datasets, Models, Experiments, Playground, Evaluation and Red Team tabs. Create ML classifiers; MLX from-scratch language models, LoRA and distillation; evaluation and export. The agent can drive the lifecycle with `lab_*` tools. See [[Model Store]].
**Limits:** smoke runs show execution works, not model quality; full GUI lifecycle coverage and GGUF export are not certified.

## Audit
A hash-chained record of agent runs, approvals and tool results. **Verify now** recomputes every hash and compares the head; the chain can be exported. See [[Security and Privacy]].

## Browser
A tabbed browser that identifies itself as Safari, so streaming and cloud-gaming sites accept it. See [[Browser]].

## Devices
See [[Devices]].

## Media
See [[Media]].

## Images
Local image generation with SD-Turbo and a model catalog, history, and optional external engines (Draw Things, ComfyUI, AUTOMATIC1111/Forge). A missing engine shows a setup state and never fakes output.
**Limits:** SDXL and external-engine generation are unverified; AI upscalers and ControlNet are not implemented.

## Maps and News
Maps: MapKit, USGS Topo and a historical-map catalog, pins and driving directions. News: the ModernReader source directory, subscriptions, combined stories and RSS, Atom and JSON feeds. Both expose agent and MCP tools. Maps has a My Location button (macOS asks for permission the first time; if you denied it, enable Kiln under System Settings → Privacy & Security → Location Services). It also has a Radar button (NOAA radar for the contiguous US, with a time loop, opacity, legend and a `maps_radar` tool; it shows rain already falling, not a forecast) and a Weather button and agent tools (`weather_forecast`, `weather_alerts`) for US places from the National Weather Service, with the source, when it was issued and the issuing office of any alert; it covers the United States only. A radar layer is on the [[Roadmap]], not built. See [scope and verification](https://github.com/noktirnal42/Kiln/blob/main/docs/23-MAPS-AND-NEWS.md).
**Limits:** location and routes need live QA; News subscriptions are local and entries are session-only.

## Mail
Add an account with your name, address and password. Kiln finds the servers (built-in settings, the Thunderbird configuration database, the domain's own autoconfig file, then common names) and proves the sign-in before saving. Then read, reply and compose, with address completion from Contacts. Gmail, iCloud and Yahoo need an app-specific password.
**Limits:** tested only against scripted local servers, not a real provider. No browser sign-in, so Outlook.com and Microsoft 365 are not supported; no STARTTLS-only providers; no offline cache, search or folder actions.

## Messages
Your conversations, threads that refresh every few seconds, and sending through the Messages app. A message goes to the conversation by its own id (iMessage, SMS and groups); a failed send is shown in red.
**Limits:** needs Full Disk Access to read and Automation permission to send; Apple documents neither, so updates can break it; delivery cannot be confirmed; one recipient per new text; attachments are not sent. Tested against a fixture database and fake senders; no real text has been sent from it.

## Slack
Channels, direct messages and history of your Slack workspace, and posting with your approval. You create a small Slack app, add the read and `chat:write` scopes, install it to your workspace and paste its token (a bot `xoxb-` or user `xoxp-` token) into Kiln. Kiln checks it with Slack before saving it to the Keychain, never shows it again and never gives it to a model. Messages you post show their exact text for approval and Kiln refuses `@channel`, `@here`, `@everyone` and user-group mentions.
**Limits:** a bot only sees channels it has been invited to; Kiln polls every 15 seconds (no real-time events), and has no search, files or reactions; one workspace; Discord and Teams are not built. Tested against a stub of the Slack API; not seen on screen and not tried against a real workspace.

## Contacts
A read-only lookup that also completes addresses in Mail and numbers for texts.
**Limits:** tested with a fake contact list; needs your macOS permission.

## Calendar
The next 7 days of events and open reminders; agents can add an event or reminder after approval.
**Limits:** reading events and reminders worked against real data in the installed build (2026-11-12); creating one has not been tried; no edit or delete.

## Notes
Recent notes, search, read, and add a new note in Apple Notes by asking the Notes app (macOS asks once for Automation permission, and Kiln waits until you press Allow).
**Limits:** Apple documents no data API for Notes, so this can change with macOS updates; Kiln only creates notes and never edits or deletes; password-locked notes cannot be read; attachments and checklists are not read; not run against real notes.

## Cloud Drives
Browse and search the names of the iCloud Drive, Google Drive, Dropbox and OneDrive folders that the providers' own apps sync to this Mac, read text files, and copy files into the project or save a project file into a drive (with approval). Kiln never signs in to a cloud service and never handles a token.
**Limits:** online-only files must be downloaded in Finder first; search matches names, not contents; Google Docs and Sheets are only link files on disk; macOS may ask for access to the folders; no real drive folder has been browsed yet.

## Research
A library of sources with notes and tags, citations in APA, MLA and BibTeX, DOI lookup through Crossref (only the DOI is sent), and a PDF reader that highlights text and saves a new annotated copy (the original is never changed). Agents can read and search PDFs in the project.
**Limits:** scanned PDFs have no selectable text and there is no OCR; locked PDFs are refused; the reader's highlight and save buttons have not been seen working on screen.

## GitHub
Pull requests, CI runs and issues for the open project, read-only, through the `gh` sign-in on your Mac.
**Limits:** no comments, reviews or merges; seen only in a folder that is not a repository.

## Spotlight and Shortcuts
Not activities. In Settings you can add conversations to Spotlight (Off by default, Titles only, or Titles and text; secrets are redacted and Off removes everything Kiln added). Shortcuts can open any activity or website or put a question in the message box ("Ask Kiln"). Spotlight search itself has not been tried.

## Voice and remote control
Not an activity, but part of the Agent: dictation, spoken replies and a hands-free mode in the composer, and a Remote control card (Develop → MCP) that pairs an iPhone or Apple Watch companion by QR code to read conversations, send messages and allow once or deny approvals over an encrypted link. The companions are built from source. Physical-device coverage is partial; see [[Security and Privacy]] and `docs/14-REMOTE-CONTROL.md`.

All the communication and knowledge activities have agent and MCP tools; see [[MCP Server and Tools]] and the permissions in [[Security and Privacy]].

---

**Verified status.** Activity names, order and shortcuts match the registry (22 activities). Behavior and limits come from `docs/11-CURRENT-STATE.md`, `docs/KNOWN-ISSUES.md` and `docs/13-AGENT-CAPABILITY-MATRIX.md`. On 2026-11-12 the installed build was checked on screen: Home and its grouping, the palette, the empty states and permission screens of Mail, Messages, Contacts, Notes, Cloud Drives, Research and GitHub, Calendar reading real events, the Browser, and an Agent run. **Not checked:** Mail, Messages, Contacts, Notes, Cloud Drives, Research and Slack with real accounts and data (the Slack screen itself has not been seen), Spotlight search, Maps, News, Media, Images, Devices, Audit, Swarm and Analyze in this pass, narrow windows and light mode. The registry is not proof of end-to-end operation.
