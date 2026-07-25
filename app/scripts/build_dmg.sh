#!/bin/sh
# Packages the built .app into a distributable .dmg (drag-to-Applications installer). Run
# core/build_binary.sh and build_app_bundle.sh (with the config you want) first. This only wraps
# the already-built bundle.
#
# NOTE: the .app is ad-hoc signed, not notarized. This DMG opens fine on THIS Mac, but on another
# Mac macOS Gatekeeper will quarantine it, so the recipient must right-click then Open the first time
# (or run `xattr -dr com.apple.quarantine` on it). A clean "download and open" needs Developer ID
# signing + notarization, which requires an Apple Developer account.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_DIR="$SCRIPT_DIR/.."
BUNDLE="$APP_DIR/.build/ClaudeCodeSwitcher.app"
VERSION="${1:-0.1}"
DMG="$APP_DIR/.build/ClaudeCodeSwitcher-$VERSION.dmg"

[ -d "$BUNDLE" ] || { echo "No .app at $BUNDLE. Run build_app_bundle.sh first."; exit 1; }

# Stage the .app plus an /Applications symlink so the DMG shows the familiar drag-to-install layout.
STAGE=$(mktemp -d)/dmg
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Claude Code Switcher" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Built $DMG"
