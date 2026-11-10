#!/bin/bash
# Runs the schema the way a Supabase project would see it, in a throwaway
# Postgres 16 container: the auth stub, every migration in order, the facts
# migration a second time (it must be idempotent), then rls.test.sql and
# claim_fact_extraction.test.sql. Needs Docker (OrbStack on Marco's Mac:
# `open -a OrbStack` first). No psql is needed on the host. Exit non-zero on
# the first failure. 2026-11-04.
set -u
cd "$(dirname "$0")/.." || exit 1
NAME=lhf-pg-check
docker rm -f $NAME >/dev/null 2>&1
docker run --rm -d --name $NAME -e POSTGRES_PASSWORD=lhf postgres:16 >/dev/null || exit 1
trap 'docker rm -f $NAME >/dev/null 2>&1' EXIT
for i in $(seq 1 30); do docker exec $NAME pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker cp test $NAME:/t >/dev/null && docker cp supabase/migrations $NAME:/m >/dev/null
P() { docker exec $NAME psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }
P -f /t/local_auth_stub.sql >/dev/null || exit 1
for f in $(ls supabase/migrations); do P -f "/m/$f" >/dev/null || { echo "FAIL migration $f"; exit 1; }; done
echo "migrations: all $(ls supabase/migrations | wc -l | tr -d ' ') applied"
P -f /m/20261104090000_course_facts.sql >/dev/null 2>&1 || { echo "FAIL: course_facts migration is not idempotent"; exit 1; }
echo "course_facts migration: idempotent"
P -f /m/20261105090000_finish_fact_extraction.sql >/dev/null 2>&1 || { echo "FAIL: finish_fact_extraction migration is not idempotent"; exit 1; }
echo "finish_fact_extraction migration: idempotent"
P -f /m/20261108090000_agent_connection.sql >/dev/null 2>&1 || { echo "FAIL: agent_connection migration is not idempotent"; exit 1; }
echo "agent_connection migration: idempotent"
P -f /m/20261109090000_agent_hardening.sql >/dev/null 2>&1 || { echo "FAIL: agent_hardening migration is not idempotent"; exit 1; }
echo "agent_hardening migration: idempotent"
P -f /m/20261109100000_agent_drafts.sql >/dev/null 2>&1 || { echo "FAIL: agent_drafts migration is not idempotent"; exit 1; }
echo "agent_drafts migration: idempotent"
P -f /m/20261110090000_agent_uploads.sql >/dev/null 2>&1 || { echo "FAIL: agent_uploads migration is not idempotent"; exit 1; }
echo "agent_uploads migration: idempotent"
P -f /t/rls.test.sql 2>&1 | tail -1 || exit 1
P -f /t/claim_fact_extraction.test.sql 2>&1 | grep -E 'passed|ERROR' | tail -1
P -f /t/finish_fact_extraction.test.sql 2>&1 | grep -E 'passed|ERROR' | tail -1
P -f /t/agent_connection.test.sql 2>&1 | grep -E 'passed|ERROR' | tail -1
P -f /t/agent_hardening.test.sql 2>&1 | grep -E 'passed|ERROR' | tail -1
P -f /t/agent_uploads.test.sql 2>&1 | grep -E 'passed|ERROR' | tail -1
