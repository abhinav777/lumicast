#!/bin/bash
# Build Lumicast.app from source: compile a universal binary, assemble the bundle, sign it.
#
#   ./build.sh                          # universal (Apple silicon + Intel), ad-hoc signed
#   ARCHS=arm64 ./build.sh              # one architecture only (faster)
#   CODESIGN_IDENTITY="My Cert" ./build.sh   # sign with a real identity (see note at the bottom)
set -euo pipefail
cd "$(dirname "$0")"

APP="Lumicast.app"
BIN="$APP/Contents/MacOS/Lumicast"
ARCHS="${ARCHS:-arm64 x86_64}"
# The deployment target comes from Info.plist so the two can't disagree. Without an explicit
# target swiftc uses the toolchain default, which can be NEWER than the OS you are running —
# the app then refuses to launch at all.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> copying bundle resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SLICES=()
for arch in $ARCHS; do
    echo "==> compiling ($arch, macOS $MIN_OS+)"
    swiftc -O Sources/*.swift -o "$BIN.$arch" \
        -target "$arch-apple-macos$MIN_OS" \
        -framework AppKit \
        -framework SwiftUI \
        -framework ScreenCaptureKit \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework CoreGraphics \
        -framework ServiceManagement \
        -framework IOKit
    SLICES+=("$BIN.$arch")
done
lipo -create "${SLICES[@]}" -output "$BIN"
rm -f "${SLICES[@]}"

# Ad-hoc signing ("-") ties macOS privacy grants to this exact binary, so the Screen Recording
# permission (Mirror mode) must be re-granted after every rebuild. Signing with a real
# identity — a Developer ID, or a self-signed code-signing certificate from Keychain Access —
# keeps the grant across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> code signing ($([ "$IDENTITY" = "-" ] && echo "ad-hoc" || echo "$IDENTITY"))"
codesign --force --sign "$IDENTITY" --identifier com.abhinav.lumicast "$APP"

echo "==> done: $PWD/$APP  ($(lipo -archs "$BIN"))"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
