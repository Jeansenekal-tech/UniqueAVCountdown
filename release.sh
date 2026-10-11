#!/bin/bash
# Builds a new version and publishes it as a GitHub release so installed copies get the update.
#
#   ./release.sh 1.1.0 "Added video PIP and crop"
#
# Needs the GitHub CLI once: `brew install gh` then `gh auth login`.
# Without gh, it still builds the zip and tells you what to upload.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
    CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
    echo "Usage: ./release.sh <new version> \"what's new\"   (current version: $CURRENT)"
    exit 1
fi

REPO=$(/usr/libexec/PlistBuddy -c "Print :UpdateGitHubRepo" Info.plist)
if [[ "$REPO" == YOUR-* ]]; then
    echo "✗ Set UpdateGitHubRepo in Info.plist to your GitHub name/repo first (e.g. jean/UniqueAVCountdown)."
    exit 1
fi

echo "▸ Setting version to $VERSION"
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

./build_app.sh

ZIP="build/UniqueAVCountdown-$VERSION.zip"
echo "▸ Zipping to $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Unique AV Countdown.app" "$ZIP"

if command -v gh >/dev/null 2>&1; then
    echo "▸ Publishing release v$VERSION to github.com/$REPO"
    gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Unique AV Countdown $VERSION" \
        --notes "${NOTES:-Version $VERSION}"
    echo "✓ Released. Installed copies will offer the update next time they open."
else
    echo "✓ Built $ZIP"
    echo "  Now on github.com/$REPO → Releases → Draft a new release:"
    echo "  tag v$VERSION, attach the zip, add notes, Publish."
fi
echo "  Remember to commit the version change in GitHub Desktop."
