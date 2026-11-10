# FAQ

**Is Kiln finished?** No. It is a preview with real, verified capabilities and substantial open areas. See [[Roadmap]] and `docs/KNOWN-ISSUES.md`.

**Does it replace Xcode, Ghidra or LM Studio?** No. Develop is a capable editor, not Xcode; Analyze uses an installed Ghidra for decompilation; Lab trains small models and is not a production platform.

**Which Macs?** The deployment target is macOS 15 and development uses Xcode 27. Apple silicon is recommended and the MLX workflows are not covered on Intel.

**Do I need an API key?** No. Use Apple Foundation Models or a local Ollama model. Hosted providers need your own key. See [[Providers and Keys]].

**Where are my keys and data?** Keys are in the macOS Keychain. Data lives in `~/Library/Application Support/Kiln`. An earlier version stored data in an app container; a one-time migration copies it and never deletes the container.

**Is it sandboxed? Is it safe to let the agent run commands?** It is not sandboxed. The safety layer is approvals, policy gates, a behavior monitor, tripwires and the audit chain. Read commands before allowing them. See [[Security and Privacy]].

**What does Bypass do?** Approves everything except hard policy blocks and monitor holds, for one answer at a time, and resets to Ask on relaunch. Use it deliberately.

**Can other tools use Kiln's tools?** Yes: start the MCP server in Develop → MCP. See [[MCP Server and Tools]].

**Can I control Kiln from my phone or watch?** You can read the conversation, send messages and allow once or deny approvals with the companion apps, which you build yourself. See [[Activities]]. Physical-device coverage is partial.

**Does it support passkeys or iCloud sync? Siri? Private Cloud Compute?** Not as verified features. The browser passkey entitlement has been requested and not granted; iCloud sync is not implemented or verified; Private Cloud Compute is an untested provider in development; Siri is not covered by the verified documentation and should not be assumed. See [[Browser]] and [[Providers and Keys]].

**Why does a small local model fail at tasks?** Chat and tool use are different skills; see [[Troubleshooting]].

**Can the agent do everything the GUI can?** No. The registry lists gaps; see [[MCP Server and Tools]].

**What license is it under?** See the LICENSE file in the repository.

**Is the image studio available?** No. It is planned; see [[Roadmap]].

**Is Kiln affiliated with Apple, Anthropic, OpenAI or Ghidra?** No.

---

**Verified status.** Answers are taken from the repository documents named on the linked pages. **Not checked:** a user-testing pass of these answers.
