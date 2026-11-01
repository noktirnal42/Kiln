#!/bin/bash
# Builds a Developer ID signed Release of Kiln, notarizes it with Apple, staples the ticket, and
# leaves dist/Kiln.zip ready to share. Run from the repository root.
#
# One-time setup (you type the app-specific password, never this script or an agent):
#   xcrun notarytool store-credentials kiln-notary --apple-id <you@example.com> --team-id LH8KLB9N4F
# Create the app-specific password at https://account.apple.com (Sign-In and Security).
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-kiln-notary}"
# This Mac holds two Developer ID certificates with the same name, which makes the name ambiguous to
# codesign. Selecting by hash avoids that. Override with SIGN_IDENTITY=<hash or unique name>.
SIGN_IDENTITY="${SIGN_IDENTITY:-6EBE39556C347275CEACB82B2DDB8A4A9BB42127}"
DERIVED="${DERIVED_DATA:-build/notarize-derived}"
APP="$DERIVED/Build/Products/Release/Kiln.app"
OUT="dist"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
  echo "No notary credentials named '$PROFILE'. Run the store-credentials command at the top of this script." >&2
  exit 1
}

xcodegen generate
xcodebuild build -project Kiln.xcodeproj -scheme Kiln -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY"

echo "== Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags=.*runtime" || {
  echo "Not signed with a Developer ID identity and the hardened runtime." >&2; exit 1; }

mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/Kiln-notarize.zip"

echo "== Submitting to Apple (waits for the result)"
xcrun notarytool submit "$OUT/Kiln-notarize.zip" --keychain-profile "$PROFILE" --wait

echo "== Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT/Kiln.zip"
rm -f "$OUT/Kiln-notarize.zip"
echo "Done: $OUT/Kiln.zip"
