# Agent and Approvals

## Profiles

A profile decides which tools the agent is offered.

- **Research Assistant**: read-only.
- **Coding Agent**: adds file, shell and Git tools.
- **Workstation Agent**: adds the module tools (`re_*`, `lab_*`, `browser_*`, `device_*`, `media_*`, swarm tools and opt-in computer use). Each module declares the prefixes it owns in the registry.

Agent mode runs `AgentOrchestrator` with policy gates A and B, approvals, a behavior monitor and a tamper-evident audit record. The default run limit is 200 steps and it pauses rather than failing. The limit can be changed per profile in Settings or the composer, and `kiln_round_limit_read` / `kiln_round_limit_set` expose it to agents and MCP clients. Changes apply to the next run; the write tool requires approval. **Keep going** starts a new turn with the tool context retained in memory, subject to normal context compaction. The context is lost after relaunch or switching conversations; changing the model, profile, project or agent mode requires a new message instead.

## Approvals

Reads run freely. Writes, commands and network calls open the approval sheet.

- **Allow once** answers one call.
- **Always Allow** makes a standing grant, revocable under Approvals. Standing grants are made at the Mac, never from a phone or watch.

### Modes: Ask, Auto, Bypass

The composer's **Permissions** menu:

| Mode | Behavior |
|---|---|
| **Ask** (default) | Waits for you on every approval |
| **Auto** | Approves routine calls: non-destructive, inside the project, not flagged by the execution policy, not admin tier. Destructive, out-of-scope, new-to-network, risky-shell or admin calls still ask |
| **Bypass** (red, confirmed first) | Approves everything except hard policy blocks and behavior-monitor holds |

A mode answers once: it never creates a standing grant, never answers a monitor hold, and resets to Ask whenever Kiln launches. Each decision is written to `approvals.jsonl` with how it was given (`mouse`, `keyboard`, `programmatic`, `remote`, `auto-mode`, `bypass-mode`) and how long it waited; mode changes go to the audit chain. These modes are separate from macOS permissions such as Accessibility or the microphone, which they cannot grant.

## Reasoning options

The brain button next to the context meter lists the reasoning options the selected model actually offers: an on/off switch for most Ollama thinking models, named levels where a model has them (low, medium and high for gpt-oss and for OpenRouter reasoning models, low, high and max for NVIDIA GLM 5.3). A model with no options shows the button greyed out, and its tooltip says why. The choice is remembered per model. The memory files (KILN.md, AGENTS.md, CLAUDE.md) are in the composer's **+** menu, and `/memory` still opens them. Request bodies are unit-tested; no live API has been sent a chosen level yet.

## Context management

Before each model call, if the estimate passes 70% of the window (minus output and tool-schema size), older tool results become short stubs (newest four kept); if still over, the older part is summarised by the model; if that fails, the oldest part is dropped with a note. The composer has a context meter, a compact button and `/compact`. Tool calls from earlier turns are not replayed to the model, only the summary and text.

### Tools are loaded on demand

Kiln has more than 200 tools, about 21,000 tokens of definitions. When those would use more than a tenth of the model's window, a run starts with the file, search, shell, Git and web tools plus one tool, `kiln_tool_search`. The agent searches by what it needs ("email", "calendar") and the matching tools are added for the rest of the run; calling a tool that is not loaded loads it and returns its arguments instead of running it. Permissions and approvals are unchanged. A window too small even for the basics is trimmed to fit, and the thread says "N of M tools are loaded". The meter counts the conversation while a run is going and, when idle, also the system prompt and loaded tools, so the two readings differ. Swarm workers still get their tools up front.

## Streaming

Agent mode emits text as the provider streams it. Redaction of secrets in streamed text is heuristic: an incomplete secret fragment may be briefly visible before it is replaced. Text content is not written to the audit log.

## Shared tool configuration

Kiln reads, and never copies, MCP servers from Claude Code, Codex and OpenCode configuration and skills from their skill folders; each imported server needs **Approve & Connect** in Develop → MCP. Agents get `list_skills` and `read_skill`. Not imported: OpenCode's JavaScript plugins, Claude Code hooks and slash commands, and MCP servers bundled inside Claude plugins.

## Computer use (experimental)

Off until enabled in Settings; needs macOS Accessibility. It is Accessibility-based, so it sees only what an app exposes; actions include `list_apps`, `open_app`, `read`, `inspect`, `press`, `set_value`, and keyboard actions that refuse password fields. Each call asks in Ask and Auto. Indices are valid only for the latest `inspect` of one app.

---

**Verified status.** Modes and logging were unit-tested; Bypass was exercised by a real agent run on 2026-11-03; computer use read Calendar and Messages. Compaction and streaming fixes have regression tests. On 2026-11-12 an agent run against NVIDIA NIM was watched on screen: tools loaded on demand (22 of 199), the search tool ran, and the thinking text and answer streamed. **Not checked:** Auto in a real agent run, the compaction interface in the running app, on-demand loading with a small local model, and computer use beyond Calendar and Messages.
