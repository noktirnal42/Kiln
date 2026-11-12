# Roadmap

The integration branch contains thirteen registered activities, and the development branch five more (Mail, Calendar, Contacts, Messages, GitHub). The latest public preview can lag behind the development branch; see [releases](https://github.com/noktirnal42/Kiln/releases) and the [current state](https://github.com/noktirnal42/Kiln/blob/main/docs/11-CURRENT-STATE.md) for verification limits. Proposals below are not shipped promises.

## Built on the integration branch

- Home, Agent, Swarm, Develop, Analyze, Lab, Audit, Browser, Devices, Media and Images.
- Agent platform with memory, slash commands, hooks, plans, sessions, checkpoints, usage and schedules, subject to the verification limits in current state.
- Image studio has generated images with SD-Turbo locally; other models and external engines need separate verification.
- Develop and Analyze include editor, debugging and reverse-engineering features; important parity gaps remain.

## In development (tested with fakes; not yet verified against real accounts)

Mail, Contacts, Messages, Calendar and Reminders, GitHub pull requests and CI, PDF annotation with a research library and citations, and Shortcuts for every activity plus "Ask Kiln". See [[Activities]] for their limits and [[Security and Privacy]] for the permissions they need.

## Planned, in the owner's priority order

Spotlight indexing of conversations and artifacts (on its own branch); cloud drives; Notes; Slack and chat connectors; Notification Center and Focus awareness; a menu-bar quick-ask and Share extension; Writing Tools and Services-menu actions; weather and a radar layer on the Maps view (sources and terms still to be verified); a document, spreadsheet and presentation studio. Details are in the [feature roadmap](https://github.com/noktirnal42/Kiln/blob/main/docs/21-EVERYTHING-APP-ROADMAP.md).

## Next

Make the foundation dependable (streaming, tool correctness, clear failures); agent tools for the registry gaps (swarm control, audit queries, build and debug, project selection); companion apps that stay reachable in the background; accessibility and narrow-window layouts.

## Horizon (proposals)

Evidence ledger and signed run bundles; Pinboard context tray; saved workflows; closed-loop app analysis; verifier agent; privacy tiers and local-first routing; time-travel workspace; mission control; project knowledge graph; policy as code; agent-driven QA.

## Waiting on others

Browser passkeys need an Apple entitlement that has been requested but not granted. iCloud sync, push for new features and Private Cloud Compute are not verified in any build. Windows and Linux guests in Devices are a design only.

## Definition of done

A service, a GUI, an agent tool and MCP tool, a palette entry, an audit record, tests, and a screenshot of it working in the app recorded under `docs/qa/`.

---

**Verified status.** Items are copied from `docs/17-PARITY-AND-BEYOND.md`, `docs/20-APPLE-CAPABILITIES.md` and `docs/18-BROWSER-AUTHENTICATION.md`; check the tracker and current state before relying on a feature.

## Maps proposal

Explore a native MapKit activity with USGS current topography, historical-sheet discovery, georeferenced overlays, source attribution and approval-gated downloads. It is a proposal, not a shipped activity. See the [research and acceptance criteria](https://github.com/noktirnal42/Kiln/blob/main/docs/21-EVERYTHING-APP-ROADMAP.md).

Maps and News have initial development implementations; routing, location permissions, live feed workflows and complete end-to-end agent/MCP checks need further verification. [Status](https://github.com/noktirnal42/Kiln/blob/main/docs/23-MAPS-AND-NEWS.md) · [Competitive research](https://github.com/noktirnal42/Kiln/blob/main/docs/22-PARITY-RESEARCH-2026-11-10.md).

The [parity research](https://github.com/noktirnal42/Kiln/blob/main/docs/22-PARITY-RESEARCH-2026-11-10.md) tracks current gaps, planned improvements and proposed activities. Maps and News status and verification are documented [here](https://github.com/noktirnal42/Kiln/blob/main/docs/23-MAPS-AND-NEWS.md).
