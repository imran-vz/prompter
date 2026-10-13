#!/usr/bin/env bash
#
# Build a signed, notarized Prompter.zip for direct download.
#
# Needs a "Developer ID Application" certificate in your keychain and a
# notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials prompter-notary \
#     --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: TEAM_ID=ABCDE12345 scripts/release.sh
set -euo pipefail

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-prompter-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Prompter.xcarchive"

rm -rf "$OUT"
mkdir -p "$OUT"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Archiving"
xcodebuild archive \
  -project "$ROOT/Prompter.xcodeproj" \
  -scheme Prompter \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID"

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT"

echo "==> Notarizing"
ditto -c -k --keepParent "$OUT/Prompter.app" "$OUT/Prompter-notarize.zip"
xcrun notarytool submit "$OUT/Prompter-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT/Prompter.app"

echo "==> Packaging"
rm "$OUT/Prompter-notarize.zip"
ditto -c -k --keepParent "$OUT/Prompter.app" "$OUT/Prompter.zip"
spctl --assess --type execute --verbose "$OUT/Prompter.app"
echo "Done: $OUT/Prompter.zip"
