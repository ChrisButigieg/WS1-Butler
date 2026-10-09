#!/bin/zsh
# Notarizes, staples and verifies the installer package.
# Usage: ./notarize-pkg.sh [pkg] [keychain-profile]
set -euo pipefail
cd "$(dirname "$0")"
PKG="${1:-WS1-Butler-1.0.pkg}"; PROFILE="${2:-WS1Butler-Notary}"
pkgutil --check-signature "$PKG" >/dev/null
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait --timeout 6h --output-format json > pkg-submit.json
ID=$(python3 -c "import json;print(json.load(open('pkg-submit.json'))['id'])")
STATUS=$(python3 -c "import json;print(json.load(open('pkg-submit.json'))['status'])")
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" pkg-notary-log.json || true
echo "Final status: $STATUS"
[[ "$STATUS" == "Accepted" ]] || { echo "Not accepted; see pkg-notary-log.json"; exit 1; }
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=2 "$PKG"
shasum -a 256 "$PKG" > "$PKG.sha256"
echo "PKG FINALIZED: $(pwd)/$PKG"
