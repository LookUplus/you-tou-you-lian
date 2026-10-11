#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Some Command Line Tools versions omit this built-in macro directory on incremental builds.
YELLOWPAGE_SWIFTC="$(xcrun --find swiftc)"
YELLOWPAGE_TEST_PLUGINS="$(dirname "$YELLOWPAGE_SWIFTC")/../lib/swift/host/plugins/testing"
if [[ -d "$YELLOWPAGE_TEST_PLUGINS" ]]; then
    swift test --disable-xctest -Xswiftc -plugin-path -Xswiftc "$YELLOWPAGE_TEST_PLUGINS" "$@"
else
    swift test --disable-xctest "$@"
fi
