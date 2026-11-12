# Kiln: product gaps and Maps proposal

Research snapshot: 2026-11-10. This is a roadmap. Maps and News now have initial development implementations; see [their status](23-MAPS-AND-NEWS.md) for verification and gaps. Other ideas remain proposals. The current implementation and its verification limits are in [Current state](11-CURRENT-STATE.md); work items are in the [issue tracker](https://github.com/noktirnal42/Kiln/issues).

## Product direction

The opportunity is a single native workstation where a person can move evidence, files and context between specialized activities while supervising agents. Breadth alone is not a quality bar: each workflow needs usable output, truthful progress, explicit approval for consequential actions, cancellation, recovery and independently reproducible evidence.

## Priorities

1. **Reliability first:** complete visible streaming and Stop/retry checks; prove artifact-based verification against both successful and failing local models; improve long-running job recovery, clear errors, and per-provider timing. Finish native accessibility, narrow windows and keyboard/VoiceOver checks. Resolve the open issues before calling the foundation complete.
2. **Shared context and evidence:** a Pinboard holding selected files, URLs, map extents, datasets and outputs; citations and provenance carried through a run; an inspectable evidence ledger and exportable run bundles. Permission scope must follow the actual data and destination.
3. **Workflows and orchestration:** resumable multi-step workflows, dependencies, retries, budgets, cancellation, isolated worktrees, reviewable plans and artifacts, plus a mission-control view. Compare real outcomes, not the number of cooperating agents. Cursor documents remote background agents with status, follow-up and takeover; this is a useful benchmark, not evidence of Kiln parity. [Cursor background agents](https://docs.cursor.com/background-agent)
4. **Complete existing activities:** a robust Develop debugger and editor, reliable Analyze/Ghidra workflows, full Lab training and export verification, browser downloads/history, device control and companion reconnects, media editing and source-backed image-generation capabilities. The [capability matrix](13-AGENT-CAPABILITY-MATRIX.md) records specific missing tool adapters.
5. **Additional activities:** Maps and geospatial research; a research library for documents, citations and archives; spreadsheets and data analysis; a document/presentation studio; and integrations for calendars, communications and project trackers. Build these around real user workflows and narrowly scoped permissions, not placeholder tabs.

## Communications: requested work

These are planned capabilities, not existing integrations. Build each through a Core service, a usable interface, agent and MCP tools, auditable state changes, and tests under the parity contract. A communications workspace should sit beside chat where the window has room, and agents should show their draft and destination before a user-approved external send.

- **Email:** multi-account setup and account-scoped permissions; IMAP/SMTP and provider APIs where supported, with OAuth where available; unified and per-account inboxes, folders/labels, threading, read/unread, stars, archive, delete and restore; search, filters and sorting; compose, reply, reply-all, forward, attachments, signatures, drafts, scheduled send and delivery/error status; contact/address completion, offline cache and synchronization recovery. Add reviewable agent-assisted search, summaries and drafting, with explicit approval for sends and other consequential changes. Verify real inbound/outbound messages, attachments, account isolation, conflict recovery and revocation before claiming support.
- **Apple-compatible messaging:** research supported ways to initiate a user-reviewed message through Apple Messages and, separately, any supported iPhone/iPad Messages extension. Evaluate message composition, recipients, attachments and handoff, with status and permissions accurately shown. Do not claim inbox sync, silent sending, iMessage protocol interoperability or feature parity until a supported integration and end-to-end tests establish them. Apple's [Messages framework](https://developer.apple.com/documentation/messages) documents iMessage apps and extensions; it does not by itself establish a general macOS Messages inbox API. Apple's [MailKit](https://developer.apple.com/documentation/mailkit) documents extensions to Apple Mail, rather than a general standalone email account client.
- **Shared requirements:** account and destination visibility, attachment and content preview, clear local versus provider storage, permission revocation, accessibility, searchable history where the provider permits it, reliable cancellation and delivery status, and tests for failed authentication, offline operation, duplicates and mistaken recipients. Keep unsent drafts local until the user chooses to send.

## Proposed Maps activity

**First release:** native MapKit view with search, coordinate entry, pins, measurement, layer selection and a shareable map extent. Add a USGS current topographic layer, an explicit legend/attribution and a visible offline/error state. Save map state as a project artifact. Provide read-only agent tools to search locations, inspect the viewport and list sources; require approval for downloads, writes and network actions under the existing policy. MapKit supports native maps and tile overlays; the precise service tiling scheme and projection must be verified against the USGS service before implementation. [Apple MapKit](https://developer.apple.com/documentation/mapkit), [Apple overlay documentation](https://developer.apple.com/documentation/mapkit/displaying-overlays-on-a-map?language=objc), [USGS basemap services](https://www.usgs.gov/faqs/what-are-base-map-services-or-urls-used-national-map)

**Historical maps:** search National Map products by location, date and scale; present individual sheet metadata, preview and user-initiated download. GeoTIFFs contain georeferencing, but displaying a scan in the right place requires projection/extent handling and validation; do not present them as a seamless historical basemap. Provide side-by-side or opacity comparison with dates and source metadata. USGS documents topoView and the National Map API for discovery and downloads. [USGS access points](https://www.usgs.gov/the-national-map-data-delivery/topographic-map-access-points), [topoView format guide](https://ngmdb.usgs.gov/topoview/help/)

**Later:** 3DEP elevation profiles and terrain, hydrography, imagery, GeoJSON/KML/GPX and GeoTIFF import/export, region bookmarks, geospatial analysis and reproducible layer manifests. Investigate source coverage, usage terms, rate limits, cache policy, accessibility and coordinate precision per provider. Offline behavior must distinguish user-downloaded USGS products from Apple map content; do not promise offline caching until its terms and implementation are verified.

**Acceptance:** test locations inside and outside USGS coverage, tile failures and recovery, large historical sheets, date/scale attribution, coordinate/projection alignment against known points, keyboard and VoiceOver, local artifact round trips and approval behavior. The initial map integration and its verification limits are tracked in [Maps and News status](23-MAPS-AND-NEWS.md).

## Further activity ideas

These are candidates for discovery and prototyping, not commitments or existing integrations. Every candidate should first identify a real task, a minimal shared-service interface, data rights, failure states and a repeatable end-to-end test.

| Candidate | Example workflow | Why it belongs / dependencies |
|---|---|---|
| Research library | Collect sources, extract passages, annotate, deduplicate and produce a cited brief. | Connect Browser, documents and Pinboard; preserve source links and retrieval dates. |
| Data and spreadsheets | Import a CSV or workbook, inspect quality, transform, visualize and export results. | Share datasets with Lab; record transformations and formulas, and preserve originals. |
| Documents and presentations | Draft a report or slide deck from cited artifacts; render and review before export. | Shared assets, accessible templates and fidelity checks across formats. |
| Maps and field intelligence | Compare historic topo sheets with current layers and an elevation profile. | Map proposal above; coordinate systems and source licensing are central. |
| Knowledge graph | Link people, places, files, experiments and evidence with provenance. | Requires a transparent local index, source-level permissions and correction/deletion. |
| Automation and integrations | Connect a permitted calendar or project tracker to a supervised workflow. | Least-privilege connectors, account isolation, previews and explicit approval for external writes. |
| Audio and video studio | Transcribe recordings, search timestamps, assemble clips and export with captions. | Builds on Media; validate transcription, consent and source attribution. |
| App and device lab | Launch test fixtures across real devices and simulators, capture artifacts and compare runs. | Builds on Devices; physical hardware access and platform restrictions vary. |
| Security and dependency desk | Inventory dependencies, inspect advisories and generate reviewable remediation patches. | Build on Audit and Develop; version data and scan limitations must be explicit. |
| Reproducible research and science | Run notebooks, visualize results and package code, environment, datasets and citations. | Isolated execution, resource budgets, reproducible environments and artifact provenance. |
| Design and accessibility studio | Inspect a screen, collect annotated screenshots, check focus and compare revisions. | Requires permission-aware capture, visual baselines and human accessibility review. |
| Local knowledge and search | Index opted-in folders, search by keyword and semantic similarity, and cite exact sources. | Local-first indexing, selective exclusion, encryption choices and deletion propagation. |

Prioritize research library, data and Maps prototypes after reliability and shared evidence. Prototype with representative tasks and decide based on completion rate, correction effort and trustworthy output—not on feature count. Connected services and operating-system permissions must stay opt-in, and the user should see what data each workflow sends and where.

## Competitive benchmarks to evaluate

VS Code documents an agents window, worktree isolation, cross-interface session continuity, agent harness choices and browser tools. Some of these are experimental or depend on a specific harness; they are benchmarks for investigation, not evidence that Kiln offers them. Evaluate Kiln against concrete tasks: start, supervise, interrupt and resume a multi-file change; compare two isolated attempts; review artifacts; and continue without losing context. [VS Code agent overview](https://code.visualstudio.com/docs/agents/overview), [Agents window](https://code.visualstudio.com/docs/agents/run/agents-window), [browser tools](https://code.visualstudio.com/docs/agents/run/browser-tools)
