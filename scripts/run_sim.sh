#!/bin/bash
# Build, install, and launch openshape3d on the iPad simulator, then screenshot.
# Usage: scripts/run_sim.sh [screenshot_path] [--no-build]
set -e
UDID="69DB84F4-607C-46F2-9089-3E8C0770B4A9"   # iPad Pro 13-inch (M5)
BUNDLE="com.laan.labs.openshape3d"
SHOT="${1:-}"

cd "$(dirname "$0")/.."

if [[ "$2" != "--no-build" ]]; then
  xcodebuild build -project openshape3d.xcodeproj -scheme openshape3d \
    -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -quiet 2>&1 \
    | grep -E "error:" && exit 1 || true
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || { xcrun simctl boot "$UDID"; sleep 8; }

APP_PATH=$(xcodebuild -project openshape3d.xcodeproj -scheme openshape3d \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -showBuildSettings 2>/dev/null \
  | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')/openshape3d.app

xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
SIMCTL_CHILD_OS3D_AUTO_OPEN=1 xcrun simctl launch "$UDID" "$BUNDLE"

if [[ -n "$SHOT" ]]; then
  sleep 4
  xcrun simctl io "$UDID" screenshot "$SHOT"
fi
