#!/usr/bin/env bash
# Prints the last brief the degree advisor built on the connected phone, plus a
# dump of every audit rule, so "why could the chat not fill this requirement"
# can be answered from what the model was actually shown.
#
# Only works against a Debug build: the file (degree-advisor-last.txt) is
# written under `#if DEBUG` and a Release or App Store build never makes it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p build
devices_json="build/devices.json"
out="build/degree-advisor-last.txt"

if ! xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1; then
  echo "Could not list devices. Is Xcode installed and opened once on this Mac?" >&2
  exit 1
fi

# The CoreDevice identifier of the phone, a cabled iPhone preferred (the same
# choice scripts/build-to-phone.sh makes).
device=$(/usr/bin/python3 - "$devices_json" <<'PY'
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
    if d.get("hardwareProperties", {}).get("platform") == "iOS" and d.get("identifier")
]
ios.sort(key=rank)
if ios:
    print(ios[0]["identifier"])
PY
)

if [ -z "$device" ]; then
  echo "No iPhone found. Plug it in, unlock it, then run this again." >&2
  exit 1
fi

rm -f "$out"
xcrun devicectl device copy from --device "$device" \
  --domain-type appDataContainer --domain-identifier com.lhf.lowhangingfruit \
  --source "Library/Application Support/LowHangingFruit/degree-advisor-last.txt" \
  --destination "$out"
cat "$out"
