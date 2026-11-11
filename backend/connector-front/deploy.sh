#!/bin/sh
# Deploys the connector front to Vercel as an Edge Function: esbuild bundles
# connector-front/vercel-entry.ts into connector-front/dist/front.mjs (Vercel's bundler refuses
# Deno's explicit .ts import extensions), api/connector-front.js imports that bundle and
# carries the literal `export const config = { runtime: "edge" }` Vercel reads statically, and backend/vercel.json
# rewrites every path to it. Run from anywhere; it cd's to backend/.
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

run npx --yes esbuild@0.24.0 connector-front/vercel-entry.ts --bundle --format=esm --platform=browser --define:import.meta.main=false --outfile=connector-front/dist/front.mjs
run "$VERCEL" link --yes --project "$PROJECT"
setenv UPSTREAM_BASE "$UPSTREAM_BASE"
setenv PUBLIC_BASE "$PUBLIC_BASE"
[ -n "${UPSTREAM_APIKEY:-}" ] && setenv UPSTREAM_APIKEY "$UPSTREAM_APIKEY"
# The same value as agent-auth's LHF_FRONT_CLIENT_IP_SECRET: lets agent-auth
# rate-limit /authorize and /register per student instead of per Vercel
# egress address (docs/V11_TEST_BACKEND_2026-11-11.md). Left as is when unset.
[ -n "${CLIENT_IP_SECRET:-}" ] && setenv CLIENT_IP_SECRET "$CLIENT_IP_SECRET"
run "$VERCEL" deploy --prod --yes
