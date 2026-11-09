#!/bin/sh
# Deploys the connector front to Vercel as an Edge Function (backend/api/connector-front.ts,
# every path rewritten to it by backend/vercel.json). Run from anywhere; it cd's to backend/.
#
# One-time: `vercel login`. This script never logs in and never prints a secret.
#
# It deploys to PRODUCTION on purpose: on the Hobby plan preview deployments sit behind
# Vercel Authentication, which would answer Claude's requests with a login page.
#
# PUBLIC_BASE defaults from the project name; the Edge Functions must be deployed with a
# matching LHF_AGENT_PUBLIC_BASE (backend/scripts/deploy-agent.mjs --public-base ...).
# Env vars are replaced each run (rm, then add from stdin).
#
# --dry-run prints the commands and runs nothing.
set -eu
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
PROJECT="${LHF_CONNECTOR_PROJECT:-smooth-agent}"
UPSTREAM_BASE="${UPSTREAM_BASE:-https://ynetfjixexksxqrrkwsg.supabase.co/functions/v1}"
PUBLIC_BASE="${PUBLIC_BASE:-https://$PROJECT.vercel.app/functions/v1}"

cd "$(dirname "$0")/.."
VERCEL="${VERCEL_BIN:-vercel}"
command -v "$VERCEL" >/dev/null 2>&1 || { [ -x "$HOME/.npm-global/bin/vercel" ] && VERCEL="$HOME/.npm-global/bin/vercel"; }

echo "project $PROJECT"
echo "UPSTREAM_BASE $UPSTREAM_BASE"
echo "PUBLIC_BASE $PUBLIC_BASE"

run() {
  if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi
}
setenv() {
  # $1 name, $2 value (value goes via stdin, never argv or output)
  if [ "$DRY" = 1 ]; then echo "+ $VERCEL env rm $1 production -y; printf <value> | $VERCEL env add $1 production"; return; fi
  "$VERCEL" env rm "$1" production -y >/dev/null 2>&1 || true
  printf '%s' "$2" | "$VERCEL" env add "$1" production >/dev/null
}

if [ "$DRY" = 0 ]; then
  "$VERCEL" whoami >/dev/null 2>&1 || { echo "not logged in: run \`vercel login\` once" >&2; exit 1; }
fi

run "$VERCEL" link --yes --project "$PROJECT"
setenv UPSTREAM_BASE "$UPSTREAM_BASE"
setenv PUBLIC_BASE "$PUBLIC_BASE"
[ -n "${UPSTREAM_APIKEY:-}" ] && setenv UPSTREAM_APIKEY "$UPSTREAM_APIKEY"
run "$VERCEL" deploy --prod --yes
