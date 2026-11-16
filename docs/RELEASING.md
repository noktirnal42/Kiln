# Releasing Kiln

Two supported routes produce the same artifact: a Developer ID signed, notarized, stapled `Kiln.app`. The app is **not sandboxed**
(see `docs/11-CURRENT-STATE.md`), so it cannot go to the Mac App Store; distribution is direct.

## Route 1 — the Apple ID signed in to Xcode (used so far)

Prerequisite: Xcode → Settings → Accounts has the team's Apple ID, and a *Developer ID Application* certificate exists for the team
(`security find-identity -v -p codesigning`). Two certificates with the same name make `codesign --sign "<name>"` ambiguous; use the hash.

```sh
Scripts/release_xcode_account.sh              # → dist/Kiln-<version>.zip, .dmg, .sha256
INSTALL=1 Scripts/release_xcode_account.sh    # also replaces /Applications/Kiln.app
```

It generates the project, archives, uploads for notarization, retries `-exportNotarizedApp` until Apple finishes ("archive is
processing" is normal), staples, runs `stapler validate`, `spctl --assess` and `codesign --verify`, then packages. Verified on a real run: archive →
upload → notarized export took about 10–15 minutes on this Mac; the resulting app reported `source=Notarized Developer ID`.

## Route 2 — `notarytool` with a stored profile

```sh
xcrun notarytool store-credentials kiln-notary --apple-id <you@example.com> --team-id LH8KLB9N4F
# you type the app-specific password (account.apple.com → Sign-In and Security); never put it in a script or chat
Scripts/notarize.sh                            # → dist/Kiln.zip
```

`Scripts/notarize.sh` refuses to run until the `kiln-notary` profile exists. It has not been run on the maintainer's Mac because the profile is not set up there.

## DMG

`Scripts/make_dmg.sh path/to/Kiln.app dist/Kiln-<version>.dmg` wraps a stapled app with an `/Applications` shortcut (`hdiutil`, UDZO, verified). The
image is unsigned; Gatekeeper evaluates the stapled app inside. Sign the DMG too if you ship it outside GitHub.

## GitHub Release

Only after the artifacts verify (and only by the maintainer — publishing is public):

```sh
git tag v<version> && git push origin v<version>
gh release create v<version> dist/Kiln-<version>.zip dist/Kiln-<version>.dmg dist/Kiln-<version>.sha256 \
  --title "Kiln <version>" --notes-file release-notes.md
```

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` for a new release (builds from `main` already say 0.2.0 (3), ahead of the published 0.1.1). State in the notes what was and was not verified (see "Not verified" in `docs/11-CURRENT-STATE.md`). `site/support.html` and the README point at the Releases page; v0.1.0 (preview) was published on 2026-11-03 from `c41409f` (notes in `docs/releases/v0.1.0.md`) and v0.1.1 the same day from `76eca6a` (notes in `docs/releases/v0.1.1.md`). Bump `MARKETING_VERSION` in `project.yml` before archiving: the script names the artifacts from the built app's version, and `/releases/latest` only follows non-pre-releases, so link the Releases page while the builds are previews. Tag the commit the artifact was built from.

## Updates

There is no in-app updater. Users download the new notarized build and replace the app; data lives in `~/Library/Application Support/Kiln`, so nothing is lost.
Adding Sparkle needs an EdDSA key pair and an appcast host, which are the maintainer's decisions; it is intentionally not wired up.

### Update options (for the maintainer to choose; nothing here is implemented)

| Option | What it needs | Trade-offs |
|---|---|---|
| **Stay manual** (today) | Nothing beyond GitHub Releases. | Users must notice new versions. Zero infrastructure, no signing keys to protect. |
| **"Check for updates" button only** | A call to the GitHub Releases API (`/repos/noktirnal42/Kiln/releases/latest`, unauthenticated, rate-limited) comparing `CFBundleShortVersionString`; opens the release page. No download or install in the app. | Small (one view, one network call, needs the sandbox network-client entitlement Kiln already has for providers). Must say clearly that it only checks. Pre-releases must be excluded or opted into. |
| **Sparkle 2** | An EdDSA key pair (private key in the maintainer's Keychain, public key in Info.plist as `SUPublicEDKey`), an appcast XML host (GitHub Pages already serves the site, so `site/appcast.xml` works), `generate_appcast` run per release, the Sparkle SPM package, and the sandbox XPC services entitlements/`SUEnableInstallerLauncherService`. | Silent background download and install with signature verification. Adds a dependency and a key that must never be lost or leaked; a key change breaks updates for installed copies. Release script would need an extra signing and appcast step. |

Recommendation: keep manual updates until there are users who are not the maintainer; if a nudge is wanted sooner, the check-only button is the cheapest honest step. Sparkle only after the EdDSA key is generated and backed up by the maintainer.

## CI

`.github/workflows/ci.yml` builds and runs the Mac unit suite, the relay's JS tests and the site checks on a hosted macOS runner. It passed there on 2026-11-04
(it needs `-skipPackagePluginValidation -skipMacroValidation` for the SwiftTerm plug-in, and `npm ci --prefix Relay` for the relay end-to-end test). It runs on pull
requests and by hand from the Actions tab. It is not yet a required check; make it one once a few pull requests have gone through it.
