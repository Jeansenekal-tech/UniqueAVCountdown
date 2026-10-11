#!/bin/bash
# Packs build/Unique AV Countdown.app into a drag-to-Applications disk image.
#   ./make_dmg.sh            → build/UniqueAVCountdown-<version>.dmg
# Run ./build_app.sh first.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Unique AV Countdown.app"
[ -d "$APP" ] || { echo "✗ $APP not found — run ./build_app.sh first"; exit 1; }
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
DMG="build/UniqueAVCountdown-$VERSION.dmg"
STAGE="build/dmg-stage"

echo "▸ Making $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# hdiutil is occasionally "busy" on build machines; retry a few times.
for attempt in 1 2 3 4 5; do
    if hdiutil create -volname "Unique AV Countdown" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; then
        break
    fi
    echo "  hdiutil busy, retrying ($attempt)…"; sleep 5
    [ "$attempt" = 5 ] && exit 1
done
rm -rf "$STAGE"
echo "✓ $DMG"
echo "DMG=$DMG" >> "${GITHUB_ENV:-/dev/null}"
