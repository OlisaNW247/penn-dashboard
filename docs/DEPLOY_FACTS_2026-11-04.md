# Deploying extract-facts to production (runbook, 2026-11-04)

Nothing here has been run. The scripts were written and tested with `fetch`
stubbed on 2026-11-04; the live project, the Management API and OpenRouter
have not been called. A green `--dry-run` proves the plan, not the deploy.

What goes live: migration `20261104090000_course_facts.sql` (three tables,
one function, one column), the `sync` function (manifest now carries `facts`
and `factsCursor`) and the new `extract-facts` function. Contract:
`backend/PROTOCOL.md`, sections "sync" and "Facts and `extract-facts`".

## Prerequisites

1. A Supabase personal access token, from
   supabase.com/dashboard/account/tokens (name it for this deploy; revoke it
   afterwards). It can read secrets and run SQL on every project in the
   account, so treat it like a password.
2. Save it where the scripts look, and lock the file:
   ```bash
   mkdir -p ~/lhf-bench && umask 077 && pbpaste > ~/lhf-bench/supabase.token
   chmod 600 ~/lhf-bench/supabase.token
   ```
   or export `SUPABASE_ACCESS_TOKEN` for one shell. `LHF_SUPABASE_TOKEN_FILE`
   points at a different file. With neither, the scripts send no
   `Authorization` header (the old cloud proxy case) and the first call will
   401. The token is never printed.
3. Node 24 (`node -v`) and, for step 5, the phone paired in Xcode with a
   DEBUG build installed (CLAUDE.md, "Commands").
4. `cd` to the repo root. Dry run first, it sends nothing:
   ```bash
   node backend/scripts/deploy-facts.mjs --dry-run
   ```

## Steps

Run all of 1-4 in order, stopping at the first failure (secrets are checked
before anything is deployed):

```bash
node backend/scripts/deploy-facts.mjs
```

or one at a time with `--step <n>`. Exit codes: 0 good, 1 failure, 2 nothing
extracted yet.

1. **Migration, then `sync`, then `extract-facts`** (`--step 1`). The SQL is
   re-runnable (`if not exists`, `create or replace`, drop-then-create for
   the policy); the script refuses to send it if its scan finds an unguarded
   statement. Migration first, deploy second: `sync` and `extract-facts` both
   fail soft without the tables, but this order never needs that.
2. **Manifest check** (`--step 2`). One throwaway anonymous user enrolled in
   nothing sends `factsSince: 0` (expects 200, `facts: []`, a numeric
   `factsCursor`) and then the old request shape (expects 200 and the usual
   keys). The user is deleted through `delete-account`; if that fails the
   script prints the user id to remove by hand (Authentication > Users).
3. **One real extraction** (`--step 3`). Lists the latest
   `course_fact_extractions` (status, model, cost, counts, reject reasons,
   latency), then checks that every fact's `quote` appears in its document's
   `title + text` (the server's own folding: NFKC, straight quotes and dashes, whitespace and case; PROTOCOL.md → Facts → Quote folding). Exits
   non-zero on a missing quote. With no extraction yet it prints how to
   trigger one and exits 2: a phone that has synced a course (that creates
   the enrollment) POSTs `extract-facts` with `{"courseId": "<canvas id>"}`,
   or just syncs, since `sync` runs it after an upload that changed
   documents. Then re-run `--step 3`. A fact whose document was edited
   afterwards is reported `stale`, not as a failure.
4. **Secrets** (`--step 4`, also runs first in a full run). Requires
   `OPENROUTER_API_KEY`; reports whether `LHF_FACTS_MODEL`,
   `LHF_FACTS_DISABLED` and `FACTS_COURSE_MONTHLY_LIMIT` are set. Defaults
   apply when they are not (Haiku 5.5, 400 extractions per course per month).
5. **On the phone, by hand.** Install the current DEBUG build (check it is
   the newest, CLAUDE.md "Install only the newest build"), foreground the
   app, let a sync finish, then:
   ```bash
   backend/scripts/verify-facts-on-phone.sh <CoreDevice id>
   ```
   It prints `lastStructuredSourcesSyncSummaryV1`, `factsCursorV1` and the
   dismissed and completed counts, each with what a healthy value looks
   like. Then in the app: open a card a fact touched, tap `undo`, and confirm
   nothing was completed or deleted (re-run the script: the completed count
   is unchanged) and that a date you edit by hand still wins over the
   fact's date.

## Kill switches

- **Server, immediate, no migration:** set `LHF_FACTS_DISABLED=1` (or `true`)
  on the project (dashboard, Edge Functions > Secrets, or
  `POST /v1/projects/ynetfjixexksxqrrkwsg/secrets` with
  `[{"name":"LHF_FACTS_DISABLED","value":"1"}]`). This stops new
  extraction only. Facts already stored keep being served by the manifest.
- **Phone, needs a build:** `FeatureFlags.appliedFacts = false`
  (`FeatureFlags.swift:140`) removes the whole facts path: no `factsSince`
  sent, nothing read or applied, `fact-` ledger rows hidden but kept.
  `FeatureFlags.structuredCanvasSources = false` (`:122`) does the same for
  the Canvas structured signals. Phones on a build already shipped keep
  whatever flag they were built with.

## Rollback

No migration rollback is needed or wanted: the tables are additive and only
the new code reads them. Set the secret, ship the flags in the next build.
If a bad fact is already reaching phones and cannot wait for a build, the
remaining option is a data delete (`delete from public.course_facts;`, not a
schema change), which stops the manifest serving them; it needs the owner's
OK and does not remove facts a phone has already stored.

## Afterwards: what to record in CLAUDE.md

In the same commit as the next code change: the date the migration and both
functions went live and the deployed function versions; the step 2 and 3
results (cursor value, how many extractions, cost per extraction, reject
reasons seen); whether `LHF_FACTS_MODEL` / `FACTS_COURSE_MONTHLY_LIMIT` were
set; the kill switches above under Known gaps if the on-phone check was not
done; and the Deno and script test counts. Revoke the token.
