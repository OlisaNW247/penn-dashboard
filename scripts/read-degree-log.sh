#!/usr/bin/env bash
# Prints why the last Path@Penn read failed on the plugged-in iPhone: the
# degree portal's own step log, the tail of the silent Canvas sign-in log, and
# the timestamps of the shared PennKey budget, all from the app's settings
# file. Written on 2026-11-26, when the degree chat answered "couldn't read
# path@penn's audit for management (general)" and nothing on screen said
# whether Penn's sign-in had timed out, was waiting on Duo, or had been held
# back by the ten-minute PennKey budget the Canvas sign-in shares with it.
#
# What it prints holds no cookie, token, password, URL path, course or name:
# the two logs are step words and host names by construction
# (`DebugDegreeLog`, `debugRenewalLogV1`), and the rest are dates and flags.
# The output is also written to build/degree-log.txt and stays on this Mac
# unless you choose to share it.
#
# Only works against a Debug build: the App Store copy's container cannot be
# read, and a Release build keeps neither log.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p build
devices_json="build/devices.json"
plist="build/lhf-group.plist"
out="build/degree-log.txt"

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

rm -f "$plist"
xcrun devicectl device copy from --device "$device" \
  --domain-type appGroupDataContainer --domain-identifier group.com.lhf.lowhangingfruit \
  --source Library/Preferences/group.com.lhf.lowhangingfruit.plist \
  --destination "$plist" >/dev/null

/usr/bin/python3 - "$plist" > "$out" <<'PY'
import plistlib, sys

with open(sys.argv[1], "rb") as handle:
    prefs = plistlib.load(handle)

print("== degree portal log (debugDegreeLogV1, oldest first)")
for line in prefs.get("debugDegreeLogV1", []) or ["(empty)"]:
    print("  ", line)

print()
print("== silent canvas sign-in log (debugRenewalLogV1, last 15)")
for line in (prefs.get("debugRenewalLogV1", []) or ["(empty)"])[-15:]:
    print("  ", line)

print()
print("== flags and dates")
# Every key that mentions the renewal, the PennKey budget, Duo or the degree
# feature, so a renamed key still shows. Values that are not a date, a number,
# a flag or a short line of words are reduced to their type.
words = ("renewal", "credential", "duo", "autologin", "degree", "canvassession")
skip = {"debugDegreeLogV1", "debugRenewalLogV1"}
for key in sorted(prefs):
    if key in skip or not any(word in key.lower() for word in words):
        continue
    value = prefs[key]
    if isinstance(value, (bool, int, float)) or hasattr(value, "isoformat"):
        shown = value
    elif isinstance(value, str) and len(value) <= 160 and "://" not in value:
        shown = value
    else:
        shown = "(%s)" % type(value).__name__
    print("  ", key, "=", shown)
PY
cat "$out"
