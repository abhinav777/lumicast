#!/bin/bash
# Build and run the Lumicast tests. No LED hardware needed — the engine is pointed at a
# pseudo-terminal instead of the controller.
#
#   tests/run.sh                    # logic + wire tests
#   tests/run.sh --snapshot DIR     # also render the control panel in each state to DIR/*.png
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

# Everything except the app's entry point, plus the test entry point.
SOURCES=()
for f in Sources/*.swift; do [ "$f" = "Sources/main.swift" ] || SOURCES+=("$f"); done

swiftc -O "${SOURCES[@]}" tests/main.swift -o "$OUT/lumicast-tests" \
    -target "$(uname -m)-apple-macos$MIN_OS" \
    -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework CoreMedia \
    -framework CoreVideo -framework CoreGraphics -framework ServiceManagement -framework IOKit

"$OUT/lumicast-tests" "$@"
