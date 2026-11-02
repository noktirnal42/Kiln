# Contributing to Kiln

Kiln is building one native macOS workstation for agents, development, reverse engineering, and model work. The aim is a cohesive workflow with shared context, services, approvals, and history. It is an early project with substantial unfinished areas—not a completed replacement for Xcode, Ghidra, or commercial model tooling.

See [where help is needed](docs/CONTRIBUTION-AREAS.md), [known issues](docs/KNOWN-ISSUES.md), and the [issue tracker](https://github.com/noktirnal42/Kiln/issues). Small, well-verified contributions are welcome, including documentation, accessibility, reproducible bug reports, visual QA, and provider compatibility work.

## Choose a task

1. Search existing issues before opening a new one.
2. For a bug, include a minimal reproduction, expected behavior, actual behavior, and the build or commit tested.
3. For a substantial feature or architecture change, open an issue first with the user workflow, proposed boundary, and acceptance criteria. This helps avoid duplicate work.
4. Comment on an issue before starting a large change. Maintainers may be slow to respond; a comment is coordination, not a reservation or guarantee of acceptance.

Labels such as `good first issue`, `help wanted`, `bug`, `documentation`, and area labels identify useful starting points. Do not assume every open issue has a complete implementation plan.

## Build locally

Use a Mac with a compatible Xcode toolchain. Current development has been checked with Xcode 27.1; the deployment target is macOS 15. Some features additionally require Apple silicon, Metal, Apple Intelligence availability, a model download, or a provider account.

```sh
brew install xcodegen
git clone https://github.com/noktirnal42/Kiln.git
cd Kiln
xcodegen generate
xcodebuild -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 \
  CODE_SIGNING_ALLOWED=NO build
```

`project.yml` is the source of truth; the Xcode project is generated. For a signed development build, select your own team and signing identity locally. Do not commit a contributor's signing credentials, provisioning profiles, or account configuration. Intel builds do not establish support for Apple-silicon-only model workflows.

## Verify a change

Run checks that exercise the changed behavior. Most tests use synthetic fixtures and do not require provider credentials:

```sh
xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 \
  CODE_SIGNING_ALLOWED=NO
```

Live suites are opt-in and may download models, consume API credits, or take several minutes. Use disposable workspaces. Store provider credentials through Kiln Settings; never put keys in source, fixtures, screenshots, logs, or an issue.

```sh
TEST_RUNNER_KILN_LIVE=1 xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 \
  -only-testing:KilnTests/LiveChatTests CODE_SIGNING_ALLOWED=NO
```

Read the selected test before enabling it. A green Xcode command is not enough: confirm the intended tests actually ran. State whether verification used mocks, real providers, the GUI, or the standalone training runner. A compiled MLX runtime is not proof of successful inference or training.

For UI changes, inspect the result in the app. Check narrow and wide windows, light and dark appearance, keyboard access, focus, loading/error/empty states, and long names or results. Include focused screenshots without secrets or personal data.

## Engineering expectations

- Use shared services and typed agent tools rather than duplicating behavior in views or adding a separate backend for each feature.
- Route agent writes, execution, and network operations through the existing policy and approval system. Never bypass it to make a demo pass.
- Preserve cancellation, bounded output, explicit errors, and auditability.
- Report unavailable capabilities honestly. Do not replace a failed operation with fabricated output or mark a model's claim as verified work.
- Keep model/provider-specific behavior in the provider layer. Tests should cover malformed streams and provider failures as well as success.
- Keep changes focused. Explain migrations, data changes, compatibility risks, and new dependencies.

## Pull requests

Use the PR template. Describe the user-visible problem and resulting behavior, link the issue, list the checks performed and their actual results, and state what remains unverified. Avoid unrelated refactors in a bug fix. Draft PRs are welcome when a design needs discussion.

Contributions must be yours to submit or compatible with the project's MIT license. Keep upstream notices for dependencies and imported code. The MIT license does not replace third-party licenses or grant rights to model weights, datasets, provider services, or trademarks. No contributor license agreement is currently required.

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). See [security reporting](SECURITY.md) for sensitive findings.
