# Kiln marketing strategy

Status: draft for the maintainer, written 2026-11-03 against Kiln 0.1.1 (preview). Everything claimed here is something Kiln can show today;
the "not yet" list at the end is what must not be promised.

## 1. The one-sentence position

**Kiln is a native Mac workshop where AI agents do real work and you stay in control of them, from your desk or from your wrist.**

Shorter forms, for different places:

| Where | Line |
|---|---|
| Hero headline | *Agents that work. Hands that stay on the controls.* |
| README / repo description | A native macOS workshop for supervised AI agents: code, reverse engineering and model training in one app, with approvals you can answer from your iPhone or Apple Watch. |
| Social bio / one breath | Open-source Mac app for AI agents you can supervise. |
| Show HN title | Show HN: Kiln – a native Mac workshop for AI agents you can supervise (Swift, MIT) |

## 2. Why this can win a place at all

The agent-tool market is crowded with terminal agents and editor plugins. Kiln does not out-feature them on raw model capability, and should not try.
It wins on three things the others do not combine:

1. **Supervision as a product, not a footnote.** Every consequential action goes through an approval gate with a plain-language consequence line; there are three
   explicit modes (Ask, Auto, Bypass); a behavior monitor can hold a run; and every decision is written to a tamper-evident audit chain that records *how* it was
   answered (mouse, keyboard, remote, mode). Nobody else makes "who approved this, and how" a first-class, inspectable record.
2. **Approve from anywhere.** The Mac asks Apple to alert your iPhone, the alert mirrors to your Apple Watch, and Allow once / Deny work from the lock screen. This is
   verified on real hardware. For people who start an agent and walk away, this is the feature that changes the workflow.
3. **One native app, three disciplines.** Coding (editor, language server, LLDB), reverse engineering (Ghidra, radare2, native Mach-O), and model work (Create ML,
   MLX fine-tuning, distillation) share one agent, one set of tools and one audit trail. Swift and SwiftUI, not a browser wrapper.

Supporting facts: bring any model (local MLX and Ollama, Apple Foundation Models, hosted providers); MIT licensed; Developer ID signed and notarized; 592 tests on the Mac.

## 3. Who it is for, in order

| Segment | Why Kiln | How to reach them | What they need to see in 60 seconds |
|---|---|---|---|
| **A. Apple-platform developers who already use Claude Code, Codex or OpenCode** | Native, supervised, Swift-first; sees their Xcode world | r/swift, r/iOSProgramming, Swift forums, Mastodon/Bluesky dev circles, iOS Dev Weekly, Swift Weekly | The failing-test-fixed-and-committed demo, then the approval on the watch |
| **B. Local-model enthusiasts on Apple silicon** | MLX, LoRA and distillation driven from chat; no cloud required | r/LocalLLaMA, MLX community, Hugging Face spaces | A LoRA run started by the agent, with the approval and the loss curve |
| **C. Security and reverse-engineering people** | Agent plus Ghidra/radare2 with an audit trail | r/ReverseEngineering, Mastodon infosec | An agent explaining a function it disassembled, with every tool call listed |
| **D. People who worry about agents** (security-minded devs, small teams) | Approvals, modes, hard blocks, audit chain | Hacker News, Lobsters, security newsletters | The destructive-command approval and the audit log |

Segment A is the beachhead: largest, closest to the product, and the most likely to contribute. B and C are the credibility multipliers. D is the story that
gets Kiln shared beyond Mac developers.

## 4. Messaging pillars (and the proof behind each)

1. **Real work, supervised.** Proof: the agent ran the tests, found the bug, fixed it and committed with a clear message; Ask / Auto / Bypass; every decision
   logged with how it arrived. *Never* say "safe": say what the gates are and show the log.
2. **Approve from your wrist.** Proof: an Ask-mode approval raised on the Mac, answered from a locked phone's alert, logged as `via: remote`. State the setup cost
   honestly (a relay you host and an Apple push key).
3. **Any model, your hardware.** Proof: five providers verified in live chat; MLX LoRA and distillation completed end to end through agent tools.
4. **Beyond code.** Proof: Ghidra and radare2 engines, native Mach-O inspection, Model Lab, all driven by the same agent.
5. **Open and inspectable.** Proof: MIT, public issues, a QA record that lists what was *not* verified. Honesty is part of the brand: the docs say what does not work.

## 5. Voice and honesty rules

- Preview software. Say "preview" wherever a download is offered. Do not claim Xcode, Ghidra or production-platform parity.
- Claims map one-to-one to evidence in `docs/11-CURRENT-STATE.md`, `docs/KNOWN-ISSUES.md` and the release notes. If it is not verified there, it is not on the site.
- Show failures that teach: the "model stopped without an answer" notice, hard blocks, the unsandboxed trade-off explained plainly.
- No fake screenshots, no staged "AI wrote this" claims, no benchmark claims against other tools. Demos are unedited screen recordings with the approvals visible.
- Credit and disclaim: not affiliated with Apple, Anthropic, OpenAI or Ghidra.

## 6. Assets, and where each stands

