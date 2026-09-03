#!/bin/bash
# Build a distributable ARCA.app for other people: Developer ID signed,
# notarized, packaged as a DMG — with the owner's bundled API keys removed.
#
# Requires: a "Developer ID Application" certificate in the active keychain
# (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
# Application; Account Holder only) and the ASC API key used everywhere else.
#
# Usage: scripts/build-mac-dmg.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/arca-dist}"
SCHEME="${SCHEME:-ARCA-Beta}"
PRODUCT="${PRODUCT:-ARCA Beta}"
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_D3CFFDDQFB.p8"
ASC_KEY_ID="D3CFFDDQFB"
ASC_ISSUER="14e5aa60-5bc9-474f-8217-077735364dbe"
ARCHIVE="$OUT/ARCA.xcarchive"
EXPORT="$OUT/export"
mkdir -p "$OUT"

echo "▶ archive"
xcodebuild -project ARCA.xcodeproj -scheme "$SCHEME" -destination 'platform=macOS' -configuration Release \
  archive -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER" \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

APP="$ARCHIVE/Products/Applications/$PRODUCT.app"
echo "▶ strip owner keys from the bundle (BYOK: testers enter their own in onboarding)"
# Keep only the Composio project key: connectors work per user (each install
# mints its own user id). LLM keys, GitHub relay and the owner's Composio user
# id must not ship.
find "$APP/Contents/Resources" -maxdepth 1 -name "BundledKeys.plist.*" -delete
PLIST="$APP/Contents/Resources/BundledKeys.plist"
if [ -f "$PLIST" ]; then
  for k in anthropic openAI githubToken githubRepo composioUserId; do /usr/libexec/PlistBuddy -c "Delete :$k" "$PLIST" 2>/dev/null || true; done
  /usr/libexec/PlistBuddy -c "Print" "$PLIST" | sed -E 's/= .{4}.*/= ****/'
fi

echo "▶ export with Developer ID (re-signs after the strip)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist ExportOptions-developerid.plist \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER" \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"

echo "▶ verify no LLM keys shipped"
if /usr/libexec/PlistBuddy -c "Print :anthropic" "$EXPORT/ARCA.app/Contents/Resources/BundledKeys.plist" >/dev/null 2>&1; then echo "anthropic key still present — abort"; exit 1; fi

echo "▶ notarize"
DMG="$OUT/$(echo "$PRODUCT" | tr " " "-")-mac.dmg"
rm -f "$DMG"
hdiutil create -volname "ARCA" -srcfolder "$EXPORT/$PRODUCT.app" -ov -format UDZO "$DMG" >/dev/null
xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
xcrun stapler staple "$DMG"
echo "✅ $DMG"
