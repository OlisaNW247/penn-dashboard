#!/usr/bin/env bash
# usage: verify-sites-bytes.sh <original index.js> <edited index.js>
# Line 22 (the embedded images) must be identical, and apart from it the files may
# differ only by edits A and B and the generated section.
set -euo pipefail
o=$1; e=$2
[ "$(sed -n 22p "$o" | sha256sum)" = "$(sed -n 22p "$e" | sha256sum)" ] && echo "line 22 identical" || { echo "line 22 DIFFERS"; exit 1; }
mark=$(grep -n '^// >>> smooth-ambassadors' "$e" | cut -d: -f1)
diff <(sed '22d' "$o") <(head -n $((mark-1)) "$e" | sed '22d') || true
