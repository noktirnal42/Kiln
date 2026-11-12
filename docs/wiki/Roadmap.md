# Roadmap

Kiln has 21 registered activities. The published preview (0.1.1, 2026-11-03) is far behind the current source on `main`; see [releases](https://github.com/noktirnal42/Kiln/releases) and the [current state](https://github.com/noktirnal42/Kiln/blob/main/docs/11-CURRENT-STATE.md) for verification limits. Proposals below are not shipped promises.

## Built, and in the current source

- Home, Agent, Swarm, Develop, Analyze, Lab, Audit, Browser, Devices, Media, Images, Maps and News.
- Agent platform with memory files, slash commands, hooks, plan mode, checkpoints and rewind, sessions, usage and cost, and scheduled tasks, subject to the verification limits in current state.
- Tools loaded on demand to save context, a context meter that reflects what is loaded, and a browser that identifies as Safari.
- Develop and Analyze include editor, debugging and reverse-engineering features; important parity gaps remain.

## Built as development builds (tested with fakes; not yet verified against real accounts or data)

Mail, Contacts, Messages, Calendar and Reminders, GitHub pull requests and CI, PDF annotation with a research library and citations, cloud drive folders, Apple Notes, Spotlight indexing of conversations (Off by default), and Shortcuts for every activity plus "Ask Kiln". Their empty states and permission screens have been seen on screen, and Calendar read real events; nothing else has met real data. See [[Activities]] for their limits and [[Security and Privacy]] for the permissions they need.

## Planned, in the owner's priority order

Slack and chat connectors; Notification Center and Focus awareness; a menu-bar quick-ask and Share extension; Writing Tools and Services-menu actions; weather and a radar layer on the Maps view (sources and terms still to be verified); a document, spreadsheet and presentation studio. Details are in the [feature roadmap](https://github.com/noktirnal42/Kiln/blob/main/docs/21-EVERYTHING-APP-ROADMAP.md).

## Next

Make the foundation dependable (streaming, tool correctness, clear failures); agent tools for the registry gaps (swarm control, audit queries, project selection); swarm workers that load tools on demand; a layout with a title-bar icon row and a canvas beside the thread; companion apps that stay reachable in the background; accessibility and narrow-window layouts.

## Horizon (proposals)

Evidence ledger and signed run bundles; Pinboard context tray; saved workflows; closed-loop app analysis; verifier agent; privacy tiers and local-first routing; time-travel workspace; mission control; project knowledge graph; policy as code; agent-driven QA.

## Waiting on others

Browser passkeys need an Apple entitlement that has been requested but not granted. iCloud sync, push for new features and Private Cloud Compute are not verified in any build. Windows and Linux guests in Devices are a design only.

## Definition of done

A service, a GUI, an agent tool and MCP tool, a palette entry, an audit record, tests, and a screenshot of it working in the app recorded under `docs/qa/`.

---

**Verified status.** Items are copied from `docs/21-EVERYTHING-APP-ROADMAP.md`, `docs/17-PARITY-AND-BEYOND.md`, `docs/20-APPLE-CAPABILITIES.md` and `docs/18-BROWSER-AUTHENTICATION.md`; check the tracker and current state before relying on a feature. Maps and News status and verification are in [Maps and News](https://github.com/noktirnal42/Kiln/blob/main/docs/23-MAPS-AND-NEWS.md); competitive research is in the [parity research](https://github.com/noktirnal42/Kiln/blob/main/docs/22-PARITY-RESEARCH-2026-11-10.md).