| Asset | Status |
|---|---|
| Notarized download (DMG, ZIP, checksums) | Done (v0.1.1 pre-release) |
| Site with real product screenshots and a clear download path | Done (redesign landed) |
| 90-second demo video: "fix the failing test, approve it from the watch" | Script drafted (`docs/marketing/VIDEO-SCRIPT.md`). A real-footage draft cut exists (`site/assets/kiln-demo-draft.mp4`, Mac plus iOS Simulator, two approvals logged `via: remote`). **Still to record**: the real watch/iPhone alert; see `docs/marketing/README.md` |
| Three short clips (each under 30 s, no audio needed): approval from watch, LoRA from chat, reverse-engineering a function | Clip 1 (approval): 22 s real-footage loop, simulator phone, no watch. Clip 3 (reverse-engineering): 29 s real footage done. Clip 2 (LoRA from chat): 30 s real footage done (smoke run, quality not evaluated) |
| README hero image or GIF | Done as a GIF in the README (from the draft cut); replace with a watch shot when recorded |
| Architecture post: how the audit chain and approval gate work | To write |
| Architecture post: approving agent actions from an Apple Watch (relay, push, end-to-end encryption) | To write; this is the most shareable technical story |
| Contributor onboarding (good first issues, CONTRIBUTING) | Exists; keep issues labelled |
| First-run flow (pick a project, one model, one key) | Not built; the biggest conversion gap, see section 9 |

Launch copy drafts for r/swift, r/iOSProgramming, r/LocalLLaMA, r/macapps, Show HN and a Mastodon/Bluesky thread: `docs/marketing/LAUNCH-COPY.md` (nothing posted).

## 7. Launch sequence

**Phase 0: readiness (before any announcement).** Site live with screenshots; demo video recorded; README top section shows the product in one screen; the download
installs and opens on a clean Mac; known issues page current; a short "what to try first" section (a sample project and a three-step path to the first approval).

**Phase 1: soft launch (week 1).** Post to the small, relevant communities where the author can answer questions all day: r/swift and r/iOSProgramming (the
Apple-developer angle), r/LocalLLaMA (the MLX/LoRA angle), r/macapps. One post per community, written for that community, lead with the demo clip. Reply to every comment.
Fix what real users hit; ship 0.1.2 within the week to show momentum.

**Phase 2: Show HN (week 2).** Only after phase 1 fixes land. Title in section 1; first comment explains what it is, what is unfinished, and what the maintainer wants help
with. Lead with the supervision story (segment D), not "another coding agent".

**Phase 3: sustained content (weeks 3-8).** One technical post every two weeks: the audit chain, the watch approval architecture, why Kiln is unsandboxed and how approvals
compensate, Swift 6 strict-concurrency lessons (the first-use speech crash is a good, honest story). Submit to Swift Weekly and iOS Dev Weekly. Product Hunt only
once a first-run flow exists, since PH visitors bounce on setup friction.

**Phase 4: community.** GitHub Discussions for questions, a public roadmap tied to issues, a monthly "what shipped" note, and a regular small contribution list.

## 8. What to measure (weekly, simple)

- Release downloads (asset download counts on GitHub) and repository stars.
- Clones and unique visitors (GitHub traffic), and where they come from.
- Issues and pull requests opened by people other than the maintainer.
- Time to first response on issues; this is the strongest retention signal for a small project.
- Qualitative: the first sentence new users use to describe Kiln. If it is not about supervision or the watch, the messaging is off.

Do not chase stars as the goal; one engaged contributor is worth more than a thousand stars.

## 9. Product work that marketing depends on

1. **First-run flow** (project, one model, one key, one safe first task). Without it, installs do not turn into a first success.
2. **A "demo project"** bundled or one click away, so the supervised-agent story can be tried without setting anything up.
3. **Companion apps in a usable form.** They are source only today; a TestFlight build needs an Apple developer account review and production push. Until then, describe them as
   "build it yourself" and show the video.
4. **Reliability honesty**: keep the evidence layer and the no-answer notice; they are marketing assets because they make failure visible.
5. **Name check**: "Kiln" is a common word and other products use it. Search trademarks and app names before a larger launch, and keep the repository and bundle identifiers consistent.

## 10. Risks

| Risk | Response |
|---|---|
| "Unsandboxed AI agent" reads as dangerous | Lead with the approval gate, hard blocks and the audit chain; explain the trade-off in one clear paragraph and a blog post |
| Setup friction (keys, models, relay) kills first impressions | First-run flow; a local-model path that needs no account; the relay is optional |
| Small models fail tool use | State it; surface it as "the agent will tell you when it did not finish" |
| Overclaiming gets screenshotted | The honesty rules in section 5; every claim traceable to the QA record |
| One maintainer, many surfaces | Keep scope visible; label issues so contributors can take whole areas |

## 11. Not yet, so do not promise

Approval alerts for a closed app on production-signed builds; alert delivery speed across many approvals; Auto mode as a daily driver (only exercised in a short run); voice
accuracy; companion apps on the App Store or TestFlight; parity with Xcode, Ghidra or a production model platform; Windows or Linux.
