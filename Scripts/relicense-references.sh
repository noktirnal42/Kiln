#!/bin/sh
# Rewrites public references from "MIT / open source" to the PolyForm Noncommercial wording.
# Idempotent: safe to run again after docs change. Run from the repository root, then review `git diff`.
set -eu
FILES="README.md CONTRIBUTING.md $(ls site/*.html docs/wiki/*.md 2>/dev/null | tr '\n' ' ')"
for f in $FILES; do
  [ -f "$f" ] || continue
  sed -i '' \
    -e 's#license-MIT-d8b38a#license-PolyForm%20Noncommercial-d8b38a#g' \
    -e 's#alt="License: MIT"#alt="License: PolyForm Noncommercial"#g' \
    -e 's#Kiln is free and MIT licensed, and sponsorship#Kiln is free for noncommercial use, and sponsorship#g' \
    -e 's#Kiln is free and MIT licensed\.#Kiln is free for noncommercial use; commercial use needs a license.#g' \
    -e 's#Experimental software, MIT licensed\.#Experimental software, source-available under the PolyForm Noncommercial License.#g' \
    -e 's#<span>MIT licensed</span>#<span>Source-available</span>#g' \
    -e 's#Kiln is MIT licensed\. Contributions should include only work you have the right to share#Kiln is source-available under the PolyForm Noncommercial License, and contributions are accepted under the contributor agreement (CLA.md). Contributions should include only work you have the right to share#g' \
    -e 's#MIT licensed\.#Source-available (PolyForm Noncommercial; commercial use needs a license).#g' \
    -e 's#an open-source native macOS#a source-available native macOS#g' \
    -e 's#is an open-source Swift and SwiftUI#is a source-available Swift and SwiftUI#g' \
    -e 's#is an open-source Mac app#is a source-available Mac app#g' \
    -e 's#Open source, notarized#Source-available, notarized#g' \
    -e 's#Open source · Native macOS#Source-available · Native macOS#g' \
    -e 's#<strong>MIT</strong>#<strong>Source-available</strong>#g' \
    -e 's#independent open-source project#independent project#g' \
    -e 's#an experimental open-source project#an experimental source-available project#g' \
    -e 's#open-source native macOS#source-available native macOS#g' \
    -e 's#the project.s MIT license#the project'"'"'s license (PolyForm Noncommercial, see LICENSE)#g' \
    -e 's#The MIT license does not replace#The project license does not replace#g' \
    -e 's#^\[MIT\](LICENSE)\. #[PolyForm Noncommercial License 1.0.0](LICENSE) for source and builds from the relicensing onward; releases up to v0.1.1 remain MIT (see [LICENSE-HISTORY.md](LICENSE-HISTORY.md)). Commercial use: see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md). Third-party licenses: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). #' \
    "$f"
done
echo "Remaining references to review by hand:"
grep -n -i -E "MIT|open[- ]source|free software|permissive" $FILES | grep -v -i -E "limit|permit|submit|commit|admit|smith|timit|summit|transmit|emit|omit" || true
