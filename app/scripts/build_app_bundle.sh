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

# App icon (AppIcon.icns, referenced by Info.plist's CFBundleIconFile) plus the logo.png the
# About page loads at runtime. Both live in app/Resources/ (generated from app-icon.png).
cp "$APP_DIR/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$APP_DIR/Resources/logo.png" "$BUNDLE/Contents/Resources/logo.png"

# The frozen ccswitch-core binary — CoreBridge.resolveDefault() finds it here (Resources/
# ccswitch-core) and prefers it over the dev `uv run` path, so the packaged app is self-contained
# (no Python/uv on the user's machine). Build it with core/build_binary.sh first.
CORE_BIN="$APP_DIR/../core/dist/ccswitch-core"
if [ -x "$CORE_BIN" ]; then
  cp "$CORE_BIN" "$BUNDLE/Contents/Resources/ccswitch-core"
  chmod +x "$BUNDLE/Contents/Resources/ccswitch-core"
  echo "Bundled ccswitch-core binary"
else
  echo "WARNING: core/dist/ccswitch-core not found — run core/build_binary.sh. The app will fall back to dev (uv run) mode."
fi

codesign --force --deep --sign - "$BUNDLE"

# Forces Launch Services to (re-)read Info.plist's CFBundleURLTypes now, rather than waiting for
# its own discovery timing — otherwise a stale registration from a previous build can linger.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$BUNDLE"

echo "Built $BUNDLE"
