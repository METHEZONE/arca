#!/bin/bash
# Today's beta: a Development-signed ARCA.app (no Developer ID yet), with the
# owner's LLM keys stripped, zipped for hand-off. Testers must right-click ›
# Open the first time (Gatekeeper: "unidentified developer") and then enter
# their own Anthropic/OpenAI key in onboarding.
#
# Usage: scripts/build-mac-beta-zip.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/arca-beta}"
SCHEME="${SCHEME:-ARCA-Beta}"
PRODUCT="${PRODUCT:-ARCA Beta}"
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_D3CFFDDQFB.p8"
mkdir -p "$OUT"
DD="$OUT/dd"

echo "▶ build (Release)"
xcodebuild -project ARCA.xcodeproj -scheme "$SCHEME" -destination 'platform=macOS' -configuration Release -derivedDataPath "$DD" build \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY" -authenticationKeyID D3CFFDDQFB -authenticationKeyIssuerID 14e5aa60-5bc9-474f-8217-077735364dbe \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP="$OUT/$PRODUCT.app"
rm -rf "$APP"
cp -R "$DD/Build/Products/Release/$PRODUCT.app" "$APP"

echo "▶ strip owner keys"
find "$APP/Contents/Resources" -maxdepth 1 -name "BundledKeys.plist.*" -delete
PLIST="$APP/Contents/Resources/BundledKeys.plist"
if [ -f "$PLIST" ]; then
  for k in anthropic openAI githubToken githubRepo composioUserId; do /usr/libexec/PlistBuddy -c "Delete :$k" "$PLIST" 2>/dev/null || true; done
  echo "remaining bundled keys:"; /usr/libexec/PlistBuddy -c "Print" "$PLIST" | sed -E 's/= .{4}.*/= ****/'
fi

echo "▶ re-sign (Development identity, deep)"
# Only identities the system still trusts — a revoked one sits in the list too.
IDENTITY=$(security find-identity -v -p codesigning | grep -v "CSSMERR" | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
[ -n "$IDENTITY" ] || { echo "no valid Apple Development identity"; exit 1; }
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok: $IDENTITY"

echo "▶ zip"
ZIP="$OUT/$(echo "$PRODUCT" | tr " " "-")-$(date +%Y%m%d).zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ $ZIP ($(du -h "$ZIP" | cut -f1))"
