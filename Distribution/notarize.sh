#!/bin/zsh
# Notarizes and staples "WS1 Butler.app" in this folder.
# One-time setup (stores an app-specific password in your login keychain; never in this script):
#   xcrun notarytool store-credentials "WS1Butler-Notary" --apple-id "<your Apple ID>" --team-id 283WG6CQV8
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="${1:-WS1Butler-Notary}"
APP="WS1 Butler.app"

codesign --verify --deep --strict "$APP"
rm -f WS1Butler-notarize.zip
ditto -c -k --keepParent "$APP" WS1Butler-notarize.zip

echo "Submitting to Apple notary service…"
xcrun notarytool submit WS1Butler-notarize.zip --keychain-profile "$PROFILE" --wait --timeout 30m

echo "Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Final distributable with the stapled ticket inside.
rm -f "WS1 Butler.zip"
ditto -c -k --keepParent "$APP" "WS1 Butler.zip"
echo "Done: $(pwd)/WS1 Butler.zip"
