# MCP Server and Tools

## Kiln as an MCP server

**Develop → MCP → Start** exposes Kiln's tool registry to external MCP clients (Claude Code, Codex, OpenCode and others).

- Listens on **loopback only**.
- Requires a **bearer token** kept in a private (0600) file under `~/Library/Application Support/Kiln`; a request without it gets 401. Never paste that token into prompts, issues or screenshots.
- External calls run as "External: <client>", are **audited**, and anything other than a read waits for approval in Kiln.
- The tool list comes from the registry, so it grows with the app. The authoritative list for your build is what `tools/list` returns. (An earlier record counted 34 tools; the registry now has more than 200, so do not rely on a number.) The MCP server offers every registered tool; on-demand loading (`kiln_tool_search`) is only for the in-app agent and is not part of the server.

## Kiln as an MCP client

Develop → MCP lists servers imported from Claude Code, Codex and OpenCode configuration (read, not copied). A server that launches the same command is one server; the same name with a different command is kept as `name-<tool>`. Environment values stay in memory. Each needs **Approve & Connect**. Agents reach connected servers through `mcp_list_tools` and `mcp_call_tool`.

## Tool families

| Family | Examples | Notes |
|---|---|---|
| Files, shell, Git | `read_file`, `write_file`, `edit_file`, `run_command`, `git_diff`, `git_commit` | File tools are confined to the project root; `run_command` is not |
| Web and skills | `web_fetch`, `web_search`, `list_skills`, `read_skill` | Network calls are egress-checked |
| Reverse engineering | `re_import_binary`, `re_analyze_binary`, `re_get_decompilation`, `re_search_strings`, `re_scan_crypto`, `re_rename_function` | Import returns a `project_id`; writes need approval |
| Model Lab | `lab_import_dataset`, `lab_create_experiment`, `lab_start_training`, `lab_start_lora`, `lab_export_model` | Starting jobs is execution-gated |
| Develop | `ide_open`, `ide_outline`, `ide_definition`, `ide_build`, `ide_test`, `ide_diagnostics` and the rest of `ide_*` | Build, test, run and debug need execution approval |
| Browser | `browser_open`, `browser_read_page`, `browser_click`, `browser_type` | `browser_type` refuses credential fields |
| Devices | `device_list`, `device_boot`, `device_screenshot`, `device_install` | Reads free; execute and write gated |
| Media | `media_open`, `media_list`, `media_generate_image`, `media_speak`, `media_transcribe` | Writes need approval |
| Images, Maps, News | `image_*`, `maps_*`, `news_*` | See [Maps and News](https://github.com/noktirnal42/Kiln/blob/main/docs/23-MAPS-AND-NEWS.md); image writes need approval |
| Kiln itself | `kiln_memory_read`, `kiln_memory_write`, `kiln_command_*`, `kiln_hooks_list`, `kiln_schedule_*`, `kiln_checkpoint_list`, `kiln_usage_report`, `kiln_round_limit_*` | State changes need approval and are audited |
| Swarm workers | `swarm_post`, `swarm_read`, `swarm_memory_get`, `swarm_memory_set`, `swarm_report_blocker` | Used by workers |
| Computer use | `computer_use` | Experimental, opt-in |
| Mail (development build) | `mail_accounts`, `mail_folders`, `mail_recent`, `mail_read`, `mail_send` | Reading reaches the network and is gated; `mail_send` needs approval of the recipients, subject and text; message text is untrusted |
| Slack (development build) | `slack_status`, `slack_channels`, `slack_read`, `slack_send` | Reads need your connected token; `slack_send` needs approval of the conversation and exact text and refuses whole-channel mentions; message text is untrusted; the token is never in tool input or output |
| Contacts (development build) | `contacts_status`, `contacts_search` | Read-only; needs the macOS Contacts permission |
| Messages (development build) | `messages_conversations`, `messages_read`, `messages_send`, `messages_compose` | Reading needs Full Disk Access; sending needs Automation permission and approval of the conversation and exact text; delivery is not confirmed |
| Calendar and Reminders (development build) | `calendar_events`, `calendar_create_event`, `reminders_list`, `reminders_create` | Reads gated by macOS permission; creating needs approval; no edit or delete |
| Cloud drives (development build) | `drive_locations`, `drive_list`, `drive_search`, `drive_read`, `drive_copy_to_project`, `drive_save` | Reads stay inside the chosen drive; copies never overwrite; `drive_save` needs approval; file text is untrusted |
| Notes (development build) | `notes_recent`, `notes_search`, `notes_read`, `notes_create` | Through the Notes app (Automation permission); creating needs approval; no edit or delete; note text is untrusted |
| GitHub (development build) | `github_prs`, `github_pr`, `github_issues`, `github_runs` | Read-only, through the `gh` sign-in on the Mac; text from GitHub users is untrusted |
| Research (development build) | `pdf_info`, `pdf_read`, `pdf_search`, `pdf_highlight`, `pdf_note`, `library_search`, `library_add`, `library_cite`, `library_note` | Annotating always writes a new file; locked PDFs are refused; only a DOI is sent to Crossref |
| Loading tools | `kiln_tool_search` | In the in-app agent loop only: loads module tools on demand; runs nothing |

## What is not exposed

The registry records capabilities with no agent tool yet, including: creating, inspecting or stopping a swarm run; browsing or verifying the audit chain; choosing the open analysis project; deleting projects or media; downloading models into the Lab library; browser history and tab closing. Shell access is not a substitute for a service-backed action. The maintained list is `docs/13-AGENT-CAPABILITY-MATRIX.md`.

## Adding a tool

A new action should call the same service the GUI uses, declare read, write or execute permission before registration, accept stable IDs and bounded parameters, return structured status (including partial, blocked and failed), preserve cancellation, and ship with behavior tests. See [[Contributing]].

---

**Verified status.** Tool names come from the source on `main` (2026-11-12); the MCP server returned 401 without a token and listed real tools in a 2026-11-01 check; an external call was audited. Imported-tool behavior is covered by tests. **Not checked:** an end-to-end session with each external client in this documentation pass, and an exact tool count for the current build (219 were registered in a test registry on 2026-11-12; a chat without a project folder was offered 199).
