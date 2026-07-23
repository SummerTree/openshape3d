#!/usr/bin/env bash
#
# run_occt_spike.sh — Milestone 0 acceptance check.
#
# Compiles the OCCTBridge Obj-C++ shim + a tiny harness against the simulator
# slice of ThirdParty/OCCT.xcframework and runs it on a booted simulator,
# asserting the two spike facts (box meshes + exact volume; extruded circle is
# ONE analytic cylindrical face). Standalone on purpose — proves the kernel +
# shim link and run on iOS with zero Xcode-project changes.
#
#   SIM_UDID=<udid> scripts/run_occt_spike.sh
#
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_UDID="${SIM_UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}"
XCF="$REPO_ROOT/ThirdParty/OCCT.xcframework/ios-arm64-simulator"
BRIDGE="$REPO_ROOT/openshape3d/Kernel/OCCT"   # OCCTBridge.{h,mm} (also in the app target)
HARNESS="${HARNESS:-$REPO_ROOT/OCCTKit/OCCTSpikeMain.mm}"  # standalone main(), NOT in the app target
BIN="$(mktemp -d)/occt_spike"

[ -d "$XCF" ] || { echo "Missing $XCF — run scripts/build_occt_ios.sh first."; exit 2; }
[ -n "$SIM_UDID" ] || { echo "No booted simulator; boot one or set SIM_UDID."; exit 2; }

LIB="$(ls "$XCF"/libOCCT*.a 2>/dev/null | head -1)"
xcrun -sdk iphonesimulator clang++ \
  -arch arm64 -mios-simulator-version-min=16.0 -std=gnu++17 -fobjc-arc -O0 \
  -I"$XCF/Headers" -I"$BRIDGE" \
  "$BRIDGE/OCCTBridge.mm" "$HARNESS" "$LIB" \
  -lc++ -framework Foundation -o "$BIN"

echo "==> Running spike on simulator $SIM_UDID"
xcrun simctl spawn "$SIM_UDID" "$BIN"
