#!/bin/bash
# Builds "Unique AV Countdown.app" into ./build
# Requires Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Unique AV Countdown"
EXEC="UniqueAVCountdown"
APP="build/$APP_NAME.app"

echo "▸ Building release (universal: Apple Silicon + Intel)…"
if swift build -c release --arch arm64 --arch x86_64; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXEC"
else
    echo "▸ Universal build unavailable, building for this Mac only…"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/$EXEC"
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "✓ Done: $APP"
echo "  Drag it into /Applications. First launch: right-click → Open."
[ -z "${CI:-}" ] && open -R "$APP" 2>/dev/null || true
