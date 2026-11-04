# Launch marketing assets (drafts)

Nothing here is posted or published. The maintainer approves all posting. Written 2026-11-03 against Kiln 0.1.1.

| File | What |
|---|---|
| `VIDEO-SCRIPT.md` | 90 s demo: script, shot list, checklist, ffmpeg assembly |
| `CLIPS.md` | Three under-30 s clips, storyboards |
| `LAUNCH-COPY.md` | Drafts per community, Show HN comment, social thread |
| `../../Scripts/make_marketing_loop.py` | Builds `site/assets/kiln-approval-loop.mp4` from stills |

## Captured for real (2026-11-03)

- `site/assets/shots/audit-chain.png`: a crop of the running Kiln 0.1.1 Audit view (chain event count and head hash). Real app, no agent run behind it.
- Already existing: `approval-crop.jpg` (real Mac approval queue). `watch-approval.png`, `watch-reply.png`, `iphone-*.png` are **simulator demo data**.
- `site/assets/kiln-approval-loop.mp4`: an 18 s muted draft slideshow of the three stills above with captions that state which are real and which are simulator. It is a placeholder, **not** the demo video; do not use it as proof of the watch flow. Rebuild with `python3 Scripts/make_marketing_loop.py`.

## Not captured; to record

- The 90 s demo and all three clips: needs a real watch and phone, a configured relay and push key, and a hosted tool-capable model. The installed app's agent models today are a free hosted model whose last run stopped without an answer, so a staged take needs a better model first.
- A real `via: remote` Audit row on screen. The current Audit view has "No agent activity recorded yet" for this session.
- A README hero GIF from real footage (the ffmpeg commands are in `VIDEO-SCRIPT.md`).

## Recording attempt, 2026-11-03 (second pass): what happened

Everything below was tried against the maintainer's live Kiln 0.1.1 and the iOS simulator. **No usable footage came out of it, so the video is still not cut** and no new media was added.

- Kiln can be driven: switching project (Choose Folder) and setting the mode chip to **Ask** both work. The Mac screen recorded fine with `screencapture -v`.
- **Blocker 1, no gate appeared.** The installed app has 32 standing grants, including tool-wide `write_file` and `edit_file` and a `swift test ... | tail -60` command grant, so Ask mode did not stop those calls. A clean take needs those revoked first (Approval Queue, Standing grants, Revoke). I did not revoke the maintainer's grants.
- **Blocker 2, wrong project.** Sending a prompt from "New chat" appended it to the existing PolyBot conversation, and the agent explored PolyBot, not the demo package. I stopped it after read-only calls (`list_directory`, `swift test`, `read_file`, `glob`); nothing was written. One extra user message and a partial run now sit in that old chat. Start from a genuinely new conversation (check the sidebar highlights "New Conversation" before typing).
- **Blocker 3, model.** The configured free model (nemotron-3.5-super-vl) stopped without an answer earlier and wandered here; a tool-capable model is needed for a clean fix-the-test run.
- Simulator: KilnRemote built and installed on iPhone 17 Pro, FakeMac started. Pairing by pasted link did not complete in my session (the Pair button was inert after the camera prompt); not diagnosed. Real Mac to simulator pairing was not attempted.
- Left changed in the app: project restored to PolyBot, mode chip left on **Ask** (it was Auto). The demo package is at `~/KilnDemo/DemoPackage` (git repo, one failing test).

## Needed from the maintainer (in this order)

1. Revoke the `write_file`, `edit_file` and command standing grants (or confirm I may), set a tool-capable model, and keep Ask mode.
2. Real watch: Remote control on in Kiln, relay URL set, push key deployed, iPhone locked with Kiln closed, watch awake and mirroring. Then run the 9-shot list in `VIDEO-SCRIPT.md`; the assembly commands are there.
3. Do not press Always Allow during takes.
