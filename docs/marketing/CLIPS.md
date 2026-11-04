# Three short clips (each under 30 s, muted, captions only)

Status: storyboards, none recorded. Each clip must be an unedited screen recording with the approval visible; captions are burned in. Mark waits with a cut caption.

## Clip 1: approve from the watch (about 20 s)

Segment A and D. Prereqs as in `VIDEO-SCRIPT.md`.
1. 0-4 s Mac, Ask mode, agent asks to run `swift test`. Gate on screen with consequence line. Caption: "The agent asks first."
2. 4-12 s Wrist shot: alert appears with the phone locked. Caption: "Alert on the watch. Phone locked."
3. 12-16 s Tap Allow once. Caption: "Allow once."
4. 16-20 s Mac: gate clears, run continues; audit row `via: remote`. Caption: "Logged as via: remote."
End slate: "Preview. Needs a relay and an Apple push key."

## Clip 2: LoRA from chat (about 28 s)

Segment B. Prereqs: Apple silicon, a small MLX model downloaded, a tiny dataset (a few hundred rows) already in Model Lab, nothing else running. Verified in QA: LoRA smoke run saved an adapter. Do not claim model quality.
1. 0-5 s Chat: "Fine-tune a LoRA adapter on dataset X with model Y, 50 iterations." Caption: "Ask for a LoRA run in chat."
2. 5-10 s Approval gate for the training tool; click Approve Once. Caption: "Training is an approval, like any tool."
3. 10-22 s Model Lab: loss curve updating in real time (cut caption if sped up). Caption: "The same run, in Model Lab. Loss every step." (Say "smoke run" if the run is tiny.)
4. 22-28 s Adapter saved, listed in the experiment. Caption: "Adapter saved. Quality not evaluated."
Risk: GUI lifecycle coverage is incomplete (KNOWN-ISSUES). Do a dry run; if the GUI misbehaves, record the failure honestly and file an issue instead.

## Clip 3: reverse-engineering a function (about 28 s)

Segment C. Prereqs: a small Mach-O you built yourself (your own binary, not someone else's), Ghidra optional. Native Mach-O inspection works; linear disassembly fallback is labelled in the app.
1. 0-5 s Analyze: import the binary, functions list. Caption: "Import a binary you own."
2. 5-12 s Chat: "What does the function at <addr> do?" Tool calls stream: disassemble, strings. Caption: "Every tool call is listed."
3. 12-22 s Agent answers in plain language; show the disassembly beside it. Caption: "The agent explains; you can check the disassembly."
4. 22-28 s Audit view with the tool calls. Caption: "And it is all in the audit log."
Do not use the stripped-binary fallback as a "decompiler" claim; show the "linear listing" label if it appears.

## To-record list across all four

Real watch footage; relay and push configured; a demo Swift package with a failing test; an MLX LoRA dataset; a self-built Mach-O. See `README.md` for the current status.
