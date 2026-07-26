#!/bin/bash
# Regenerate the App Store screenshots for LHF (6.9" iPhone).
# Builds a DEBUG app, boots the simulator, and captures each screen using the
# DEBUG-only `-LHFDemoData` launch seam (compiled out of release builds).
# Run from anywhere: bash docs/appstore/capture-screenshots.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DEVICE="iPhone 17 Pro Max"        # 6.9" — the size the App Store requires
BUNDLE="com.lhf.lowhangingfruit"
DD="build/screenshots"            # DerivedData (gitignored)
APP="$DD/Build/Products/Debug-iphonesimulator/LowHangingFruit.app"
OUT="docs/appstore/screenshots"
mkdir -p "$OUT"

echo "Building DEBUG app…"
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -destination "platform=iOS Simulator,name=$DEVICE" -configuration Debug \
  -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/dev/null

echo "Booting $DEVICE…"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged \
  --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true
# Uninstall first. Installing over an existing copy inherits its UserDefaults,
# so leftover state from an earlier run — including real course codes from a
# real Canvas login done in this simulator — leaks into the screenshots. That
# is both non-deterministic and a data-hygiene problem, since these PNGs get
# committed.
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

shot() {
  local name="$1"; shift
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$DEVICE" "$BUNDLE" "$@" >/dev/null
  sleep 6
  xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png"
  echo "  $name.png"
}

shot "1-onboarding"
shot "2-dashboard-thisweek" -LHFDemoData
shot "3-dashboard-all"      -LHFDemoData -LHFTabAll
shot "4-dashboard-done"     -LHFDemoData -LHFTabDone
shot "5-settings-reminders" -LHFDemoData -LHFShowSettings

xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
echo "Done → $OUT"
echo
echo "Not captured automatically (do these by hand):"
echo "  • dark mode — Settings → Appearance → Dark, then retake 2"
echo "  • the Home/Lock Screen widget — add it from the widget gallery"
