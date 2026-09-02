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
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_D3CFFDDQFB.p8"
ASC_KEY_ID="D3CFFDDQFB"
ASC_ISSUER="14e5aa60-5bc9-474f-8217-077735364dbe"
ARCHIVE="$OUT/ARCA.xcarchive"
EXPORT="$OUT/export"
mkdir -p "$OUT"

echo "▶ archive"
xcodebuild -project ARCA.xcodeproj -scheme ARCA -destination 'platform=macOS' -configuration Release \
  archive -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER" \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

APP="$ARCHIVE/Products/Applications/ARCA.app"
echo "▶ strip owner keys from the bundle (BYOK: testers enter their own in onboarding)"
rm -f "$APP/Contents/Resources/BundledKeys.plist"
find "$APP" -name "BundledKeys.plist" -delete

echo "▶ export with Developer ID (re-signs after the strip)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist ExportOptions-developerid.plist \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER" \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"

echo "▶ verify no keys shipped"
if find "$EXPORT/ARCA.app" -name "BundledKeys.plist" | grep -q .; then echo "BundledKeys.plist still present — abort"; exit 1; fi

echo "▶ notarize"
DMG="$OUT/ARCA.dmg"
rm -f "$DMG"
hdiutil create -volname "ARCA" -srcfolder "$EXPORT/ARCA.app" -ov -format UDZO "$DMG" >/dev/null
xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
xcrun stapler staple "$DMG"
echo "✅ $DMG"
