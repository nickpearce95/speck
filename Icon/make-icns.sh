#!/bin/zsh
# Renders the icon and packs it into Icon/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
swift Icon/make-icon.swift Icon/AppIcon-1024.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s Icon/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    # Skip 512@2x (1024px, ~540 KB): only used for huge Finder previews, where macOS upscales 512px
    [[ $s == 512 ]] && continue
    sips -z $((s*2)) $((s*2)) Icon/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Icon/AppIcon.icns
echo "Wrote Icon/AppIcon.icns"
