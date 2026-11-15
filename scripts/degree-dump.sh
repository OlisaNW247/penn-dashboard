#!/usr/bin/env bash
# Prints a plain-text summary of the degree audits, semester history and plan
# that the Smooth app has saved on the plugged-in iPhone, so a feasibility
# question ("can I finish both degrees by spring 2028?") can be answered from
# Penn's actual audit rather than from a screenshot.
#
# What it reads, all from the app's own container on the phone:
#   Library/Application Support/LowHangingFruit/degree-audit.json
#   Library/Application Support/LowHangingFruit/degree-plan.json
# Neither file holds a grade, a GPA, a name or an id (the audit model has no
# field for them). The output is written to build/degree-dump.txt and printed;
# it stays on this Mac unless you choose to share it.
#
# Only works while a Debug build of Smooth is installed (the App Store copy's
# container cannot be read with devicectl).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p build
devices_json="build/devices.json"

if ! xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1; then
  echo "Could not list devices. Is Xcode installed and opened once on this Mac?" >&2
  exit 1
fi

device=$(/usr/bin/python3 - "$devices_json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
def rank(d):
    hw = d.get("hardwareProperties", {}); conn = d.get("connectionProperties", {})
    return (0 if conn.get("tunnelState") == "connected" else 1,
            0 if conn.get("transportType") == "wired" else 1,
            0 if hw.get("deviceType") == "iPhone" else 1)
ios = [d for d in devices if d.get("hardwareProperties", {}).get("platform") == "iOS" and d.get("identifier")]
ios.sort(key=rank)
if ios: print(ios[0]["identifier"])
PY
)

if [ -z "$device" ]; then
  echo "No iPhone found. Plug it in, unlock it, then run this again." >&2
  exit 1
fi

for name in degree-audit.json degree-plan.json; do
  rm -f "build/$name"
  xcrun devicectl device copy from --device "$device" \
    --domain-type appDataContainer --domain-identifier com.lhf.lowhangingfruit \
    --source "Library/Application Support/LowHangingFruit/$name" \
    --destination "build/$name" >/dev/null 2>&1 || echo "(could not copy $name)" >&2
done

/usr/bin/python3 - build/degree-audit.json build/degree-plan.json > build/degree-dump.txt <<'PY'
import json, os, sys

def load(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)

snap = load(sys.argv[1]) or {}
plan = load(sys.argv[2]) or {}

def num(v):
    if v is None: return None
    try:
        v = float(v)
    except Exception:
        return None
    return int(v) if v == int(v) else round(v, 2)

def status(s):
    if isinstance(s, dict):  # Swift enum encoded as {"open": {}}
        return next(iter(s.keys()), "?")
    return str(s)

def rules(items, depth, out):
    for r in items or []:
        pad = "  " * depth
        need = []
        if r.get("needCredits") is not None: need.append(f"need {num(r['needCredits'])} cu")
        if r.get("needCourses") is not None: need.append(f"need {r['needCourses']} courses")
        applied = r.get("applied") or []
        has = ", ".join(
            f"{a.get('code')}{' (now)' if a.get('isInProgress') else ''}{' [' + str(num(a.get('credits'))) + ']' if a.get('credits') is not None else ''}"
            for a in applied)
        advice = r.get("advice") or []
        opts = ", ".join(a.get("code", "") for a in advice[:15])
        if len(advice) > 15: opts += f", +{len(advice) - 15} more"
        line = f"{pad}- [{status(r.get('status'))}] {r.get('label') or r.get('ruleType') or 'rule'}"
        if r.get("percentComplete") is not None: line += f" ({num(r['percentComplete'])}%)"
        if need: line += " | " + ", ".join(need)
        if has: line += f" | has: {has}"
        if opts: line += f" | options: {opts}"
        words = (r.get("adviceText") or "").strip().replace("\n", " ")
        if words: line += f" | penn's words: {words[:300]}"
        out.append(line)
        rules(r.get("children"), depth + 1, out)

def audit(a, title, out):
    if not a:
        return
    out.append("")
    out.append("=" * 70)
    g = a.get("goals") or {}
    out.append(f"{title}: {a.get('degreeLabel') or ''} | penn %: {num(a.get('percentComplete'))} | what-if: {a.get('isWhatIf')}")
    out.append(f"goals: college={g.get('college')} degree={g.get('degree')} program={g.get('program')} majors={g.get('majors')} concentrations={g.get('concentrations')} minors={g.get('minors')} catalog={g.get('catalogYear')}")
    out.append(f"read at: {a.get('fetchedAt')}")
    for b in a.get("blocks") or []:
        out.append("")
        out.append(f"[{b.get('type')}] {b.get('title')} ({num(b.get('percentComplete'))}%)")
        rules(b.get("rules"), 1, out)

out = []
out.append("DEGREES ON RECORD")
for d in snap.get("degrees") or []:
    out.append(f"- college={d.get('college')} degree={d.get('degree')} program={d.get('program')} majors={d.get('majors')} concentrations={d.get('concentrations')} minors={d.get('minors')} catalog={d.get('catalogTerm')}")
out.append(f"selected: {snap.get('selectedDegreeID')}")

out.append("")
out.append("SEMESTERS (from penn's record)")
for term in sorted((snap.get("history") or {}).keys()):
    out.append(f"{term}: {', '.join(snap['history'][term])}")

audit(snap.get("current"), f"SELECTED DEGREE ({snap.get('selectedDegreeID')})", out)
for key, shelf in sorted((snap.get("shelved") or {}).items()):
    audit((shelf or {}).get("audit"), f"OTHER DEGREE ({key})", out)
for i, w in enumerate(snap.get("whatIfs") or []):
    audit(w, f"WHAT-IF {i + 1} (selected degree)", out)
for key, shelf in sorted((snap.get("shelved") or {}).items()):
    for i, w in enumerate((shelf or {}).get("whatIfs") or []):
        audit(w, f"WHAT-IF {i + 1} (degree {key})", out)

out.append("")
out.append("=" * 70)
out.append("YOUR PLAN IN SMOOTH")
for t in plan.get("terms") or []:
    cs = t.get("courses") or []
    total = sum((c.get("credits") or 0) for c in cs)
    out.append(f"{t.get('termCode')} ({num(total)} cu): " + ", ".join(
        f"{c.get('code')}{' [pick: ' + c['pickLabel'] + ']' if c.get('pickLabel') else ''}" for c in cs))

print("\n".join(out))
PY

cat build/degree-dump.txt
echo
echo "Saved to build/degree-dump.txt"
