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

- `site/assets/kiln-demo-draft.mp4` (92 s, muted, captioned): the draft cut. Mac and iPhone Simulator side by side. Two `run_command` approvals were answered from the iOS Simulator companion, which Kiln logged as **`via: remote`** (26 s and 22 s waits); the `git_commit` gate, with its message, was answered with the mouse (`via: mouse`). Cuts are marked in the video.
- `site/assets/kiln-approval-loop.mp4` and `.gif` (22 s): the gate on the Mac plus the same approval on the phone.
- `site/assets/shots/demo-storyboard.png`: one still per scene of the cut, for reviewing without playing the video. `site/assets/shots/demo-gate-and-phone.png`: still from the cut. `audit-chain.png`: crop of the Audit view.
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

## Clip 3 attempt (reverse-engineering a function), same day: run worked, recording did not

- Test binary: `~/KilnDemo/re/checksum` (built from `checksum.c` there with `clang -O1`, unstripped, arm64). It has one function, `code_checksum`: FNV-1a over the input with a 5-bit left rotate after each byte.
- Prompt typed into Kiln's Analyze side agent (Ask mode, gemma4:31b): "Import the binary ..., find the function code_checksum, disassemble it and explain in plain language what it computes."
- Real result: a `re_import_binary` gate (path shown, "Writes or modifies files in the workspace", approved once with the mouse), then a `re_analyze_binary` gate ("Runs a command or reaches the network", approved once). Ghidra 12.1.4 finished within about 30 s, the function list showed `_code_checksum` and the decompilation showed the offset basis `0x811c9dc5` and the prime. The agent's explanation was correct (FNV-1a with a rotation) and ended with a plain-language summary. Its tool list showed two `re_analyze_function` failures before success; keep that in any caption ("failures that teach").
- **The footage is not usable**: `screencapture` records the real desktop, and this Claude session's own window sat on top of Kiln's right-hand agent panel. (The computer-use screenshots hide other apps, so this is only visible in the recording.) The demo cut avoided it by cropping to Kiln's centre pane; Analyze's agent panel is on the right, behind that window. I deleted the raw recording because it shows the session window.
- To redo it: move or minimise the Claude window (or narrow Kiln's window to under about 740 points so nothing overlaps), re-run the same prompt (the `checksum` project is already imported in Kiln's Analyze list, so the import gate will not appear unless it is removed), and record about 60 s. Full-screen control was not approved when I tried again, so this is stopped until someone is at the machine.
- Side effect left in the app: a `checksum` project in Kiln's Analyze list. Approval mode is still Ask.

## Clip 3 re-recorded (done): `site/assets/kiln-clip-reverse-engineering.mp4`

29 s, muted, portrait 1080x1920, real screen recording of Kiln 0.1.1 (still `site/assets/shots/clip-re-answer.png`). Prompt typed live in Ask mode with `gemma4:31b`; the agent explained `code_checksum` in a binary I built (FNV-1a with a 5-bit left rotate), correctly, and the last scene shows the Ghidra decompilation in Analyze for checking it. The tool list includes a failed `re_analyze_function` call; the caption says so. Notes:
- No approval gate appears in this take: the binary was already imported and analysed, and the read-only RE calls did not ask. The earlier take (with the import and analyze gates) is not usable because another window covered Kiln.
- Method: Window > Move & Resize > Left to tile Kiln so no other window overlaps, then `screencapture`, then `Scripts/make_clip_re.py`. The recording shows the whole desktop, including any other app, so crop to Kiln as the script does and check frames before using any footage.
- The "Last agent run" card in the first scene is left over from the earlier take.
- Remaining to record: clip 2 (LoRA from chat) and the real watch/phone alert.
