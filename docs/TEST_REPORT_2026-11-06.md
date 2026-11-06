# Test report, 2026-11-06: `v10` at `0f30ae0` (code `8d2dd35`)

A testing pass only; nothing was fixed. Run on Marco's Mac (macOS 26.6.2,
Xcode 26.6, Swift 6.3.3, Deno 2.9.8, Node 24.13.1, Docker/OrbStack) in the
worktree `.claude/worktrees/v9` on `v10` after `git pull --rebase origin v10`
(already up to date at `0f30ae0`). Phone: Marco's iPhone 17 Pro (CoreDevice
`8A287085-9C88-5A87-816B-1A8EF80D67AD`), which reported Smooth 3.4.0 (17)
installed; the App Group copy worked, so it is the developer build from
`8d2dd35` that `docs/V10_BUG_HUNT_2026-11-05.md` → Status records (the store
copy refuses that copy). Marco then said the phone held a different build and
asked for this one back, so the `v10` Debug build was reinstalled at 17:03
UTC (section 3). Start time 16:46 UTC.

## 1. Mac gate

| Check | Expected | Observed | Result |
|---|---|---|---|
| `cd LowHangingFruitKit && swift test --no-parallel` (via `script -q`, alone on the machine, `pgrep` empty first) | 3688 tests / 350 suites, green | `✔ Test run with 3688 tests in 350 suites passed after 83.765 seconds.` exit 0. No hang. | pass |
| GitHub runner, same code | green at `8d2dd35` | `gh api … tests.yml/runs?branch=v10`: `8d2dd35 completed success 2026-11-06T00:07:15Z` | pass |
| `cd backend && deno task test` | 711 | `ok | 711 passed | 0 failed (3s)` exit 0 | pass |
| `cd backend && deno task check` | clean | `deno check supabase/functions/*/index.ts` exit 0, no diagnostics | pass |
| `node --test backend/scripts/` (the form in the brief) | 29 | `Error: Cannot find module '…/backend/scripts'`, 1 test, 1 fail, exit 1. The trailing slash makes Node load the directory as a module. | n/a (wrong invocation) |
| `node --test backend/scripts/*.test.mjs` (the form CLAUDE.md:1220 records) | 29 | `tests 29 / pass 29 / fail 0`, 210 ms | pass |
| `backend/scripts/sql-check.sh` in Docker | all migrations, both idempotency checks, three SQL test files | `migrations: all 16 applied`; `course_facts migration: idempotent`; `finish_fact_extraction migration: idempotent`; `rls.test.sql: all checks passed`; `claim_fact_extraction: all 11 checks passed`; `finish_fact_extraction: all 6 checks passed`; exit 0. Two NOTICEs (`course_documents_collector_check` and policy `course_facts_select_enrolled` "does not exist, skipping") are the `drop … if exists` lines, not failures. | pass |
| `xcodebuild … -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | succeeds | `** BUILD SUCCEEDED **`, exit 0; no `warning:` or `error:` lines in the log | pass |

Noise worth knowing about, not a failure: the Swift run's log holds 140
`CoreData: error` lines from `GradeHistoryStoreHealthTests`
(`LowHangingFruitKit/Tests/LowHangingFruitKitTests/GradeHistoryStoreHealthTests.swift:27`),
every one `Sandbox access to file-write-create denied` for a store under
`NSTemporaryDirectory()`. The suite still passed (it exercises the
store-failed-to-load path), and this shell runs sandboxed, so the denial is
most likely the shell's, not the test's. Re-check in a plain Terminal before
treating it as a finding.

## 2. Phone, read-only (16:46 UTC, before any by-eye step)

| Check | Expected | Observed | Result |
|---|---|---|---|
| `verify-facts-on-phone.sh`: `factsCursorV1` | ≥ 23 | `23` | pass |
| `lastStructuredSourcesSyncSummaryV1` | counts only | `rows=0 completions=11 dismissals=0 dueOverrides=14 missing=1` | pass |
| `structuredDismissedItemIDsV1` count | small, stable | `0` | pass |
| `structuredCompletedItemIDsV1` count (baseline for the undo check) | unchanged by undo; the 2026-11-05 record said 11 | `13` | see finding 2 |
| `canvasSessionConfirmedDeadV1` | false | `false` | pass |
| `autoLoginAwaitingDuoV1` | false | `false` | pass |
| `lastSilentRenewalSummaryV1` | a renewal, or nothing bad | `renewed · 2026-11-02 14:05 · foreground` | pass |
| `debugRenewalLogV1`, last entries | no failed attempt since the build went on | Last renewal 2026-11-02T19:05Z: `canvasSessionExpired false -> true` → `credential fill result: submitted` → Duo prompt → `duo push sent` → `duo push approved` → `attempt renewed -> renewed` (28 s end to end). Last line 2026-11-04T13:25:06Z `background | session probe: alive, re-stamped 1 cookies`. Nothing from the `8d2dd35` build yet. | pass |
| `lastCourseKnowledgeSyncSummaryV1` | ok | `2026-11-06 11:43 · skipped: not stale \| last run: 2026-11-06 11:10 · ok · courses 6 · fetched 0 · partial 5 · docs 188 · manifest ok · uploaded 0 · errors 5 · ed notes 0 · ed: matched 2 · read 2 · restored 0 · dropped 4 · connected: CIS 2620, CIS 3990` | pass, but `partial 5 · errors 5` is unexplained (finding 3) |
| `lastAnnouncementSyncSummaryV1` | ok | `2026-11-06 11:43 · nothing new · canvas 20` | pass |
| `lastEdTaskSyncSummaryV1` | ok or skipped | `2026-11-06 11:43 · skipped: nothing eligible · ed documents 45 \| last run: 2026-11-02 13:53 · eligible 4 · finds 0 · errors 1 · processed 1 · first error: http 502 · gave up 1` | pass (the 502 is from 11-02) |
| Crash reports (`--domain-type systemCrashLogs`) dated 2026-11-05/06 | none | none. Six older `Smooth-*.ips` remain, newest 2026-10-26. | pass |

Both the sync summaries and the renewal log predate the `8d2dd35` install
(16:26 UTC per the bug-hunt Status); the build had not run a refresh loop
on its own by 16:46.

## 3. Phone, by eye, with Marco

Marco first answered on a build another thread had put on the phone (Codex;
`grey-exams` worktree build of 11:42 local is the likely one), then asked for
this version back. The `v10` Debug build (`0f30ae0`, 3.4.0 (17), built 12:02
local in `build/DerivedData`) was installed with `devicectl` at 17:03 UTC and
launched; everything below is on that build. Asked one at a time; what Marco
was asked and what he said, in his words where quoted.

| Check | Expected | Asked / observed | Result |
|---|---|---|---|
| Undo on a fact-touched PHYS 0151 card (the Dec 14 "Take the final exam" task or a note card) | the fact's change reverts; nothing completed or deleted; `structuredCompletedItemIDsV1` unchanged | Marco: "Undo worked, nothing lost" (first on the other build, 16:50 UTC; the plist read 13 → 13 at 16:57 UTC, overrides empty). On the `v10` build the re-check was asked but not answered. | pass on the other build; not re-confirmed on `v10` |
| A hand-edited date on a fact-moved card wins after a refresh | edited date survives | Cannot run: the server holds no `reschedule` fact for any course (finding 4), so no card is fact-moved. Marco was asked whether any card reads moved/cancelled; no answer. | not run |
| A cancelled item leaves todo and appears in all's `cancelled` section | out of todo, under "cancelled" in all | Cannot run: no `cancel` fact exists (finding 4). | not run |
| A Canvas-completed item swiped back to active stays active after a refresh | item goes active and stays after refresh; `structuredCompletionOverridesV1` gains its id | Marco, in prev, on a Canvas-completed item: "it gets stuck when you swipe it back"; then "Card hangs mid-swipe"; a second swipe freed it; afterwards "Still in prev". Plist at 17:26 and 17:30 UTC: `structuredCompletionOverridesV1` empty, completed count 13, no crash report. | **fail** (finding 6) |
| Tree, 4 questions (`HANDOFF_V10_MARCO_2026-11-05.md` step 4) | answers recorded verbatim with chips | Asked twice; Marco marked the questions done but no answer text reached this session. Nothing to record. | not recorded |
| Forced re-login (`-LHFSessionDiagnostics`, then `-LHFAgeCanvasSession --console`) | password fills, Duo handled, no wrong "update password" row | Marco: "Not now". Not run. | not run |

## 4. Backend, read-only (Management API, project `ynetfjixexksxqrrkwsg`)

| Check | Expected | Observed | Result |
|---|---|---|---|
| Latest `course_fact_extractions` rows | recent, `done` | 27 rows, all `course_id = 1949400` (PHYS 0151), all created 2026-11-05 02:07:04 to 02:08:03 UTC, all `anthropic/claude-haiku-5.5`, `attempts 1`. Newest (id 37) `page:1949400:static-electricity`, `fact_count 0`. Nothing newer than 02:08 UTC on 11-05. | pass |
| Any status other than `done` | none | `select status, count(*) … group by status` → `done 27` | pass |
| `finish_fact_extraction` exists in production | brief asks; bug-hunt item 18 says not yet applied | `select proname from pg_proc where proname='finish_fact_extraction'` → `[]` (absent) | fail, known (finding 1) |
| `course_facts` | 17 facts, cursor 23 | `course_id 1949400: facts 17, max_seq 23` (matches the phone's cursor) | pass |
| Deployed `extract-facts` version | v5 (round 4) | `extract-facts v5 ACTIVE`, updated 2026-11-05 23:26 UTC | pass |
| Deployed `sync` version | v21 (round 4) | `sync v21 ACTIVE`, updated 2026-11-05 23:26 UTC | pass |
| Other functions (for the record) | | `ask v15`, `ask-canary v11`, `delete-account v9`, `extract-announcement v10`, `extract-profile v11`, `discover-websites v8`, `map-categories v6`, `pair v4`, `device-sync v4`, all ACTIVE | |

## Findings

1. **`finish_fact_extraction` is not in production.** `pg_proc` has no such
   function, while `extract-facts v5` is deployed. Bug-hunt item 18 says the
   migration (`backend/supabase/migrations/20261105090000_finish_fact_extraction.sql`)
   must be applied before the *next* `extract-facts` deploy. The RPC call
   (`backend/supabase/functions/_shared/factsExtraction.ts:639`) entered the
   source in `8d2dd35` (2026-11-06 00:07 UTC), after the v5 deploy (23:26 UTC
   on 11-05), so the v5 in production does not call it and extraction is not
   broken today; deploying `extract-facts` from current source before the
   migration would break every extraction at the finish step. Nothing has
   extracted since 2026-11-05 02:08 UTC, so the live path has not been
   exercised either way.
2. **`structuredCompletedItemIDsV1` reads 13 while the summary says
   `completions=11` and the 2026-11-05 record said 11.** The set is
   cumulative and an id retires only after a complete run covering its
   course (`AppState+StructuredSources.swift:256`), and `missing=1` says one
   course was not fully read, so 13 ≥ 11 is consistent with the design and
   with Marco having ticked two items in Canvas since. Not a failure; the
   number to compare against after the undo check is 13.
3. **Course-knowledge sync reports `partial 5 · errors 5` on 6 courses**
   every run (last run 11:10 UTC). The summary does not say which endpoint
   failed. Not new to this build (the summary predates it), but nobody has
   explained it; the collector's per-course error is the place to look
   (`CourseKnowledgeCollector`).
4. **Only `note`, `new_task` and `needs_review` facts exist for PHYS 0151**
   (seqs 7–23; no `cancel` or `reschedule`). So two of the by-eye checks in
   section 3 have no real card to run against on this phone: "a hand-edited
   date on a fact-moved card wins" and "a cancelled item leaves todo and
   appears in all's cancelled section". The code paths are
   `FactApplication.swift:276` and `:309` and `DashboardViewModel.swift:478`;
   they are covered by unit tests only, not by a device.
6. **Swiping a Canvas-completed item back to active in prev hangs the card
   mid-swipe and never un-ticks it** (device, `v10` build, 17:2x UTC). The
   mechanism reads straight off the code: `DoneView`'s row latches
   `didUndo = true` and then ignores every further drag
   (`LowHangingFruitKit/Sources/LowHangingFruitUI/DoneView.swift:165` and
   `:189-190`), so once `undo()` runs the card is frozen at its current
   `dragX` unless the row leaves the list. It leaves the list only if the
   item actually becomes active, and for this item it did not:
   `markActive` (`AppState.swift:9146`) clears the student's own tick and
   records a structured override, but
   `overrideStructuredCompletionIfItWasTheOnlyReason`
   (`AppState+StructuredSources.swift:122`) withdraws the override whenever
   `isCompleted` still says true for another reason (`assignment.submitted`,
   `submittedCanvasAssignmentIDs`, a resolved Canvas id, or the
   nothing-to-submit auto-file; `AppState.swift:9234-9256`). So for a
   Canvas-*submitted* item the swipe is offered, accepted, and then has no
   effect, and the row is left hung. The plist agrees: the override set
   stayed empty. Bug-hunt item 2 covered the planner-tick case only. Two
   separate defects for the fixing session: the latch without a reset, and
   a swipe offered on an item the rules will not let go active (either
   refuse the swipe up front, or let a submitted item be overridden too).
7. **The brief's `node --test backend/scripts/` form fails** (module-not-found
   on the directory); the documented form `node --test backend/scripts/*.test.mjs`
   passes 29. Fix the brief, not the repo.

## Not run, and why

- **Forced re-login**: Marco declined for today. The last real renewal in
  `debugRenewalLogV1` (2026-11-02, 28 s, password filled, Duo push approved)
  is from a pre-`8d2dd35` build, so the sign-in changes (bug-hunt items
  11-17) remain unverified against Penn's identity provider, as the bug-hunt
  Status already says.
- **Fact-moved and fact-cancelled card checks**: no such facts exist on the
  server for PHYS 0151 (section 4), so there is no card to test. They need a
  course whose documents produce a `reschedule` or `cancel` fact, or a
  seeded fact.
- **The four tree questions**: asked; the answers were not captured (see
  section 3). Still owed to CLAUDE.md → Known gaps and
  `docs/TREE_IMPROVEMENT_PLAN.md` → Status.
- **Undo on the `v10` build itself**: passed on the other thread's build only.
- **Retrieval bench and labels** (hand-off steps 5 and 6): outside this brief.
