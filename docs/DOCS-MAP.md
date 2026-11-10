# Documentation map

Kiln's public documentation lives in four places. This page says which one is authoritative for what, and how to keep them in step.

## Authoritative sources

| Question | Authoritative document | Notes |
|---|---|---|
| What exists, how it was checked, what is open | [11-CURRENT-STATE.md](11-CURRENT-STATE.md) | Newer facts win over older specs |
| Known gaps and verification limits | [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | The issue tracker owns assignment and status |
| What the agent can and cannot operate, tool contracts, registry gaps | [13-AGENT-CAPABILITY-MATRIX.md](13-AGENT-CAPABILITY-MATRIX.md) | Registry gap ids mirror `Core/Registry/` |
| Planned work, parity bar, novel features | [17-PARITY-AND-BEYOND.md](17-PARITY-AND-BEYOND.md) | Everything here is a plan, not a claim |
| Browser sign-in and passkey status | [18-BROWSER-AUTHENTICATION.md](18-BROWSER-AUTHENTICATION.md) | Keep its "unverified" wording |
| Apple capabilities, Private Cloud Compute, entitlements | [20-APPLE-CAPABILITIES.md](20-APPLE-CAPABILITIES.md) | Enabled capability is not a feature |
| Devices, Ghidra, remote control | [16-DEVICES.md](16-DEVICES.md), [GHIDRA.md](GHIDRA.md), [14-REMOTE-CONTROL.md](14-REMOTE-CONTROL.md) | |
| Clean-clone build and first contribution | [GETTING-STARTED.md](GETTING-STARTED.md) | |
| Signing, notarization, releases, CI | [RELEASING.md](RELEASING.md) | |
| Which activities exist and their order and shortcuts | `Core/Registry/ActivityCatalog.swift` | The code is the source; docs follow it |
| Vision and design intent | [00-MASTER-SPEC.md](00-MASTER-SPEC.md) and the numbered specs | Not completion claims |
| License | the `LICENSE` file | Docs only say "see LICENSE"; the license is decided separately |

## Where each audience reads

| Surface | File | Role |
|---|---|---|
| README | [README.md](../README.md) | Front door: what Kiln is, activities, providers, safety, install, roadmap summary |
| Website | `site/` (deployed by `.github/workflows/pages.yml`) | Marketing and overview pages: home, activities, agent and MCP, docs, roadmap, contribute, support |
| Wiki | [wiki/](wiki/Home.md) | Task-oriented guides, one page per topic, each ending in a *Verified status* note |
| Repository docs | `docs/` | The source of truth the other three summarize |

Public surfaces summarize and link; they never add a claim the authoritative documents do not make. Keep "unverified", "unsigned" and "awaiting Apple approval" wording intact.

## Updating after a change

1. **Change the authoritative document first** (state what you verified and what you did not).
2. **README:** update the activity table, provider table, safety text or roadmap if the change touches them.
3. **Site:** update `site/activities.html`, `site/agent.html`, `site/roadmap.html` or `site/docs.html`. Navigation is repeated in each page's header; change it in every file.
4. **Wiki:** edit the matching file in `docs/wiki/`. Pages use flat names (`Getting-Started.md`) and `[[Page Name]]` links; refer to repository files with backticks or full URLs, since relative links do not work in the wiki. Keep the *Verified status* note current.
5. **Roadmap items** move from "planned" to "built" only when the feature is merged and has been seen working; update README, `site/roadmap.html` and `wiki/Roadmap.md` together.
6. **Run the checks:**
   ```sh
   Scripts/check-docs.sh
   ```
   It runs `Scripts/check_site.py` (site links, anchors, alt text, landmarks), then checks README links and images, wiki `[[links]]` and anchors, the Verified status notes, and scans public docs for personal paths, email addresses and key-like tokens. It does not fetch external URLs.

## Publishing the wiki

The wiki is a separate Git repository (`Kiln.wiki.git`). To publish, clone it and copy the files from `docs/wiki/` over its contents (the file names already match, including `_Sidebar.md` and `_Footer.md`), commit and push. The repository copy stays the reviewed source; do not edit the wiki on GitHub directly, or the next copy will overwrite it.
