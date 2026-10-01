#!/bin/zsh
# Builds Speck.app (menu bar only, no Dock icon). Usage: ./build.sh [--install]
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
