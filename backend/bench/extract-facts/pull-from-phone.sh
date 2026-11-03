#!/bin/sh
# Copies a paired iPhone's course-knowledge.json (the on-device pool of
# course documents the sync built) into an untracked folder, so
# knowledge-to-corpus.ts can turn it into bench documents. Read-only on
# the phone. Needs a DEBUG build installed: against the App Store copy the
# container is sealed and devicectl fails with ContainerLookupErrorDomain
# error 7 (CLAUDE.md -> Commands). The file lands in corpus/phone/, which
# .gitignore keeps out of the repo because it holds real course text.
#
#   sh backend/bench/extract-facts/pull-from-phone.sh <CoreDevice id> <label>
#
# CoreDevice ids come from `xcrun devicectl list devices`; Marco's iPhone
# 17 Pro is 8A287085-9C88-5A87-816B-1A8EF80D67AD. The ledger
# (Assignments.store) is deliberately not copied: the bench's item index
# comes from the pool's assignment documents, and the ledger holds the
# student's completions, which must stay on the phone.
set -eu
device="${1:?CoreDevice id}"
label="${2:?a label such as marco}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/corpus/phone/$label"
mkdir -p "$out"
xcrun devicectl device copy from --device "$device" \
  --domain-type appDataContainer --domain-identifier com.lhf.lowhangingfruit \
  --source "Library/Application Support/LowHangingFruit/course-knowledge.json" \
  --destination "$out/course-knowledge.json"
ls -l "$out/course-knowledge.json"
echo "next: deno run --allow-read --allow-write $here/knowledge-to-corpus.ts --knowledge $out/course-knowledge.json --out $out"
