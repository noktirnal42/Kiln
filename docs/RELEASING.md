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

State in the notes what was and was not verified (see "Not verified" in `docs/11-CURRENT-STATE.md`). `site/support.html` and the README point at the Releases page; v0.1.0 (preview) was published on 2026-11-03 from `c41409f` (notes in `docs/releases/v0.1.0.md`) and v0.1.1 the same day from `76eca6a` (notes in `docs/releases/v0.1.1.md`). Bump `MARKETING_VERSION` in `project.yml` before archiving: the script names the artifacts from the built app's version, and `/releases/latest` only follows non-pre-releases, so link the Releases page while the builds are previews. Tag the commit the artifact was built from.

## Updates

There is no in-app updater. Users download the new notarized build and replace the app; data lives in `~/Library/Application Support/Kiln`, so nothing is lost.
Adding Sparkle needs an EdDSA key pair and an appcast host, which are the maintainer's decisions; it is intentionally not wired up.

## CI

`.github/workflows/ci.yml` builds and runs the unit suite on a hosted macOS runner, manually triggered. It is not a required check: it has only
been proven where it can be run (see the issue tracker for the latest run), and the project targets a very recent Xcode.
