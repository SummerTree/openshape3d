#!/bin/bash
# Pull kernel capture bundles (docs/FREECAD_PLAYBOOK.md D2) out of the
# simulator's app sandbox. A DEBUG app writes them to Documents/KernelCaptures
# whenever a kernel op fails (and on POST /v1/capture); this copies them to a
# local directory ready to inspect or promote into
# openshape3dTests/Fixtures/Captures as regression fixtures.
#
# Usage: scripts/fetch_captures.sh [dest_dir]   (default ./captures)
set -e
xcrun --find simctl >/dev/null 2>&1 || export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUNDLE="com.laan.labs.openshape3d"
DEST="${1:-captures}"

CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE" data 2>/dev/null) \
  || { echo "No booted simulator with $BUNDLE installed." >&2; exit 1; }
SRC="$CONTAINER/Documents/KernelCaptures"
[[ -d "$SRC" ]] || { echo "No captures at $SRC — nothing has failed (or capture is off)." >&2; exit 1; }

mkdir -p "$DEST"
cp -R "$SRC"/. "$DEST"/
echo "Copied $(ls "$SRC" | wc -l | tr -d ' ') bundle(s) to $DEST:"
ls "$DEST"
