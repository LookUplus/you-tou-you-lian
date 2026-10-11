#!/bin/bash
set -euo pipefail
YELLOWPAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$YELLOWPAGE_ROOT"
swift build -c release --product YellowPageApp --disable-sandbox
YELLOWPAGE_BIN="$(swift build -c release --show-bin-path --disable-sandbox)"
YELLOWPAGE_APP="$YELLOWPAGE_ROOT/dist/有头有脸.app"
mkdir -p "$YELLOWPAGE_APP/Contents/MacOS" "$YELLOWPAGE_APP/Contents/Resources"
cp "$YELLOWPAGE_BIN/YellowPageApp" "$YELLOWPAGE_APP/Contents/MacOS/YellowPageApp"
cp App/Info.plist "$YELLOWPAGE_APP/Contents/Info.plist"
# Produce every standard Retina size from the checked-in generated artwork.
swift -module-cache-path "$YELLOWPAGE_ROOT/.build/icon-module-cache" scripts/prepare-icons.swift App/Resources
YELLOWPAGE_ICONSET="$YELLOWPAGE_ROOT/.build/AppIcon.iconset"
mkdir -p "$YELLOWPAGE_ICONSET"
for YELLOWPAGE_SIZE in 16 32 128 256 512; do
    sips -s format png -z "$YELLOWPAGE_SIZE" "$YELLOWPAGE_SIZE" App/Resources/AppIcon.png --out "$YELLOWPAGE_ICONSET/icon_${YELLOWPAGE_SIZE}x${YELLOWPAGE_SIZE}.png" >/dev/null
    YELLOWPAGE_RETINA=$((YELLOWPAGE_SIZE * 2))
    sips -s format png -z "$YELLOWPAGE_RETINA" "$YELLOWPAGE_RETINA" App/Resources/AppIcon.png --out "$YELLOWPAGE_ICONSET/icon_${YELLOWPAGE_SIZE}x${YELLOWPAGE_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$YELLOWPAGE_ICONSET" -o "$YELLOWPAGE_APP/Contents/Resources/AppIcon.icns"
cp App/Resources/AppIcon.png "$YELLOWPAGE_APP/Contents/Resources/AppIcon-light.png"
cp App/Resources/AppIcon-dark.png "$YELLOWPAGE_APP/Contents/Resources/AppIcon-dark.png"
codesign --force --sign - "$YELLOWPAGE_APP"
codesign --verify --strict "$YELLOWPAGE_APP"
printf '已生成图形试用版：%s\n' "$YELLOWPAGE_APP"
