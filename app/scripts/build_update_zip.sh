#!/bin/sh
# Builds and signs the Sparkle auto-update payload from the .app build_app_bundle.sh already
# produced. Separate from build_dmg.sh: Sparkle's tooling (sign_update/appcast enclosures) expects
# a .zip of the .app, not a disk image. The DMG stays the manual/first-install artifact; this zip
# is only ever fetched in-app via the appcast.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_DIR="$SCRIPT_DIR/.."
BUNDLE="$APP_DIR/.build/ClaudeCodeSwitcher.app"
VERSION="${1:-0.1}"
TAG="v${VERSION}.0"
ZIP="$APP_DIR/.build/ClaudeCodeSwitcher-$VERSION.zip"

[ -d "$BUNDLE" ] || { echo "No .app at $BUNDLE. Run build_app_bundle.sh release first."; exit 1; }

SIGN_UPDATE=$(find "$APP_DIR/.build/artifacts" -type f -name sign_update ! -path "*/old_dsa_scripts/*" | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "No sign_update found under .build/artifacts. Run swift build first."; exit 1; }

BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUNDLE/Contents/Info.plist")

rm -f "$ZIP"
# ditto, not `zip -r`: preserves the bundle/resource-fork structure codesign validation needs.
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"

SIG_FRAGMENT=$("$SIGN_UPDATE" "$ZIP")
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
URL="https://github.com/ishaanpilar/claude-code-switcher/releases/download/$TAG/ClaudeCodeSwitcher-$VERSION.zip"

cat <<XML

Built and signed: $ZIP

Paste into app/appcast.xml (inside <channel>, above the previous <item>) AFTER the GitHub
release + its .zip asset exist (the enclosure url below must already resolve), then fill in
this release's "What's new" bullets:

  <item>
    <title>Version $VERSION</title>
    <pubDate>$PUBDATE</pubDate>
    <sparkle:version>$BUILD_NUMBER</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
      <ul>
        <li>TODO: paste this release's "What's new" bullets here</li>
      </ul>
    ]]></description>
    <enclosure url="$URL" type="application/octet-stream" $SIG_FRAGMENT />
  </item>

XML
