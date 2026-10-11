#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
mkdir -p dist
cp .build/release/yellowpage dist/yellowpage
codesign --force --sign - dist/yellowpage
printf '已生成：%s/dist/yellowpage\n' "$ROOT"
