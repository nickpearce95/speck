#!/bin/zsh
# Builds Speck.app (menu bar only, no Dock icon). Usage: ./build.sh [--install]
# Release builds set VERSION, UPDATE_REPO and UPDATE_PUBLIC_KEY; without them the updater is off.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release -Xswiftc -Osize -Xlinker -dead_strip
APP=build/Speck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Speck "$APP/Contents/MacOS/Speck"
strip -x "$APP/Contents/MacOS/Speck"   # drop local symbols (~700 KB)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Speck</string>
    <key>CFBundleDisplayName</key><string>Speck</string>
    <key>CFBundleIdentifier</key><string>app.speck.menubar</string>
    <key>CFBundleExecutable</key><string>Speck</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Speck looks for Chromecast and Sonos speakers on your network so you can play music on them.</string>
    <key>NSBonjourServices</key><array>
        <string>_googlecast._tcp</string>
        <string>_sonos._tcp</string>
        <string>_spotify-connect._tcp</string>
    </array>
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>SpeckUpdateRepo</key><string>${UPDATE_REPO:-}</string>
    <key>SpeckUpdatePublicKey</key><string>${UPDATE_PUBLIC_KEY:-}</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p /Applications
    pkill -x Speck 2>/dev/null || true
    rm -rf /Applications/Speck.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Speck.app"
fi
