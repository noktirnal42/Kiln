# 90-second demo: "Fix the failing test, approve it from the Apple Watch"

Status: script and shot list, ready to record. **Nothing in this file has been recorded.** The only real footage so far is the draft stills loop in `site/assets/` (see
`README.md` in this folder). Rules: `docs/MARKETING.md` section 5. Unedited screen recording, no speed ramps over approvals, no audio claims, captions only.

## Setup (do once, off camera)

- Mac: Kiln 0.1.1 from /Applications, **Ask** mode, a hosted tool-capable model (not a 3B local model; see KNOWN-ISSUES), Remote control on, relay URL set, push key deployed.
- A throwaway Swift package, `DemoPackage`, with one failing test (an off-by-one in a function) and a git repo with a clean tree. Commit it first so the diff is visible.
- iPhone and Apple Watch paired, phone **locked and in a pocket or on the desk**, Kiln closed on the phone (this is the case the Apple push flow was verified for).
- Screen: Mac window at 1920x1080 or 2560x1440, light-on-dark, Notifications off except Kiln. Hide the project list and chat history in the sidebar (they show personal chat titles).
- Second camera or screen mirror for the watch, 4K, steady. If a watch capture is not possible, film the wrist with a phone; do not use simulator frames and do not call them a watch.
- Keep the relay and push key setup out of the video, but state it in the end card (see caption 9).

## Shot list (target 90 s)

| # | Time | On screen | Action | Must be visible | Caption |
|---|---|---|---|---|---|
| 1 | 0:00-0:06 | Terminal in Kiln Develop: `swift test` red, one failure | None. Hold. | Failing test name and assertion | "A failing test in a Swift package." |
| 2 | 0:06-0:14 | Agent tab, project = DemoPackage, mode chip says **Ask** | Type: "Fix the failing test and commit." Send | The mode chip; the model name | "Kiln in Ask mode: it will ask before consequential actions." |
| 3 | 0:14-0:26 | Agent reads files, runs the tests (read access needs no gate) | Wait | Tool calls listed as they happen | "The agent reads the code and reproduces the failure." |
| 4 | 0:26-0:38 | **Approval gate** for `write_file` or `run_command` | Do not click. Hold 4 s | Tool name, access level, the **consequence line**, the exact command, Deny / Approve Once / Always Allow | "Before it changes anything, Kiln stops and says what will happen." |
| 5 | 0:38-0:50 | Cut to wrist (or phone lock screen mirrored to watch) | Raise wrist; alert appears | The alert text and Allow once / Deny | "The Mac asked Apple to alert the iPhone; the watch mirrors it." (Add "Preview: needs a relay and an Apple push key" in 8) |
| 6 | 0:50-0:56 | Watch | Tap **Allow once** | The tap, then the answered state | "Allow once, from the watch." |
| 7 | 0:56-1:10 | Back to Mac: gate clears, agent writes fix, re-runs tests: green, then `git commit` approval handled the same way (can be answered at the Mac, say so) | Wait | Green test run; the commit message | "Tests pass. The commit was a second approval, answered at the Mac." |
| 8 | 1:10-1:22 | Audit view, newest events | Scroll to the decision | The row with `via: remote` and the wait time; audit chain head | "Every decision is recorded, including how it was answered: via: remote." |
| 9 | 1:22-1:30 | End card on plain background | None | Logo, `github.com/noktirnal42/Kiln`, "Preview 0.1.1 · MIT" | "Preview software. Remote approvals need a relay you host and an Apple push key. Not affiliated with Apple." |

Timing is a target; keep real waits if they are short, and show a visible "time passes" cut mark (a dissolve plus caption "cut: 20 s") rather than silently trimming a long wait.

## Narration (optional; the video must work muted)

Short, plain, no superlatives. 1: "Here is a failing test." 2: "I ask Kiln to fix it, in Ask mode." 4: "Before it writes, it tells me what will change." 5-6: "My phone is locked. The alert is on my wrist." 8: "The audit log records that I approved it remotely." End: "Kiln is a preview. Setup notes are in the repo."

## Hard requirements checklist

- [ ] Gate with consequence line on screen for at least 3 s
- [ ] Watch alert and the tap in the same continuous shot
- [ ] Audit row with `via: remote`
- [ ] Mode chip showing Ask
- [ ] No keys, usernames, personal chats, other projects visible
- [ ] End card states "preview", the relay and push-key cost, and non-affiliation
- [ ] No "safe", no speed or benchmark comparison with other tools

## Assembly (when raw clips exist)

Record each shot as its own file. Captions are burned in with Pillow-rendered PNG overlays because the local ffmpeg has no `drawtext`.

```sh
# normalise each clip, then concatenate
for f in raw/*.mov; do ffmpeg -i "$f" -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:-1:-1:color=0x181613,fps=30" -an -c:v libx264 -crf 20 "norm/$(basename "${f%.*}").mp4"; done
# overlay a caption PNG per shot (captions/NN.png, 1920x1080 transparent, text in the lower third)
ffmpeg -i norm/04.mp4 -i captions/04.png -filter_complex "overlay=0:0" -c:v libx264 -crf 20 out/04.mp4
# concat list then:
ffmpeg -f concat -safe 0 -i list.txt -c copy kiln-demo-90s.mp4
# 20 s muted loop for README/site: shots 4-6, 1280 wide
ffmpeg -ss 0 -t 20 -i kiln-demo-90s.mp4 -vf "scale=1280:-2,fps=24" -an -c:v libx264 -crf 24 -movflags +faststart kiln-loop.mp4
# README GIF (GitHub does not autoplay mp4 in READMEs)
ffmpeg -i kiln-loop.mp4 -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" kiln-loop.gif
```
