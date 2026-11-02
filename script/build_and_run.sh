#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-run}"
DERIVED_DATA="${KILN_DERIVED_DATA:-$PWD/DerivedData}"
APP="$DERIVED_DATA/Build/Products/Debug/Kiln.app"
BINARY="$APP/Contents/MacOS/Kiln"
xcodebuild -project Kiln.xcodeproj -scheme Kiln -configuration Debug -derivedDataPath "$DERIVED_DATA" build
case "$MODE" in
  run) /usr/bin/open -n "$APP" ;;
  --debug|debug) lldb -- "$BINARY" ;;
  --logs|logs) /usr/bin/open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "Kiln"' ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.kiln.app"' ;;
  --verify|verify) /usr/bin/open -n "$APP"; sleep 1; pgrep -x Kiln >/dev/null ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
