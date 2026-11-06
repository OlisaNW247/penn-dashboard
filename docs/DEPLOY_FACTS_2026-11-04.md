# Deploying extract-facts to production (runbook, 2026-11-04)

Steps 1-4 were run on 2026-11-05 (01:20-01:45 UTC); see "Run record" at the
end. The scripts were written and tested with `fetch` stubbed on 2026-11-04.
A green `--dry-run` proves the plan, not the deploy.

What goes live: migrations `20261104090000_course_facts.sql` (three tables,
one function, one column) and, since 2026-11-05,
`20261105090000_finish_fact_extraction.sql` (one function), the `sync` function (manifest now carries `facts`
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

1. **Migrations, then `sync`, then `extract-facts`** (`--step 1`). It applies
   every file in `FACTS_MIGRATIONS` (`deploy-facts.mjs`), in order:
   `20261104090000_course_facts.sql`, then
   `20261105090000_finish_fact_extraction.sql` (the transactional
   `finish_fact_extraction` function that `extract-facts` now calls; without
   it every finish fails). A new facts migration is added to that list. The
   SQL is re-runnable (`if not exists`, `create or replace`, drop-then-create
   for the policy); the script scans every file first and sends none if any
   scan finds an unguarded statement. Migrations first, deploy second: `sync` and `extract-facts` both
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
   trigger one and exits 2, unless `--trigger <courseId>` is given (optional
   `--trigger-code`, `--trigger-name`; default `COURSE <id>` / `Course <id>`):
   then a throwaway anonymous user enrolls that course with one manifest
   call, `extract-facts` runs for it, the counts print, the user is deleted
   (even if extract-facts fails) and the checks run again. `--dry-run` prints
   that plan and sends nothing. By hand instead: a phone that has synced a course (that creates
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

## Run record (2026-11-05, 01:20-01:45 UTC)

The evening of 2026-11-04 US Eastern (the Mac's clock is UTC-5). Project
`ynetfjixexksxqrrkwsg`, with Olisa's go.

- **Token.** A personal access token from Olisa's account is in
  `~/lhf-bench/supabase.token` (mode 600), read by
  `backend/scripts/deploy-function.mjs`. Two earlier strings failed: one
  corrupted in transit (HTTP 401 "Invalid access token") and a project
  *publishable* key, `sb_publishable_...` (HTTP 401 "JWT could not be
  decoded"). A management token starts with `sbp_` and comes from
  supabase.com/dashboard/account/tokens. A flat 401 means the string is
  wrong. Revoke the token when the deploy work is finished.
- **Step 4, secrets.** `OPENROUTER_API_KEY` present. `LHF_FACTS_MODEL`,
  `LHF_FACTS_DISABLED` and `FACTS_COURSE_MONTHLY_LIMIT` not set, so the
  defaults apply.
- **Step 1.** Migration `20261104090000_course_facts.sql` applied (the
  idempotency scan of its 305 lines passed). `sync` deployed as version 17
  (id `07f14e56-81f9-41ed-8629-d32e5acfc7c5`), `extract-facts` as version 1
  (id `2260e0fa-ae47-4e61-b25d-a9addac468d3`), both ACTIVE.
- **Step 2.** From a throwaway anonymous user: `factsSince: 0` gave 200,
  `facts: []`, `factsCursor` 0; an old-style request gave 200 with the usual
  keys. The user was deleted through `delete-account`.
- **Step 3 stopped at first** ("No extraction exists yet"): extraction is
  scheduled only by a document upload, and no phone had uploaded since the
  deploy. The overseer triggered the first one by hand: a throwaway
  anonymous user enrolled in course 1949400 (PHYS 0151) through a manifest
  call, one `POST` to `extract-facts` with `{"courseId":"1949400"}` gave 200
  in 18989 ms, `{"attempted":10,"done":10,"failed":0,"skippedBudget":0,
  "facts":6,"remaining":17}`; the manifest then returned 6 facts, cursor 6;
  the user was deleted. Re-running step 3: ten `course_fact_extractions`
  rows, all `done`, model `anthropic/claude-haiku-5.5`, cost 0.000403 to
  0.001150 USD each (about 0.0067 USD in all), latency 999 to 6264 ms,
  `rejected_count` 0 everywhere; six `course_facts` rows (seq 1-6) and all six
  quotes found verbatim in their documents. Types: 2 `new_task`, 3 `note`,
  1 `needs_review`.
- **Quality finding.** Two of the six are `new_task` items the owner does not
  want: `new_task high "Final exam"` (quote "Final exam:" only) and
  `new_task high "optional: Midterm 2 point redemption session in DRL A1"`.
  Rule (Marco, 2026-11-04): an announcement becomes a task only with clear
  action words, an assignment that needs to be submitted. The prompt in
  `_shared/facts.ts` was redrafted three times and benched that night; round
  3 was deployed at 02:03 UTC as `extract-facts` v2 and `sync` v18, and step
  3 re-run green (`docs/FACTS_PROMPT_OWNER_RULE_2026-11-05.md`). The `needs_review` fact came from a September
  document ("Quiz 5 ... Sep 19th") read against today's index: a stale
  document can raise review noise.
- **Step 5 (phone), plist half done 02:17 UTC.** The Debug build from
  `034767b` is on Marco's iPhone 17 Pro. At 01:45 UTC `factsCursorV1` was
  still absent because the phone's course-material sync is hourly and had
  last run at 01:15 UTC ("skipped: not stale"). The app was relaunched at
  02:17 UTC, the manifest ran, and `verify-facts-on-phone.sh` read
  `factsCursorV1: 23` with `structuredCompletedItemIDsV1` unchanged at 11.
  Lesson: after a deploy, the first phone needs the hour to pass (or a
  relaunch once it has); there is no force flag. Card check, same day: Marco
  reported the Midterm 2 notes and the Dec 14 final-exam task showing on
  the PHYS 0151 cards. `undo` and "a manual date edit wins" remain untried
  on a device.

### Lesson: step 3 needs a first extraction when no phone has uploaded

Step 3 can only read what exists, and extraction starts from a document
upload. If no phone has synced since the deploy, trigger one by hand with a
one-off: create a throwaway anonymous user, make a manifest call that
carries the course's `{courseID, code, name}` (this enrolls it), `POST`
`extract-facts` with `{"courseId":"<id>"}` as that user, then delete the user
through `delete-account`. `deploy-facts.mjs --step 3 --trigger <courseId>` does exactly this inside
step 3 when it finds no extraction. First run against the live project on
2026-11-05 at 21:15 UTC, after the round-4 deploy (`extract-facts` v5, `sync`
v21): because extractions already existed, the gate skipped the trigger, so
`triggerExtraction(makeContext({trigger}))` was called from a one-off
script; the throwaway user enrolled PHYS 0151, `extract-facts` answered
`attempted 0 … remaining 0`, and the user was deleted. Nothing was pending
because the course's 44 never-extracted live documents are `assignment`
rows, which `FACT_ELIGIBLE_KINDS` excludes. Lesson: "unextracted" in SQL is
not "pending"; only eligible kinds count, and the trigger gate should
probably be "nothing pending" rather than "no extraction ever".
