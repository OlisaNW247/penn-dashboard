#!/bin/sh
# Deploys the connector front to Deno Deploy. Run from anywhere; it cd's to
# backend/ because main.ts imports ../supabase/functions/_shared/agentMetadata.ts
# and deployctl uploads relative to the working directory.
#
# Needs a Deno Deploy access token (dash.deno.com -> Account -> Access tokens)
# in $LHF_DENO_DEPLOY_TOKEN_FILE (default ~/lhf-bench/deno-deploy.token, mode
# 600). It is read into DENO_DEPLOY_TOKEN for the one process; never passed
# on the command line, never printed. `--project` creates the project when it
# does not exist yet, so the first run makes it.
#
# PUBLIC_BASE is derived from the project name, so renaming the project means
# redeploying the Edge Functions with the matching LHF_AGENT_PUBLIC_BASE
# (backend/scripts/deploy-agent.mjs --public-base ...). Order on the first
# deploy: this script, then the smoke checks in README.md, then the functions.
#
# Pass --dry-run to upload nothing. --prod makes it the live deployment;
# without it only the first ever deployment is production.
set -eu
PROJECT="${LHF_CONNECTOR_PROJECT:-smooth-agent}"
UPSTREAM_BASE="${UPSTREAM_BASE:-https://ynetfjixexksxqrrkwsg.supabase.co/functions/v1}"
PUBLIC_BASE="${PUBLIC_BASE:-https://$PROJECT.deno.dev/functions/v1}"
TOKEN_FILE="${LHF_DENO_DEPLOY_TOKEN_FILE:-$HOME/lhf-bench/deno-deploy.token}"

if ! command -v deployctl >/dev/null 2>&1; then
  if [ -x "$HOME/.deno/bin/deployctl" ]; then PATH="$HOME/.deno/bin:$PATH"; else
    echo "deployctl not installed: deno install -gArf jsr:@deno/deployctl" >&2; exit 1; fi
fi
if [ -z "${DENO_DEPLOY_TOKEN:-}" ]; then
  if [ ! -r "$TOKEN_FILE" ]; then
    echo "no Deno Deploy token: put one from dash.deno.com (Account -> Access tokens) in $TOKEN_FILE (chmod 600)" >&2
    exit 1
  fi
  DENO_DEPLOY_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  export DENO_DEPLOY_TOKEN
fi

cd "$(dirname "$0")/.."
echo "project $PROJECT"
echo "UPSTREAM_BASE $UPSTREAM_BASE"
echo "PUBLIC_BASE $PUBLIC_BASE"
APIKEY_ARG=""
[ -n "${UPSTREAM_APIKEY:-}" ] && APIKEY_ARG="--env=UPSTREAM_APIKEY=$UPSTREAM_APIKEY"
# shellcheck disable=SC2086
exec deployctl deploy --project="$PROJECT" --entrypoint=connector-front/main.ts \
  --include=connector-front --include=supabase/functions/_shared \
  --env="UPSTREAM_BASE=$UPSTREAM_BASE" --env="PUBLIC_BASE=$PUBLIC_BASE" $APIKEY_ARG \
  --prod "$@"
