#!/bin/bash
# Builds, notarizes and packages Kiln using the Apple ID that is signed in to Xcode (Settings → Accounts).
# This is the route used for the published builds; Scripts/notarize.sh is the notarytool alternative.
#
#   Scripts/release_xcode_account.sh            # archive, upload, wait for notarization, staple, zip + dmg in dist/
#   INSTALL=1 Scripts/release_xcode_account.sh  # also replace /Applications/Kiln.app
#
# Nothing here reads or stores a password. Run from the repository root.
set -euo pipefail

TEAM="${DEVELOPMENT_TEAM:-LH8KLB9N4F}"
WORK="${WORK_DIR:-build/release}"
OUT="dist"
ARCHIVE="$WORK/Kiln.xcarchive"

rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"

cat > "$WORK/export-upload.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "== Generating project"
xcodegen generate

echo "== Archiving (Release)"
xcodebuild archive -project Kiln.xcodeproj -scheme Kiln -configuration Release \
  -destination 'platform=macOS' -archivePath "$ARCHIVE"

echo "== Uploading to Apple for notarization"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/export-upload.plist" \
  -exportPath "$WORK/upload" -allowProvisioningUpdates

echo "== Waiting for the notarized export (retries while Apple is still processing)"
for attempt in $(seq 1 40); do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/notarized" >/dev/null 2>&1 \
     && [ -d "$WORK/notarized/Kiln.app" ]; then break; fi
  echo "   not ready yet (attempt $attempt)"; sleep 20
done
APP="$WORK/notarized/Kiln.app"
[ -d "$APP" ] || { echo "Notarization did not finish; check the Xcode Organizer." >&2; exit 1; }

echo "== Verifying"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)"
ditto -c -k --keepParent "$APP" "$OUT/Kiln-$VERSION.zip"
Scripts/make_dmg.sh "$APP" "$OUT/Kiln-$VERSION.dmg"
(cd "$OUT" && shasum -a 256 "Kiln-$VERSION.zip" "Kiln-$VERSION.dmg" > "Kiln-$VERSION.sha256")
echo "Done: $OUT/Kiln-$VERSION.zip, $OUT/Kiln-$VERSION.dmg, $OUT/Kiln-$VERSION.sha256"

if [ "${INSTALL:-0}" = "1" ]; then
  osascript -e 'quit app "Kiln"' 2>/dev/null || true
  sleep 2
  rm -rf /Applications/Kiln.app
  ditto "$APP" /Applications/Kiln.app
  spctl --assess --type execute --verbose=2 /Applications/Kiln.app
  echo "Installed to /Applications/Kiln.app"
fi
