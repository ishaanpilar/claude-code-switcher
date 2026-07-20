#!/bin/sh
# Assembles ClaudeCodeSwitcher.app from the swift build output. Needed for anything Launch
# Services must recognize — the CFBundleURLTypes scheme (ccswitch://, for the magic-link
# callback), local notifications, launch-at-login — none of which a bare `swift build` binary can
# register, since those all require a real .app bundle with an Info.plist.
#
# Ad-hoc signed (`codesign --sign -`), not a Developer ID signature: fine for running locally on
# this Mac, but NOT what BUILD_PLAN.md Phase 5's "code-signing + notarization for distribution"
# means — that needs a real Apple Developer account to sign for other people's Macs.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_DIR="$SCRIPT_DIR/.."
CONFIG="${1:-debug}"

swift build --package-path "$APP_DIR" -c "$CONFIG"

BUNDLE="$APP_DIR/.build/ClaudeCodeSwitcher.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$APP_DIR/.build/$CONFIG/ClaudeCodeSwitcher" "$BUNDLE/Contents/MacOS/ClaudeCodeSwitcher"
cp "$SCRIPT_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"

codesign --force --deep --sign - "$BUNDLE"

# Forces Launch Services to (re-)read Info.plist's CFBundleURLTypes now, rather than waiting for
# its own discovery timing — otherwise a stale registration from a previous build can linger.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$BUNDLE"

echo "Built $BUNDLE"
