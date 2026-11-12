#!/bin/bash
# Builds "PSSO Monitor.app" into ./build using only the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

# Universal (Apple silicon + Intel) so the release runs on any Mac.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
APP="build/PSSO Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/PSSOMonitor" "$APP/Contents/MacOS/PSSOMonitor"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PSSO Monitor</string>
    <key>CFBundleDisplayName</key><string>PSSO Monitor</string>
    <key>CFBundleIdentifier</key><string>com.aes256afro.psso-monitor</string>
    <key>CFBundleExecutable</key><string>PSSOMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
