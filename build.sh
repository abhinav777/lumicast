#!/bin/bash
# Build Lumicast.app from source: compile, assemble bundle, ad-hoc sign.
set -euo pipefail
cd "$(dirname "$0")"

APP="Lumicast.app"
BIN="$APP/Contents/MacOS/Lumicast"

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> copying bundle resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> compiling (swiftc)"
swiftc -O Sources/main.swift Sources/Panel.swift -o "$BIN" \
    -framework AppKit \
    -framework SwiftUI \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CoreGraphics \
    -framework ServiceManagement

echo "==> ad-hoc code signing (stable identity for TCC/Screen Recording)"
codesign --force --sign - --identifier com.abhinav.lumicast "$APP"

echo "==> done: $PWD/$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
