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
echo "Built $DMG"
