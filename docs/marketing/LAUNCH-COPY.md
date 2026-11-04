# Launch copy drafts

Draft only. Do not post. Per `docs/MARKETING.md` section 5: say preview, state setup costs, no benchmarks, never "safe". Attach the demo clip once it is recorded; until then
do not post (Phase 0 readiness). Repo: https://github.com/noktirnal42/Kiln · Site: https://noktirnal42.github.io/Kiln/ · Not affiliated with Apple, Anthropic, OpenAI or Ghidra.
Be present for replies all day; disclose you are the author.

## r/swift

**Title:** Kiln: a native SwiftUI Mac app for supervising AI agents, with approvals you can answer from your Apple Watch (preview, MIT)

I've been building Kiln, a Swift 6 / SwiftUI workshop for AI agents on the Mac. The idea is that the agent does real work (edit files, run `swift test`, commit) but each consequential action stops at an approval gate with a plain-language consequence line, in one of three modes (Ask, Auto, Bypass). Every decision is written to a hash-chained audit log that also records how it was answered.

The part I'd like Swift people's eyes on: the iPhone/Watch companions. The Mac asks Apple (via a small relay I host) to alert the phone, the alert mirrors to the watch, and Allow once / Deny work from the lock screen. The channel is sealed with ChaCha20-Poly1305, so the relay only forwards ciphertext. Writeup of the protocol is in `docs/14-REMOTE-CONTROL.md`.

Honest state: this is a **preview** (0.1.1, notarized). The remote approval flow was verified on one iPhone and one watch; reconnect reliability and push delivery under many alerts are not. Setting it up means hosting the relay (a Cloudflare Worker or Node) and creating an Apple push key. The Mac app builds with XcodeGen and has 592 tests. The companions are source only (no TestFlight yet).

Feedback welcome, especially on strict-concurrency patterns and the approval UI. Issues labelled good first issue are open.

## r/iOSProgramming

**Title:** Approving AI agent actions from an Apple Watch: what I learned wiring relay + APNs + watchOS (open source)

Short technical angle, since the app itself is Mac-side. Findings from building the companion path for Kiln (a Mac agent app):
- A raw `NWConnection` from watchOS doesn't get the iPhone's proxying; `URLSession` WebSockets do. That's why direct LAN sockets time out on a real watch and the relay goes first.
- The Mac waits about 4 seconds on a pending approval, then asks the relay to push; the relay signs the APNs token with a key it keeps as a secret and stores no device tokens.
- Notification actions (Allow once / Deny) reconnect first, then answer. Verified on a physical iPhone 16 Pro Max with the app closed; the watch's own buttons when the phone is far away are not verified.
Costs: you host the relay and need an Apple Developer account for the push key. Preview software; companions are source-only. Repo and the protocol doc: [links]. Happy to answer questions about the pairing/encryption design.

## r/LocalLLaMA

**Title:** Kiln: Mac app where an agent drives MLX LoRA/distillation through approval gates (works with Ollama/MLX locally; preview)

Open-source Swift app (MIT). The agent can start MLX fine-tuning and distillation jobs as tools, and each one passes an approval gate. It talks to local MLX and Ollama, Apple Foundation Models, or hosted providers.

What's verified: MLX from-scratch and LoRA smoke runs saved real artifacts through the agent tools; five providers were checked in live chat. What isn't: model quality of anything those tiny runs produce, and the full GUI lifecycle (cancel, reload, export). Small local models (I tried a 3B coder) often fail tool use; Kiln blocks empty or simulated tool-call results and tells you the run didn't finish instead of pretending. Tool-capable models work best.

Apple silicon only for the MLX parts. Preview, rough edges, see `docs/KNOWN-ISSUES.md`. No benchmarks claimed. [link]

## r/macapps

**Title:** Kiln (free, open source, preview): a native Mac workshop for AI agents you can supervise

Native SwiftUI, notarized DMG, MIT. Chat with local or hosted models, give the agent file/shell/git tools, and approve what it does: an approval gate shows what will happen, with Ask / Auto / Bypass modes and an audit log. There's also a reverse-engineering side (Mach-O inspection, optional Ghidra) and a model-training lab.
Optional: pair an iPhone or Apple Watch to approve from the lock screen. That needs a relay you host and an Apple push key, so it's for tinkerers. The Mac app works without any of it.
It's a **preview** with known gaps (see the known-issues page); not Xcode, not a polished consumer app. Runs unsandboxed, which is why the approval gates exist. Download: [releases]. I'm the developer.

## Show HN

**Title:** Show HN: Kiln – a native Mac workshop for AI agents you can supervise (Swift, MIT)

**First comment:**
Hi HN, I'm the author. Kiln is a Swift/SwiftUI Mac app where an agent can read and write files, run commands, use git, drive Ghidra/radare2 and start MLX training jobs. It is not sandboxed, so supervision is the whole design: every consequential tool call stops at an approval gate that states in plain language what will happen; there are Ask / Auto / Bypass modes; a behavior monitor can hold a run; and each decision goes into a hash-chained audit log that also records how it was answered (mouse, keyboard, remote).

Remote answers are the part I'm most curious about: the Mac asks Apple to alert your iPhone, the alert mirrors to the watch, and Allow once / Deny work from the lock screen. Frames are end-to-end sealed; the relay (a Cloudflare Worker you host) sees only a room name. Setup cost is real: hosting that relay and an Apple push key.

What's unfinished: this is 0.1.1, a preview. Remote approvals were verified on one phone and watch; reconnect reliability, push latency across many alerts and Auto mode as a daily driver are not. Companions aren't on TestFlight. Small local models often fail tool use. There is no first-run flow yet, so setup is rough. A known issue about unexpected standing approvals during testing is still under investigation.

Help I'd value: break the approval gate and the audit chain, review the relay and encryption design, and tell me whether the supervision model is something you'd actually use. Known issues are documented in the repo. No benchmark claims against other tools; it isn't trying to out-model them.

## Mastodon / Bluesky thread (5 posts)

1/ I built an open-source Mac app for AI agents you can supervise. It's called Kiln, it's Swift, MIT, and a preview (0.1.1). [clip] 
2/ Every consequential action an agent takes stops at an approval gate that says what will happen. Ask / Auto / Bypass modes. Each decision is logged, including how it was answered.
3/ The bit I like: the Mac asks Apple to alert your iPhone, it mirrors to your Apple Watch, and you tap Allow once. The log says via: remote.
4/ Honest costs: that needs a relay you host and an Apple push key. Companions are source only. Reconnect reliability is still being tested. The Mac app works fine without any of it.
5/ Also: reverse engineering (Mach-O, optional Ghidra) and MLX LoRA from chat, all through the same gates. Not affiliated with Apple. Repo + known issues: [link] #swift #macOS #opensource
