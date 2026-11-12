# Activities

Kiln's activities are declared once in the activity registry (`Core/Registry/`), which also determines their shortcuts. In the `codex/kiln-qa-completion` development branch, Chat, Code, Browser, Maps and Devices have toolbar controls; the Work menu and command palette (⌘K) provide access to the other activities. On wider windows, Chat stays in the center beside Browser, Maps, Devices, Media and News; Develop and Analyze keep a larger central workspace. Packaged releases can differ from this development layout.

In that development branch, an unsent message follows the conversation between the center and the compact dock. Draft text and attachments are kept separately for conversations while Kiln is open; they are not persisted across relaunches.

| Shortcut | Activity | One line |
|---|---|---|
| ⌘1 | [Home](#home) | Overview and get-started checklist |
| ⌘2 | [Agent](#agent) | Chat with a model, with tools |
| ⌘3 | [Swarm](#swarm) | A goal handed to a team of agents |
| ⌘4 | [Develop](#develop) | Editor, terminal, Git, search, MCP |
| ⌘5 | [Analyze](#analyze) | Reverse engineering |
| ⌘6 | [Lab](#lab) | Datasets, training, evaluation, models |
| ⌘7 | [Audit](#audit) | What agents did, and whether the record is intact |
| ⌘8 | [Browser](#browser) | Tabbed browser the agent can read |
| ⌘9 | [Devices](#devices) | iOS simulators and Android emulators |
| ⌘0 | [Media](#media) | Video, images and audio |

## Home
An overview with a *Get started* checklist and a tile per activity.

## Agent
Converse with a model that has tools. The composer has the model picker, an Agent toggle, a profile menu, a Permissions menu (Ask, Auto, Bypass), a context meter and a compact button, and voice controls (dictate, read replies aloud, hands-free conversation). Finished runs collapse to a one-line summary of tool calls. See [[Agent and Approvals]].
**Limits:** small local models often fail tool use; the compaction interface was merged but not visually verified by its author.

## Swarm
Give a goal to a team: a planner (JSON plan, or a fixed research, implement, review fallback), parallel workers over a coordination bus, blockers reported rather than retried, every call through the same gates.
**Limits:** a hosted model completed a real read, write, review job; a small local model failed. The agent cannot yet create, inspect or cancel a run through a tool.

## Develop
Editor, Terminal, Git, Search and MCP tabs. See [[Develop and Debug]] and [[MCP Server and Tools]].
**Limits:** a capable editor, not Xcode.

## Analyze
Reverse engineering: import, strings, disassembly, Ghidra and radare2 engines, decompiler, cross-references, crypto scan, package downloader. See [[Reverse Engineering Workflow]].

## Lab
Datasets, Models, Experiments, Playground, Evaluation and Red Team tabs. Create ML classifiers; MLX from-scratch language models, LoRA and distillation; evaluation and export. The agent can drive the lifecycle with `lab_*` tools. See [[Model Store]].
**Limits:** smoke runs show execution works, not model quality; full GUI lifecycle coverage and GGUF export are not certified.

## Audit
A hash-chained record of agent runs, approvals and tool results. **Verify now** recomputes every hash and compares the head; the chain can be exported. See [[Security and Privacy]].

## Browser
See [[Browser]].

## Devices
See [[Devices]].

## Media
See [[Media]].

## Voice and remote control
Not an activity, but part of the Agent: dictation, spoken replies and a hands-free mode in the composer, and a Remote control card (Develop → MCP) that pairs an iPhone or Apple Watch companion by QR code to read conversations, send messages and allow once or deny approvals over an encrypted link. The companions are built from source. Physical-device coverage is partial; see [[Security and Privacy]] and `docs/14-REMOTE-CONTROL.md`.

---

**Verified status.** Activity names, order and shortcuts match the registry; behavior and limits come from `docs/11-CURRENT-STATE.md`, `docs/KNOWN-ISSUES.md` and `docs/13-AGENT-CAPABILITY-MATRIX.md`. The registry's own 12 tests passed on 2026-11-09 and the integration branch reported 772 passing tests. **Not checked:** a visual pass of all ten activities in one signed build; Mail, Contacts, Messages, Calendar and GitHub against real accounts and data; the registry is not proof of end-to-end operation.

## Mail, Contacts, Messages, Calendar and GitHub (in development)

Five more activities exist in the development branch. None is in a published release, and none has been tried against a real account yet.

- **Mail:** add an account with your name, address and password. Kiln finds the servers (built-in settings, the Thunderbird configuration database, the domain's own autoconfig file, then common names) and proves the sign-in before saving. Then read, reply and compose. Gmail, iCloud and Yahoo need an app-specific password. **Limits:** no browser sign-in, so Outlook.com and Microsoft 365 are not supported; no STARTTLS-only providers; no offline cache, search or folder actions.
- **Contacts:** a read-only lookup that also completes addresses in Mail and numbers for texts. **Limits:** tested with a fake contact list; needs your macOS permission.
- **Messages:** your conversations, threads that refresh every few seconds, and sending through the Messages app. **Limits:** needs Full Disk Access to read and Automation permission to send; Apple documents neither, so updates can break it; delivery cannot be confirmed; one recipient per new text; attachments are not sent.
- **Calendar:** the next 7 days of events and open reminders; agents can add an event or reminder after approval. **Limits:** EventKit has not been exercised against real data; no edit or delete.
- **GitHub:** pull requests, CI runs and issues for the open project, read-only, through the `gh` sign-in on your Mac. **Limits:** no comments, reviews or merges.

All five have agent and MCP tools; see [[MCP Server and Tools]] and the permissions in [[Security and Privacy]]. Shortcuts can open any activity or put a question in the message box ("Ask Kiln").

## Maps and News

The development branch includes Maps (MapKit, USGS Topo and historical catalog discovery, pins and driving directions) and News (ModernReader source directory and feed subscriptions and an All stories view with source, topic and text filters). Both expose agent and MCP tools. These activities are not part of the older preview release; see [scope and verification](https://github.com/noktirnal42/Kiln/blob/main/docs/23-MAPS-AND-NEWS.md).
