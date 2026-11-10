# Contributing

Kiln welcomes code, tests, documentation, accessibility work, visual QA, provider checks and reproducible bug reports. It is an early project; small, well-verified contributions are the most useful.

## Find work

- [Good first issues](https://github.com/noktirnal42/Kiln/issues?q=is%3Aopen+label%3A%22good+first+issue%22) and [help wanted](https://github.com/noktirnal42/Kiln/issues?q=is%3Aopen+label%3A%22help+wanted%22)
- `docs/CONTRIBUTION-AREAS.md` (areas and what counts as evidence) and `docs/ISSUE-INDEX.md`
- Search existing issues first. For a substantial feature, open an issue with the workflow, boundary and acceptance criteria before building. Comment before a large change; a comment is coordination, not a reservation.

## Make a change

1. Branch: `git switch -c fix/<short-name>`.
2. Make the smallest change that does the job, with a test beside it in `Tests/`. Pure logic (`Core/Editor`, `Core/Integrations`) is the easiest place to start.
3. Verify the area first, then everything:
   ```sh
   xcodebuild test -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS,arch=arm64' \
     -only-testing:KilnTests/LineDiffTests CODE_SIGNING_ALLOWED=NO
   ```
4. For visible changes, run the app: narrow and wide windows, light and dark, keyboard only. Attach screenshots without personal paths or keys.
5. Open a pull request that says what you verified (mocks, a real provider, the GUI) and what you did not.

## Engineering expectations

- **One service, many surfaces.** A capability is not finished until it has a service in `Core/` with no UI dependency, a GUI in its activity, an agent tool and MCP tool with the right permission level, a command-palette entry, an audit record for state changes, and tests (plus a look at the running app).
- Route agent writes, execution and network operations through the existing policy and approval system. Never bypass it to make a demo pass.
- Preserve cancellation, bounded output, explicit errors and auditability.
- Report unavailable capabilities honestly; never replace a failed operation with fabricated output.
- Keep provider-specific behavior in the provider layer, with tests for malformed streams and failures.

## Adding an activity

A new activity needs its own folder declaring an `ActivityDescriptor` (title, symbol, summary, starter prompts, tool prefixes, capabilities, tool registration) and one line in `ActivityCatalog`. Do not edit the shared shell files per module.

## Documentation changes

Keep claims proportional to evidence. Update the README, the website and these wiki pages together; `docs/DOCS-MAP.md` says which document is authoritative and `Scripts/check-docs.sh` checks the links.

## Rules that matter

Never commit keys, tokens, signing credentials, provisioning profiles or `Packages/ModelLabCore/Package.resolved`. Do not use private binaries, proprietary datasets or non-redistributable weights as fixtures. Follow the code of conduct. For the license and contribution terms, see LICENSE and `CONTRIBUTING.md`. Security findings go through `SECURITY.md`.

---

**Verified status.** Steps are taken from `CONTRIBUTING.md`, `docs/GETTING-STARTED.md` and `docs/17-PARITY-AND-BEYOND.md`; the registry description matches `Core/Registry/ActivityCatalog.swift`. **Not checked:** a first contribution by someone new to the repository in this pass.
