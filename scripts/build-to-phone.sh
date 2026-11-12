#!/usr/bin/env bash
# Builds the Debug app from this checkout and puts it on the iPhone that is
# plugged into this Mac:   bash scripts/build-to-phone.sh
#
# It exists because the three steps in CLAUDE.md -> Commands need two different
# ids for the same phone (xcodebuild wants the hardware UDID, devicectl wants the
# CoreDevice identifier), and copying them by hand out of two listings is where a
# build session usually goes wrong. On 2026-11-11 a pasted block of those commands
# also hung at zsh's `quote>` prompt: an interactive zsh does not treat `#` as a
# comment, so an apostrophe inside one opened a string. A script has neither
# problem. It changes nothing in git and writes only under build/, which is ignored.
#
# Installing a Debug build over the App Store copy keeps the student's data (same
# team, same App Group and Keychain); going back to the store copy means deleting
# the app. CLAUDE.md -> Commands says the same.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p build
devices_json="build/devices.json"
log="build/phone-build.log"

if ! xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1; then
  echo "Could not list devices. Is Xcode installed and opened once on this Mac?" >&2
  exit 1
fi

# One line: UDID, CoreDevice identifier, name. A cabled iPhone is preferred to one
# seen over Wi-Fi, and an iPhone to an iPad, so the phone in your hand wins.
picked=$(/usr/bin/python3 - "$devices_json" <<'PY'
import json, sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])


def rank(d):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    return (
        0 if conn.get("tunnelState") == "connected" else 1,
        0 if conn.get("transportType") == "wired" else 1,
        0 if hw.get("deviceType") == "iPhone" else 1,
    )


ios = [
    d
    for d in devices
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("hardwareProperties", {}).get("udid")
    and d.get("identifier")
]
ios.sort(key=rank)
if ios:
    d = ios[0]
    name = d.get("deviceProperties", {}).get("name", "iPhone")
    conn = d.get("connectionProperties", {})
    state = conn.get("tunnelState") or "unknown"
    link = conn.get("transportType") or "none"
    print(d["hardwareProperties"]["udid"], d["identifier"], state, link, name, sep="\t")
PY
)

if [ -z "$picked" ]; then
  echo "No iPhone found. Plug it in, unlock it, tap Trust if it asks, then run this again." >&2
  echo "If it has never been used with Xcode on this Mac, open Xcode -> Window -> Devices and Simulators once." >&2
  exit 1
fi

IFS=$'\t' read -r udid device state link name <<<"$picked"
echo "Phone: $name (connection: $state, link: $link)"
echo "Building (a first build takes several minutes; the full log is $log)..."

build_for() {
  xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug \
    -destination "$1" -derivedDataPath build/dd -allowProvisioningUpdates build >"$log" 2>&1
}

# devicectl and xcodebuild find devices through different services, and they do
# not always agree: on 2026-11-11 devicectl listed the phone while xcodebuild's
# destination list held only the Mac and the simulators, not even the phone as
# "ineligible". A build for "any iPhone" needs no device at all and produces the
# same Debug-iphoneos/Smooth.app, so when xcodebuild cannot find the phone the
# build is tried that way and devicectl does the install. The by-id build is
# still tried first because it is the one that registers a phone this Mac has
# never built for.
set +e
build_for "id=$udid"
status=$?
if [ "$status" -ne 0 ] && grep -q "Unable to find a destination" "$log"; then
  cp "$log" build/phone-build-first-try.log
  echo "xcodebuild cannot see the phone itself. Building for any iPhone and installing after..."
  build_for "generic/platform=iOS"
  status=$?
fi
set -e
if [ "$status" -ne 0 ] || ! grep -q "BUILD SUCCEEDED" "$log"; then
  echo "The build failed. The errors:" >&2
  grep -E "error:|BUILD FAILED" "$log" | sort -u | tail -30 >&2
  # "Unable to find a destination" is not a compile error, and what xcodebuild
  # could build for is on the lines after it. The grep above drops those lines,
  # which on 2026-11-11 left the error ending at its colon with nothing after it.
  if grep -q "Unable to find a destination" "$log"; then
    echo "xcodebuild found no destination to build for. What it said:" >&2
    grep -A 25 "Unable to find a destination" "$log" | sed -n '2,26p' >&2
  fi
  exit 1
fi
echo "Built."

app="build/dd/Build/Products/Debug-iphoneos/Smooth.app"
echo "Installing..."
xcrun devicectl device install app --device "$device" "$app" >>"$log" 2>&1 || {
  echo "The install failed. What devicectl said:" >&2
  grep -iE "error|not connected|unavailable|unlock|trust" "$log" | tail -8 >&2
  echo "Unplug the phone and plug it back in, unlock it, tap Trust if it asks, then run this again." >&2
  exit 1
}
echo "Installed."

# A locked phone refuses the launch but keeps the install, so this is not an error.
if xcrun devicectl device process launch --device "$device" com.lhf.lowhangingfruit >>"$log" 2>&1; then
  echo "Launched on $name."
else
  echo "Installed, but the phone would not launch it (usually because it is locked). Open Smooth on the phone."
fi
