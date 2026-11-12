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

## Decisions and integration gaps (2026-11-11)

**Decided by the owner:** full email with its sub-features (the list above is the scope), and Apple-compatible messaging if a supported route works. Neither exists in the code yet.

**Email, suggested order.** (1) A Core `Mail` service with an account model and Keychain-held credentials; IMAP and SMTP over Network.framework, OAuth for Gmail and Microsoft, app passwords elsewhere. (2) Read side first: folders, threads, search, offline cache, attachments. (3) Compose, reply, forward, drafts and scheduled send, always shown to the user before an external send. (4) Agent and MCP tools (search, summarize, draft; send needs approval), audit records, tests against a local IMAP/SMTP fixture server. A faster, narrower first path is driving Mail.app through Automation (scripting), which reuses the user's accounts but cannot sync or run unattended; label it as such.

**Email setup (2026-11-11, branch `codex/kiln-mail`).** Name, address and password, then Continue: Kiln finds the servers (built-in providers, the Thunderbird configuration database, the domain's own autoconfig file, then common host names), proves the IMAP and SMTP sign-in without reading or sending anything, and only then saves. Provider notes link to where app passwords are made. Advanced lets the person set hosts, ports and TLS. Not supported yet, and said so in the app: browser sign-in (OAuth) for Outlook.com, Microsoft 365 and Google accounts that block app passwords, and STARTTLS-only providers. The discovery and verification are unit-tested with fakes; no real provider has been tried.

**Apple messaging, what is feasible.** There is no public macOS API to read or send iMessage. Supported: open a prefilled compose sheet in Messages (`NSSharingService` compose message, or an `sms:` URL) that the user reviews and sends. Possible but fragile and permission-heavy: Automation scripting of Messages to send, and reading `chat.db`, which needs Full Disk Access and is unsupported by Apple. Plan: ship the compose handoff first, offer scripting only as an explicit opt-in, and never claim inbox sync or silent send.

**Missing integrations in Kiln today** (none of these exist in `Core` or `Modules`): Calendar and Reminders (EventKit); Contacts (also needed by email address completion); Notes; Files and cloud drives (iCloud Drive, Google Drive, Dropbox); a document, spreadsheet and presentation studio; PDF reading and annotation; a research library with citations; GitHub and issue trackers beyond local git (PRs, CI, issues); Slack and chat-service connectors; Shortcuts and App Intents (so Siri and Shortcuts can call Kiln); Spotlight indexing of conversations and artifacts; Notification Center and Focus awareness; Apple Intelligence Writing Tools and Services-menu actions; Share extension and a menu-bar quick-ask; voice calls and FaceTime hand-off; password-manager hand-off (never storing credentials in chat). Each must follow the parity contract: Core service, GUI, agent and MCP tool, audit record, tests.

**Build order (owner request 2026-11-11, most needed first).** Each item follows the parity contract (Core service, GUI, agent and MCP tool, audit record, tests) and is not "done" until verified against a real account or system.

1. **Email** (above). Slice 1: message model, MIME parsing and composing, threading. Then IMAP/SMTP transport, accounts and Keychain, the mail pane, agent tools.
2. **Contacts** (Contacts framework): address completion for email and messaging; read-only first, permission shown. *Status 2026-11-11 (branch `codex/kiln-mail`): `Core/Contacts` service with ranked search, `contacts_status` and `contacts_search` tools, completion chips in the Mail compose sheet, the addressbook entitlement and usage text; tested with a fake source only. Not yet run against the real Contacts database or seen on screen (needs a signed build with the entitlement).*
3. **Apple-compatible messaging**: compose handoff to Messages first; scripting only as an opt-in. *Status 2026-11-11 (branch `codex/kiln-messaging`, on top of the mail branch): `Core/Messaging` normalises and validates recipients, opens a prefilled Messages compose window through `NSSharingService`, and exposes `messages_status` and `messages_compose` (admin tier: the person approves, then reviews and presses Send in Messages). A "New text message" sheet in the Mail pane suggests numbers from Contacts. Kiln cannot read conversations, send silently or confirm delivery, and says so in the sheet, the tool and the tool result. Unit-tested with a fake composer; the real Messages window has not been opened yet.*
4. **Calendar and Reminders** (EventKit): agents read the day, propose events and tasks; writes need approval.
5. **GitHub PRs, CI and issues** (beyond local git): the PR and CI flow the chat parity table already lists.
6. **Shortcuts and App Intents**: Kiln actions callable from Shortcuts and Siri.
7. **Spotlight indexing** of conversations and artifacts.
8. **PDF annotation and a research library with citations**.
9. **Cloud drives** (iCloud Drive first, then Google Drive and Dropbox).
10. **Notes**.
11. **Slack and chat connectors**.
12. **Notification Center and Focus awareness**.
13. **Menu-bar quick-ask and Share extension**.
14. **Writing Tools and Services-menu actions**.
15. **Document, spreadsheet and presentation studio** (largest; after the data sources above exist).

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
