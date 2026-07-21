#!/bin/sh
# Freezes ccswitch-core into a single standalone executable (dist/ccswitch-core) with PyInstaller,
# so the packaged .app needs no Python or uv on the user's machine — the app spawns this binary
# directly (CoreBridge's `.bundled` location). Run this before build_app_bundle.sh when the core
# changed; the app-bundle script copies whatever dist/ccswitch-core it finds.
#
# --onefile keeps CoreBridge's "one executable at Resources/ccswitch-core" expectation intact (it
# checks for a single executable file, not a directory). The tradeoff is a ~sub-second self-extract
# on each invocation; fine for this app's low call rate. Switch to --onedir + a path tweak if that
# ever bites.
set -eu
cd "$(dirname "$0")"

uv run pyinstaller --onefile --name ccswitch-core --clean --noconfirm \
  --distpath dist --workpath build/pyi --specpath build pyinstaller_entry.py

echo "Built $(pwd)/dist/ccswitch-core"
