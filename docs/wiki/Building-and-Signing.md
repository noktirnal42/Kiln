# Building and Signing

## Build and test

`project.yml` is the source of truth; `Kiln.xcodeproj` is generated (`xcodegen generate`) and not committed. Use your own signing team for development and never commit it.

```sh
xcodegen generate
xcodebuild -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 CODE_SIGNING_ALLOWED=NO build

xcodebuild test -project Kiln.xcodeproj -scheme Kiln \
  -destination 'platform=macOS,arch=arm64' -jobs 2 CODE_SIGNING_ALLOWED=NO
```

The deployment target is macOS 15. Live suites are opt-in (`TEST_RUNNER_KILN_LIVE=1`), use your configured providers and may spend credits. A green command is not enough: confirm the suite you care about actually ran, and know that `Packages/ModelLabCore/Package.resolved` is rewritten by builds and must not be committed.

The Xcode version in `project.yml` (`xcodeVersion`) matches the recommended build settings so Xcode's "Update to recommended settings" prompt stays away; raise it when moving to a newer Xcode.

## Companions

The iPhone and Apple Watch apps live in `Companion/iOS` and `Companion/Watch`, each with its own XcodeGen project and README. Build them with your own signing team. The shared protocol is `Packages/KilnRemoteKit` (test with `swift test`). The optional relay is in `Relay/` (`npm ci`, then `npm run dev` or a Cloudflare Worker deployment).

## Release (maintainers)

Kiln is not sandboxed, so it cannot go to the Mac App Store; distribution is a Developer ID signed, notarized, stapled `Kiln.app`. Two routes produce it:

1. **The Apple ID signed in to Xcode:** `Scripts/release_xcode_account.sh` generates the project, archives, uploads for notarization, retries the notarized export until Apple finishes ("archive is processing" is normal), staples, validates with `stapler`, `spctl` and `codesign`, then packages a zip, a DMG and a checksum into `dist/`.
2. **`notarytool` with a stored profile:** create the profile once with `xcrun notarytool store-credentials` (you type the app-specific password; it is never put in a script or chat), then `Scripts/notarize.sh`.

`Scripts/make_dmg.sh` wraps a stapled app in a DMG (unsigned image; Gatekeeper evaluates the stapled app). Two certificates with the same name make `codesign --sign "<name>"` ambiguous; use the certificate hash. Bump `MARKETING_VERSION` before archiving and tag the commit the artifact was built from. Publishing a GitHub Release is public and is the maintainer's action; release notes should say what was and was not verified.

## Updates

There is no in-app updater. Options (manual, a check-only button, or Sparkle) are documented in `docs/RELEASING.md`; none is implemented.

## CI

`.github/workflows/ci.yml` builds and runs the Mac suite, the relay tests and the site checks on a hosted macOS runner (passed on 2026-11-04). It needs `-skipPackagePluginValidation -skipMacroValidation` for the terminal plug-in. It is not yet a required check.

## Apple capabilities

An enabled App ID capability is not a feature. The browser passkey entitlement and Private Cloud Compute eligibility are separate Apple decisions; the shipping signature does not include the passkey entitlement, and no CloudKit sync, push for new features or Maps feature has been verified. The project and release have not migrated to the newly registered App ID. See `docs/20-APPLE-CAPABILITIES.md`.

---

**Verified status.** Build and test commands were run on a clean checkout (`docs/GETTING-STARTED.md`); the Xcode-account release route produced the notarized preview (`spctl` reported a notarized Developer ID app); CI passed on 2026-11-04. **Not checked:** `Scripts/notarize.sh` (never run, no stored profile), the DMG signing, and any release in this documentation pass.
