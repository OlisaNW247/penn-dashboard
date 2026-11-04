#!/bin/bash
# Reads the facts/structured-source state off a paired iPhone (a DEBUG build
# must be installed; the App Store copy refuses, see CLAUDE.md "Commands").
# Usage: backend/scripts/verify-facts-on-phone.sh <CoreDevice id>
#   (list ids with: xcrun devicectl list devices)
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <CoreDevice id>" >&2
  exit 1
fi
device="$1"
dest="${LHF_PLIST_DEST:-/tmp/lhf.plist}"

xcrun devicectl device copy from --device "$device" \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.lhf.lowhangingfruit \
  --source Library/Preferences/group.com.lhf.lowhangingfruit.plist \
  --destination "$dest" >/dev/null

pb() { /usr/libexec/PlistBuddy -c "$1" "$dest" 2>/dev/null || true; }

# Count the entries of an array-typed key; "absent" when the key is missing.
count() {
  local out
  out="$(pb "Print :$1")"
  if [ -z "$out" ]; then echo "absent"; return; fi
  # PlistBuddy prints `Array {` ... `}` with one element per line.
  echo "$out" | sed '1d;$d' | grep -c . || true
}

summary="$(pb 'Print :lastStructuredSourcesSyncSummaryV1')"
cursor="$(pb 'Print :factsCursorV1')"

echo "lastStructuredSourcesSyncSummaryV1: ${summary:-absent}"
echo "  Healthy: counts only, like `rows=12 completions=1 dismissals=0 dueOverrides=3 missing=0`, rewritten on every refresh. `skipped: <reason>` is also fine (the step declined to run, e.g. no session). Absent means the step has never run on this build, or Canvas was disconnected, or FeatureFlags.structuredCanvasSources is off."
echo
echo "factsCursorV1: ${cursor:-absent}"
echo "  Healthy: a non-negative integer. 0 right after a first sync of a course with no facts yet; it only ever grows, and equals the highest course_facts seq the server has handed this phone. Absent means no manifest with the facts fields has completed."
echo
echo "structuredDismissedItemIDsV1 count: $(count structuredDismissedItemIDsV1)"
echo "  Healthy: a small number of Canvas-planner dismissals the dashboard follows (it equals `dismissals` in the summary only on the first sync). A count that jumps with no action by the student is suspicious."
echo
echo "structuredCompletedItemIDsV1 count: $(count structuredCompletedItemIDsV1)"
echo "  Healthy: items Canvas itself reports completed. Fact application never writes here, so opening a fact-touched card, tapping undo and re-reading must leave this count unchanged."
echo
echo "(plist copied to $dest; it is not committed anywhere and holds no cookies)"
