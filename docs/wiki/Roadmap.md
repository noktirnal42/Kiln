# Roadmap

The integration branch contains eleven registered activities. The latest public preview can lag behind the development branch; see [releases](https://github.com/noktirnal42/Kiln/releases) and the [current state](https://github.com/noktirnal42/Kiln/blob/main/docs/11-CURRENT-STATE.md) for verification limits. Proposals below are not shipped promises.

## Built on the integration branch

- Home, Agent, Swarm, Develop, Analyze, Lab, Audit, Browser, Devices, Media and Images.
- Agent platform with memory, slash commands, hooks, plans, sessions, checkpoints, usage and schedules, subject to the verification limits in current state.
- Image studio has generated images with SD-Turbo locally; other models and external engines need separate verification.
- Develop and Analyze include editor, debugging and reverse-engineering features; important parity gaps remain.

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
