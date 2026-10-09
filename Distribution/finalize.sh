#!/bin/zsh
# Waits for an existing notarization submission, then staples, verifies and packages.
# Usage: ./finalize.sh <submission-id> [keychain-profile]
set -euo pipefail
cd "$(dirname "$0")"
ID="$1"; PROFILE="${2:-WS1Butler-Notary}"; APP="WS1 Butler.app"

xcrun notarytool wait "$ID" --keychain-profile "$PROFILE" --timeout 6h
STATUS=$(xcrun notarytool info "$ID" --keychain-profile "$PROFILE" | awk -F': ' '/status:/{print $2}')
echo "Final status: $STATUS"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE" notary-log.json || true
  echo "Notarization not accepted; see notary-log.json"; exit 1
fi
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" notary-log.json || true
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "WS1 Butler.zip"
ditto -c -k --keepParent "$APP" "WS1 Butler.zip"
shasum -a 256 "WS1 Butler.zip" > "WS1 Butler.zip.sha256"
echo "FINALIZED: $(pwd)/WS1 Butler.zip"
