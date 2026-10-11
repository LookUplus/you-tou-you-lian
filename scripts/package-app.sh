#!/bin/bash
set -euo pipefail
YELLOWPAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$YELLOWPAGE_ROOT"
YELLOWPAGE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)
YELLOWPAGE_OUTPUT="${1:-$YELLOWPAGE_ROOT/dist/release}"
YELLOWPAGE_FOLDER="$YELLOWPAGE_OUTPUT/有头有脸-$YELLOWPAGE_VERSION-图形试用版"
mkdir -p "$YELLOWPAGE_FOLDER"
bash scripts/build-app.sh
# Avoid carrying obsolete resources into the release; copy only the current signed bundle.
if [[ -e "$YELLOWPAGE_FOLDER/有头有脸.app" ]]; then
    printf '目标包已存在，请选择新的输出目录：%s\n' "$YELLOWPAGE_FOLDER" >&2
    exit 1
fi
ditto "$YELLOWPAGE_ROOT/dist/有头有脸.app" "$YELLOWPAGE_FOLDER/有头有脸.app"
cp 图形版使用说明.md "$YELLOWPAGE_FOLDER/使用说明.md"
cp 验证说明.md "$YELLOWPAGE_FOLDER/验证说明.md"
cp LICENSE "$YELLOWPAGE_FOLDER/LICENSE"
python3 scripts/archive-app.py "$YELLOWPAGE_FOLDER" "$YELLOWPAGE_OUTPUT/有头有脸-$YELLOWPAGE_VERSION-macOS-AppleSilicon-GUI.zip"
shasum -a 256 "$YELLOWPAGE_OUTPUT/有头有脸-$YELLOWPAGE_VERSION-macOS-AppleSilicon-GUI.zip" > "$YELLOWPAGE_OUTPUT/SHA256SUMS.txt"
printf '已打包：%s\n' "$YELLOWPAGE_OUTPUT"
