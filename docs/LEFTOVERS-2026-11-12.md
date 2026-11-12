# Leftovers and verification status (2026-11-12)

What was seen working, what was only tested, and what has not met real data. Newer than `LEFTOVERS-2026-11-10.md`.

## Seen on screen (installed or debug builds of `main`, 2026-11-12)

- Home and its three groups; the command palette ("Go to Mail" first, highlight on the top row).
- Empty states and permission screens: Mail, Messages, Contacts, Notes, Cloud Drives, Research (centered empty library), GitHub (in a folder that is not a repository), Slack (connect screen, token field, readable privacy note).
- Calendar reading real events and reminders (EventKit works against live data).
- Browser: a public server echoed `Version/27.0 Safari/605.1.15` from the browser.
- Agent: a hosted model run (`nemotron-3.5-super` on NVIDIA NIM) with tools loaded on demand ("22 of 199 tools are loaded now"), the search tool ran, the thinking text and answer streamed, the context meter read 3% to 4% during the run and 11% idle.
- Reasoning control: greyed with no label on `nemotron-3.5-super-vl` (no published options), enabled showing "High" on GLM 5.3 Flash.

## Tested only (fakes, fixtures, generated files, stubs)

Mail (scripted IMAP and SMTP servers), Messages (fixture database and fake senders, including the chat-id route and the handle fallback), Contacts (fake list), Notes (a test compiles every generated script against the real Notes dictionary, but no real notes were read), Cloud Drives (temporary folders), Research (generated PDFs, one real Crossref lookup), GitHub (`gh` field names checked against this repository), Spotlight (recording indexer), Slack (in-process URL stub, in-memory token storage), the reasoning requests (request bodies for OpenRouter, NVIDIA and Ollama), Shortcuts (a test guards the destination list).

## Not verified, with what is needed

| Item | Needs |
|---|---|
| A real Mail account (and Outlook.com or Microsoft 365, which cannot sign in at all: no browser sign-in) | An account and an app password from the owner |
| Messages: reading the real database (Full Disk Access) and a real send (Automation permission); the "messages don't send" report from the owner is not diagnosed | The owner, a macOS prompt answered by them, and the exact red error text if it fails |
| Contacts with real contacts; Notes with real notes (Automation permission) | The owner and the permission prompts |
| A real cloud-drive folder; the PDF reader's highlight and save buttons | A synced folder; a PDF |
| A real Spotlight search of an indexed conversation | Settings option turned on by the owner |
| Slack: the connected view, reading, and posting | A Slack app and token created and pasted by the owner |
| A cloud-gaming service starting in the browser | The owner's sign-in; some services check more than the browser name; voice chat has no microphone prompt |
| The reasoning menu opened on screen; a live request with a chosen level for each provider | Real keystrokes or full-screen control; provider keys (never read them) |
| Creating a calendar event or reminder | The owner's approval flow on screen |
| Return in the command palette | Real key events (background automation cannot deliver them) |
| Maps, News, Media, Images, Devices, Audit, Swarm and Analyze in this pass; narrow windows; light mode; VoiceOver | A screen pass |
| Swarm workers with tools on demand | Not built |
| Passkeys, iCloud sync, push for new features, Private Cloud Compute | Apple entitlements and decisions; not promised |

## Known defects (not fixed)

- The context meter has two readings (see the handoff).
- GitHub lists PR 38 as closed although its merge commit is on `main`.
- Model picker: models that are not in the catalog are now hidden from Recents, but the rest of the picker is the old design; the owner wants a real library (see the model-library handoff).
