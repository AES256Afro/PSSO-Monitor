#!/bin/bash
# Builds the app and wraps it in build/PSSO-Monitor-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
APP="build/PSSO Monitor.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/PSSO-Monitor-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "PSSO Monitor $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Optional: sign with a Developer ID and notarize.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> ./package-dmg.sh
# Create the profile once with: xcrun notarytool store-credentials <profile>
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi
echo "Built $DMG"
