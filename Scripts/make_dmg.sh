#!/bin/bash
# Packages an already notarized and stapled Kiln.app into a compressed disk image with an /Applications shortcut.
#   Scripts/make_dmg.sh path/to/Kiln.app dist/Kiln-0.1.0.dmg
# The image itself is not signed; Gatekeeper checks the stapled app inside it. Sign the DMG too if you distribute it
# widely:  codesign --sign "<Developer ID hash>" dist/Kiln-0.1.0.dmg
set -euo pipefail
APP="${1:?path to Kiln.app}"
DMG="${2:?output .dmg path}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
xcrun stapler validate "$APP" >/dev/null
ditto "$APP" "$STAGE/Kiln.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "Kiln" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Created $DMG"
