# Launch marketing assets (drafts)

Nothing here is posted or published. The maintainer approves all posting. Written 2026-11-03 against Kiln 0.1.1.

| File | What |
|---|---|
| `VIDEO-SCRIPT.md` | 90 s demo: script, shot list, checklist, ffmpeg assembly (the full target version, including the watch) |
| `CLIPS.md` | Three under-30 s clips, storyboards |
| `LAUNCH-COPY.md` | Drafts per community, Show HN comment, social thread |
| `../../Scripts/make_demo_cut.py` | Builds the demo cut from raw Mac and simulator recordings |
| `../../Scripts/make_marketing_loop.py` | Older stills-only placeholder builder (no longer used for the published loop) |

## Captured for real (2026-11-03)

One unedited-recording session of the installed Kiln 0.1.1, Ask mode, on a throwaway Swift package with a failing test (`pageCount` used integer division). Model: `gemma4:31b` via Ollama Cloud. The agent ran `swift test --filter PaginationTests`, read the test and source, fixed the bug, re-ran the test and committed.

- `site/assets/kiln-demo-draft.mp4` (about 100 s, muted, captioned): the draft cut. Mac and iPhone Simulator side by side. Two `run_command` approvals were answered from the iOS Simulator companion, which Kiln logged as **`via: remote`** (26 s and 22 s waits); the `git_commit` gate, with its message, was answered with the mouse (`via: mouse`). Cuts are marked in the video.
- `site/assets/kiln-approval-loop.mp4` and `.gif` (22 s): the gate on the Mac plus the same approval on the phone.
- `site/assets/shots/demo-gate-and-phone.png`: still from the cut. `audit-chain.png`: crop of the Audit view.
- The README hero is the GIF above.

What the cut honestly is, so captions and posts must say the same:
- The phone is the **iOS Simulator** paired to the real Mac over the local network. It is not a real iPhone and there is no Apple Watch.
- The audit scene is a **verbatim excerpt of `approvals.jsonl`**, rendered as text. The Audit tab in Kiln lists events but does not show the `via` field, so the `via: remote` evidence is the log file, not the app UI.
- `write_file` was **not gated**: a standing grant on this Mac covers it (it shows as `alwaysAllow` in the log with no wait). A clean demo should revoke that grant; I did not touch your grants.
- The Mac pane is clipped on the right in the recording because another window covered part of Kiln; the gate is readable but "Always Allow" is cut off.
- The phone list shows a few conversation titles from your QA chats ("New Conversation", "Clean up the build folder: ..."). Review before posting.

## Still to record

- **Apple Watch / real iPhone push alert**: the relay and push registration are live for your real phone (Kiln showed "Internet relay connected" and "1 phone registered for alerts"), so an alert should reach it when an approval waits about 4 s. Needs you: Remote control on, phone locked, Kiln closed on the phone, watch awake, then film the wrist or lock screen while the Mac run is going. I did not touch your phone.
- **Clips 2 and 3** (LoRA from chat, reverse-engineering a function): not attempted. Clip 1 is covered by the loop above, minus the watch.
- A rebuilt cut once a real watch shot exists: `python3 Scripts/make_demo_cut.py MAC.mov PHONE.mov OUT_DIR` (edit the segment table at the top).

## How the footage was made (for repeating it)

- Mac: `screencapture -v -x -V <seconds> mac.mov` (it writes the file only when it ends; start it with `nohup ... &` from a background command). Phone: `xcrun simctl io <udid> recordVideo --codec h264 phone.mov`, stopped with SIGINT.
- Pair the simulator: build KilnRemote with ad-hoc signing (`CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=`); an unsigned build cannot write the Keychain and Pair silently does nothing. The pairing link can be decoded from the Remote control QR with CoreImage `CIDetector`; type it into the "paste the pairing link" field, press return, then Pair. A leftover pairing from an earlier install shows as "Studio Mac": Settings, Unpair, then pair again.
- Kiln quirks met: New chat sometimes keeps showing the old transcript and typing appends to it, so after quitting and relaunching Kiln start from the fresh "New chat" screen and check the title; the free `nemotron` and `GLM 5.3 Flash` models did not respond in 80 s, `gemma4:31b` did; the Mode chip's menu is not the tooltip you see on hover.
- State left behind: Remote control stopped, project back to PolyBot, mode chip on **Ask** (was Auto), simulator app uninstalled. The simulator's pairing may still be listed under Kiln's Remote control devices (remove that one entry; "Unpair all devices" would also remove your real phone). The demo package is at `~/KilnDemo/DemoPackage`.
