# Smooth roadmap

The plan: what blocks the next release, what's next, and what was tried and
set aside. `CLAUDE.md` is the engineering reference (what the app does, how
the code works, the traps it has hit). **Every session reads both at the
start and updates both before it ends** (`CLAUDE.md` → "Start here" has the
table of what goes where). When an item lands, move it to **Done recently**
with its date and commit, rather than deleting it.

Last updated 2026-11-09 on `v12` (degree progress built blind; the Now entry). Before that, 2026-11-05 on `v10` (composed-day Phases 1-3 built; the
backend half went live 2026-11-05 01:20-01:45 UTC, the evening of 2026-11-04
US Eastern). Before that, 2026-10-28 on `release/3.4.0` (the 3.4.0 release,
renamed from 3.3.1 that afternoon when PR #16 was folded in). Before
that, 2026-10-24 on `v8` (the tree research plan). Before that,
2026-10-22, on `v8` (the Chrome extension). Before that,
2026-10-20, on `v8-merge-loud-alert` (Olisa's `v8` merged
with Marco's `v8-loud-alert-actions`; not compiled). Marco's
`fix/submission-status` (last updated 2026-10-18, off `v8-announcements`
at `75dc7aa`) is merged in on `v8-merge-marco` (2026-10-23); his entries
below keep their own dates and describe `v8-announcements`' state, not
today's.
The rest of Marco's branches the plan of 2026-10-23
(`docs/MERGE_PLAN_MARCO_2026-10-23.md`) names are merged there too, in the
same order; none of it is compiled yet, and the launch refresh and the
course-sync salvage are separate briefs, not merges.

Live on the App Store: **3.3.0 (16)**, since 2026-10-27 22:37 UTC by the
public iTunes lookup; it still has the launch crash. The next release is
**3.4.0 (17)**, the two crash fixes plus the hardening round and the
onboarding work of PR #16, from `release/3.4.0` (`docs/RELEASE_3.3.1_PLAN.md`,
which also records the rename; 3.3.1 was stamped but never uploaded). Marco's
launch-prep work (2026-10-09/10, built on `v8-launch-prep`) was merged into
`v8` on 2026-10-10 through pull request 9, at his instruction, so it now
rides in whatever is built from `v8` next. Most of it has not been on a phone:
the first item under Now is the check that should happen before a build
from `v8` goes to TestFlight.
Marco's `fix/canvas-signin-bulletproof` (last updated 2026-10-08, on `V7`,
when 3.0.0 (build 11) had been live since 2026-09-28 and the next release
was 3.0.1 with the sign-in fixes at the top of Now) is merged in on
`v8-merge-marco` (2026-10-23); his Now and Done entries keep their own
dates.

---

## Now: before the next release

These block shipping, or would make shipping risky. The launch-prep
work of 2026-10-09/10 is summarised, with the order to take these in,
in `docs/LAUNCH_PREP_HANDOFF.md`.

- **v12 degree progress: compile, capture, then a phone** (Olisa's
  decision 2026-11-09: use the Path@Penn login; build progress and what-if,
  no course recommendations; "make this extremely smooth"). Built blind the
  same day on `v12` (`docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md` is the
  contract). In order: (1) the `tests` workflow on `v12` goes green (the
  runner is the compiler); (2) Marco's capture on his Mac and phone, keys
  and hosts only, never a token: does `/worksheets/` on the Degree Works
  host reach the dashboard through WebLogin without Duo, what does
  `/api/students/myself` answer, which audit call the dashboard makes, and
  the key shape of one audit response (`DebugDegreeLog` on a DEBUG build
  prints it); fix `DegreeWorksEndpoints` and the decoder from that; (3) a
  DEBUG build on a phone: the ring and blocks for his own program, one
  what-if, disconnect clears; (4) the privacy label and `REVIEW_NOTES.md`
  before any upload. Not for 3.4.1.
- **Facts deploy: re-run 2026-11-06 18:56 UTC from `bd9d20c` (`finish_fact_extraction` applied, `sync` v22, `extract-facts` v6; `docs/DEPLOY_FACTS_2026-11-04.md` → Run 3); first done 2026-11-05 (01:20-01:45 UTC)**
  (`docs/DEPLOY_FACTS_2026-11-04.md` is the runbook and now ends with the run
  record; `backend/scripts/deploy-facts.mjs` runs it). Done, with Olisa's go
  and a token from his account in `~/lhf-bench/supabase.token`:
  1. Token saved (after two failed strings, see CLAUDE.md -> Traps).
  2. `sql-check.sh` passed 2026-11-04; the migration
     `20261104090000_course_facts.sql` applied live (idempotent scan
     passed), `sync` deployed as version 17, `extract-facts` as version 1.
  3. A manifest from a throwaway anonymous user answered 200 in both
     shapes (`factsSince: 0` gave `facts: []`, cursor 0). The first
     extraction was triggered by hand for PHYS 0151 (course 1949400): ten
     documents, all `done`, none rejected, about $0.0067, six facts, all six
     quotes found verbatim. Throwaway users were deleted through
     `delete-account`.

  Remaining:
  4. Secrets were checked: `OPENROUTER_API_KEY` present;
     `LHF_FACTS_MODEL`, `LHF_FACTS_DISABLED`, `FACTS_COURSE_MONTHLY_LIMIT`
     unset, so the defaults apply (Haiku 5.5). Set `LHF_FACTS_MODEL` only if
     it should differ; `LHF_FACTS_DISABLED=1` is the off switch.
  5. **Tighten the extraction prompt, then redeploy `extract-facts`.** Two of
     the six real facts are `new_task` items the owner does not want ("Final
     exam", supported only by the quote "Final exam:", and "optional:
     Midterm 2 point redemption session in DRL A1"). Marco's rule
     (2026-11-04): an announcement becomes a task only when it has clear
     action words, an assignment that needs to be submitted. The prompt in
     `_shared/facts.ts` was redrafted three times and benched; Marco ruled
     a due date counts as action words, and round 3 went live 2026-11-05
     02:03 UTC (`extract-facts` v2, `sync` v18; 0 false tasks in two runs,
     recall 64%/57%): `docs/FACTS_PROMPT_OWNER_RULE_2026-11-05.md`. PHYS
     0151 was cleared and re-extracted under it (17 facts, no false tasks).
     The `needs_review` noise from a September document ("Quiz 5 ... Sep
     19th") read against today's index was round 4 (a document-age rule
     plus `due_in_past` / `stale_document` guards), live since 2026-11-05
     21:13 UTC as `extract-facts` v5 and `sync` v21 with Marco's go; its
     first live exercise waits for a new post (the course's unextracted
     rows are all assignment descriptions, which extraction skips).
     **Next deploy must apply migration `20261105090000_finish_fact_extraction.sql`
     first** (`deploy-facts.mjs --step 1` now does both migrations, then
     both functions); the code on `v10` calls that function on every
     finish.
  6. Phone: `bash backend/scripts/verify-facts-on-phone.sh <CoreDevice id>`
     after a sync, then one card a fact touched: `undo` works, nothing
     completed or deleted, a manual date edit still wins. The plist half is
     done: at 02:17 UTC on 2026-11-05 `factsCursorV1` read 23 (all 17 PHYS
     0151 facts on the phone) and the Canvas completion count stayed at 11.
     Card half, 2026-11-05: Marco looked and reported that the Midterm 2
     notes and the Dec 14 final-exam task both show on the PHYS 0151
     cards. Today's `v10` (`08b2e77`, tree reads facts) went on the phone
     at 20:15 UTC: cursor 23, Canvas completions 12, no crash. `undo`,
     "a manual date edit wins" and the tree questions are still
     unexercised on a device. Phase 1's plist read ran 2026-11-04 (11
     completions, 14 section dates, 1 missing).
  7. Record the result in `CLAUDE.md` and `docs/PRIVACY.md` in the same
     commit. The token stays in `~/lhf-bench/supabase.token` for the
     follow-up deploys (tightened prompt, `ask` model move); Olisa revokes
     it afterwards.
  Also open: the phone's course-material sync reported `manifest failed ·
  uploaded 0 · errors 7` on 2026-11-03, which would starve extraction.
- **Reminders for work already turned in, and a Sweeper that earns its
  ring** (Marco, 2026-11-04: reminded of an assignment he had submitted
  fifteen minutes earlier; agreed to the plan the same day). Reminders
  are local notifications scheduled days ahead and only a replan after a
  Canvas grades fetch unsets one; that fetch runs at most every 15
  minutes and only in the foreground, so a submission inside about 20
  minutes of a reminder, or with the app closed, cannot stop it.
  `docs/REMINDER_SUBMISSION_FIX_SESSION_PROMPT.md` is the brief, four
  parts that ship alone: cancel at observation, a submissions-only poll
  every minute inside the last hour, the background wake proven on a
  phone with a throttle bypass, and the Sweeper armed only inside the
  last hour from a confirmed-unsubmitted check, qualified by rules
  (no-submission, zero points, "optional"/"survey" titles) with a seam
  for a pooled model verdict later. Not started.
- **Ship the no-banner sign-in as 3.4.1.** `v9` (2026-11-02): the sign-out
  banner is gone for good, replaced by a quiet status line the clock can
  never trigger; silent re-login on every open; keepalive probes; the
  hidden renewer taps Duo's trust and push buttons; Marco's onboarding
  polish (PR 19) merged in. 3442/329 green. Proven on Marco's phone the
  same day: the aged launch logged `session probe: alive` with nothing on
  screen, twice, and `-LHFForgetDuoTrust -LHFAgeCanvasSession` (hidden
  store emptied of Duo trust and Canvas session) went through PennKey and
  Duo to `renewed` in 27 s with one push approved. Two failed runs that
  day were a stale build from another worktree on the phone and the
  10-minute credential spacing after its submission (CLAUDE.md, Stay
  signed in). Still pending: a background-wake-then-open check, the Mac
  build, a second phone (Olisa), then the version bump and upload.

- **The launch-day crash (2026-10-26): ship 3.2.2 with the A1 fix.** A
  few hundred people installed 3.2.1 (15) on launch day and some of them
  crash a few seconds after every open. The code says why: two Canvas
  assignment groups whose names slug to the same id trap
  `GradeEngine`'s `Dictionary(uniqueKeysWithValues:)` on every grade
  fetch, which the automatic sync runs at launch for everyone.
  `docs/LAUNCH_CRASH_2026-10-26.md` is the record and the plan: the fix
  is on `fix/duplicate-category-ids`, then 3.2.2 (16) with an expedited
  review, then the floor. Not yet proven from a crash report: Xcode's
  Organizer needs Marco's Apple ID signed in before it will list them.
  On 2026-10-27, at Marco's say, A2 (reconnect as a cover over the
  dashboard, never a persisted "not onboarded" flag) and A3 ("expired"
  decided by whether a session cookie is still fresh) landed on the same
  branch, each in its own commit so either can be dropped; both compiled
  and tested, neither run on a phone.
  Later that day, at Marco's say ("continue with everything"), the rest
  of the plan that needs no phone answer or product call landed on the
  same branch in seven reviewed groups (sign-in edges, ledger integrity,
  alarms and the background wake, the Kit hardening and fuzz suite,
  privacy text and ask links, sessions and Keychain, the backend track,
  not deployed). `docs/WHAT_CHANGED_3.2.2.md` explains each commit and
  lists what was skipped and why: A6 and A9 (the renewer, Olisa), B2
  (reinstall policy, Marco), C3, C8, C10 (product calls), D3-D7 (measure
  first), P2 (pairing protocol), BE-D/E/G (Olisa's sync).

- **The Chrome extension: built 2026-10-22, now the owner's to try**
  (`docs/CHROME_EXTENSION.md` is the design record and its Status list).
  Collector, encrypted phone sync with QR pairing, Canvas Files, Penn
  only, unpacked. As of 2026-10-23 the backend half is all live and the
  phone half is compiled and on Olisa's iPhone; what is left needs his
  laptop. Done:
  1. ~~`swift test --no-parallel`~~ **2606 / 237 green on the first run
     at `ad4f920`** (2026-10-23, Olisa's Mac), the extension's Swift and
     the announcement phases compiled together for the first time.
  2. ~~Build to the phone~~ **The `ad4f920` build is on Olisa's iPhone**
     (2026-10-23, 18:09 UTC sync recorded); the pairing sheet is in it,
     unseen until a laptop shows a code.
  3. ~~Migration and deploys~~ **All live**: `sync` (v12 since the
     announcement work), `pair` v1, `device-sync` v1, `delete-account`
     v6 (2026-10-22), and `extract-profile` v8 and `discover-websites`
     v4 (2026-10-23, with Olisa's go, so the extension's post-upload
     calls act for the paired student). Each smoke-tested live with
     throwaway users, who were deleted.

  Steps 4 to 6 happened on 2026-10-23/24 (read from the live table on
  2026-10-24: one device link, 692 extension-collected documents across
  10 courses, 53 of them `file` rows from one course; the 401 trap in
  CLAUDE.md is what the first run hit). Kept for the record:
  4. Load the extension unpacked (`chrome-extension/README.md`), signed
     in to Canvas and Gradescope: the popup should list real work.
  5. Pair: "pair with phone" in the popup, point the iPhone camera at
     it, "pair". Tick something on the laptop; it should be ticked on
     the phone within a refresh, and the other way round.
  6. Within the hour the collector runs: check `course_documents` for
     `collector = 'extension'` rows and kind `file` through the
     Management API (read-only). If no `file` rows ever appear, the
     download redirect needs a host permission (Known gaps).
- **Check the merge of 2026-10-20 on the phone** (it compiled green,
  2397 / 214, and was installed on Olisa's iPhone that morning; nothing in
  it has been watched running yet). The DEBUG rows under Profile →
  accounts (announcements, ed tasks, course material) say where each sync
  stopped; the Berserk alarm, the exam cards and the megaphone sheet are
  the things to look at. Where the two sides' tests could disagree:
  `AnnouncementFindExpiryTests` against `AnnouncementTaskRulesTests`.
- **Watch the catalog rows flip to `2026C`** after the semester fix was
  finally deployed (2026-10-22, `sync` v10 and `ask` v11, Olisa's go;
  `396e464` had sat undeployed since 2026-10-20 and the tree was giving
  Spring 2027 section times). `select semester, count(*) from
  catalog_courses group by semester` through the Management API; then
  ask "when and where is my CIS 2400 lecture" on the phone and expect
  Tue/Thu 1:45 to 3:14 in AGH 106B.
- **Try the section details on a phone** (deployed 2026-10-20 without the semester fix above): ask
  "where is my CIS 2400 lecture" once the catalog rows have refetched
  (`select count(*) filter (where components::text like '%"room"%') from
  catalog_courses` through the Management API says how many have). Note
  `deploy-function.mjs`'s `--also` only bundles a second directory into
  one upload; each slug is its own deploy.

- **Look at the launch-prep work on a phone** (`v8-launch-prep`). Marco's
  phone has builds up to `b5ed8a1`; everything after is compiled for iOS
  and tested on the Mac only. In order of how much could be wrong:
  1. The megaphone: Canvas announcements reach today (re-read
     `announcement-log.json` off the phone; the first install showed the
     28-day-window bug), Ed rows for an Ed-only class, row layout.
  2. Profile → accounts with no sign-in prose in a Release build. (On a
     DEBUG build the sign-in lines are in plain view under the canvas row
     again since 2026-10-18; the collapsed "sign-in diagnostics" is gone.)
  3. An opened card: "open in canvas" opens without collapsing the card;
     "edit date" survives a force-quit; "delete" / "stop repeating" on
     your own tasks.
  4. A reminder that fires: class as title, "Name. Due in …" as body,
     the renamed class name; the 10-minute option.
  5. ask: a question about a class's Ed post, a follow-up without the
     class name, a tappable source chip.
  6. The widget when caught up ("all clear") and at a due time.
  7. A fresh install in mid-semester: old overdue work withheld (since
     2026-11-06 with no "older hidden" line in prev to bring it back).
- **Ship 3.1.0 (13)** (stamped 2026-10-20; the owner's call that evening:
  straight to App Review, no TestFlight round, the song kept under a
  licence he says he holds). **Build 13 was archived from `1450fdc` and
  uploaded at 19:11 that evening** (tests green, the widget's AlarmKit
  link confirmed weak). Left to do, in App Store Connect by hand
  (`docs/appstore/CHECKLIST.md` → "3.1.0 submission", step 5): create
  version 3.1.0, attach build 13, paste the 3.1.0 What's New and
  the rewritten Description from `LISTING.md`, the 3.1.0 review notes,
  drop any grades screenshot, submit. Raise the `update-manifest` floor
  only once it is downloadable, with Olisa's word. Two decisions the
  memory asked for before a release were not taken and ship as they
  stand: the ask summary carries completion state while
  `docs/PRIVACY.md` says it does not, and the anonymous-post sentence
  (both below).
- **Ring the Berserk alarm on a phone, the rest of it.** Done on Olisa's
  iPhone on 2026-10-20: full screen on the lock screen, the song once,
  "turned in" marked the card done. Still to try, with a real card's
  date edited to about 13 minutes out and the phone locked: the system
  "Stop" (today it opens the assignment in Canvas; decide whether to keep
  that or make Stop only stop, `CLAUDE.md` → Traps, "an alarm's stop is
  any dismissal"); one ring with the app force-quit first; and, once the
  2026-10-20 build is on the phone, the new Live Activity (the Dynamic
  Island card, seen; the lock-screen card, not yet) and the in-app
  takeover screen (seen once; try the three roads in). The `otool -L`
  check on the widget's AlarmKit link passed on the 3.1.0 Release archive
  (2026-10-20: `weak`).
- **Hear the loud alert's buttons on a phone** (`v8-loud-alert-actions`).
  With an item due in about 11 minutes: the three buzzes arrive Time
  Sensitive; "turned in" from the lock screen stops the next buzz and
  the card is done after unlock, also when the app was force-quit first;
  "open in canvas" lands on the assignment (Canvas Student may take the
  link, as it does from the card). Nothing about the alert has been heard
  on a device yet.
- **Submitted work that still reads "not done"** (Marco's PHYS 0151
  prelab, 2026-10-18; `CLAUDE.md` → Traps and Known gaps, "Turned-in
  state"). On the phone, in this order:
  1. Is there a saved Canvas login (Profile → accounts shows "sign in to
     canvas" when there is not)? Without one nothing is ever marked
     turned in. Not yet answered: whether Marco signed in after
     2026-10-10, and whether the prelab went to Canvas or Gradescope.
  2. Is Gradescope still connected? It disconnects itself silently.
  3. Is the ledger on disk ("not saving on this phone"; does a swiped
     task survive a force-quit)? Not yet answered.
  4. With a build of `fix/submission-status`: a module-listed assignment
     beside a similar-titled calendar item shows as two cards when they are
     two assignments; a Gradescope "Graded …"-titled item with no
     submission stays on the dashboard.
- **Decide the submission-status parks** (Marco; Olisa for the sync).
  Items 1 and 2 were decided and merged on 2026-10-23 (`v8-merge-marco`,
  blind): 1 as a rework that leaves the notice drains out of the launch
  pass, 2 as written.
  1. `parked/launch-submission-refresh`: fetch submission state at a
     cold launch. Moves the course-knowledge/Ed sync, a full Gradescope
     scrape and the renewal checks to launch as well.
  2. `parked/gradescope-unverified-submission`: keep "submitted" when a
     Gradescope detail page fails to load. Edits one line of
     `syncGradescope`.
  3. Still open, no branch: Gradescope's silent, permanent disconnect in
     `AutoSyncCoordinator.syncConnectedServices`, and re-planning
     reminders after a background wake (`BackgroundRefresh.run`), so a
     loud alert doesn't fire for work already handed in.
- **Decide the three sync questions** (Marco and Olisa). Items 1 and 2
  were done at the owner's direction on 2026-10-23 (the window fix in
  `9540751`; the half-failed sync and the 403 as a fresh patch,
  `course-sync-salvage`, blind), and item 3's pagination went live in
  `sync` v12; byte batching and the 120-page cap remain open. Marco has
  not been told that the sync was touched:
  1. Pass `until:` where `CourseKnowledgeCollector` fetches
     announcements. One argument. Without it ask has never had an
     announcement (`CLAUDE.md` → the announcements-window trap).
  2. `parked/ask-course-sync-fixes`: the half-failed sync that erases
     documents for a whole class, and the 403 that aborts every course.
     Read its commit message first; a review found one regression and
     listed what the server needs before the page cap can rise.
  3. Server: paginate `selectLiveDocumentsForCourses`, batch uploads by
     bytes, and drop empty-text documents before upload.
- **Decide what the ask summary may carry.** `docs/PRIVACY.md` says the
  summary sent with a question is built without completion state, and
  that completions never leave the phone. The code sends "done" /
  "outstanding" for every feed item, and has since ask got its backend
  (`CLAUDE.md` → Known gaps). Either the document loses its status
  column or the policy, here and wherever it is hosted, says so.
- **Settle the anonymous-post sentence in `docs/PRIVACY.md`.** It
  promises anonymous Ed posts never leave the phone; `EdThreadFilter`
  does not look at `isAnonymous`. Change the keep-rule or the sentence
  (`CLAUDE.md` → Known gaps).
- **The sign-out fix ships inside 3.1.0 (13)** without the TestFlight
  week this item asked for (owner's call, 2026-10-20). What it was:
  3.0.1 (12), `v8`, 2026-10-09, blind;
  `docs/SIGNOUT_INVESTIGATION.md`. 3.0.0 (11) went live about 2026-10-01
  and students with a saved PennKey password were still signed out,
  most likely because every manual reconnect purged Duo's trust. A
  three-slice review of that commit found two blockers in the background
  wake (it never awaited its renewal; expiry tore nothing down) and a
  failed navigation counted as a login landing; the fixes are the second
  blind round of 2026-10-09 and predict 1536/154. Compile on the Mac
  (`swift test --no-parallel` AND the iOS `xcodebuild`, since
  `BackgroundRefresh.swift` is iOS-only), then run
  `docs/SIGNOUT_VERIFICATION.md` on two phones, then TestFlight to three
  affected students for a week, then the store. Raise the
  `update-manifest` floor only after it is downloadable, and only with
  Olisa's word.
- **Verify background refresh on a device.** The crash is fixed on `v8`
  (launch handler made `@Sendable` + `nonisolated`; background renewals
  run with a 20 s budget and can only help, never latch). Xcode's Debug →
  Simulate Background Fetch on a DEBUG build, then read
  `debugRenewalLogV1` and the Profile health line.
- **Make staying signed in bulletproof (3.0.1).** On 2026-10-08 the live
  build was still asking Marco to refresh: sometimes the banner cleared by
  itself, sometimes it stayed. Diagnosed on his phone the same day
  (`CLAUDE.md` → Known gaps, and the analytics-cookie trap). Three pieces,
  each verified on a real phone with `-LHFSessionDiagnostics`,
  `-LHFAgeCanvasSession` and `debugRenewalLogV1` before it counts as done:
  1. **The 24-hour trigger.** Decide "expired" by whether a fresh Canvas
     session cookie is left, so a saved analytics cookie cannot switch the
     rule off. Proven cause; smallest fix.
  2. **Verdicts and the banner.** A silent attempt that never got an
     answer (no network, the 30-second cap away from a login wall, the app
     left mid-attempt) must not be recorded as signed out; it retries on
     the next open. The banner appears only when a person is needed, and
     never while an attempt is running. This changes logic that was copied
     from Olisa's proven build, and bounds how often the saved password
     may be resubmitted, so the plan needs Marco's sign-off first.
  3. **The reconnect pane.** Tapping the banner must not delete Duo's
     remembered device, and the saved password must fill by itself there
     (Marco reports typing it by hand; not yet reproduced).
  Status at 2026-10-23: pieces 2 and 3 were done blind in `v8` on
  2026-10-09 (the sign-out commit and its second round; the Duo-preserving
  purge is `v8`'s too) and have not run on a device. Piece 1 is not done:
  `SessionCookieStore.load` and `isExpired` still decide by any cookie's own
  expiry, so the analytics-cookie trap stands.
- **Raise the `update-manifest` floor to 3.0.1 once it is downloadable.**
  3.0.0 is live but the floor is still 1.2.1. Skip 3.0.0 as a floor: it
  would force everyone onto the build with the sign-in bug.
- **Fix the background-refresh crash, with a foreground-only re-login.**
  Every `BGAppRefreshTask` wake has crashed on entry since 2026-08-24
  (`CLAUDE.md` → the background-refresh trap), so background refresh has
  never run. Fix the handler's isolation (run the launch handler's work on
  the main actor, e.g. a `Task { @MainActor in … }` hop, and complete the
  task on every path), and in the same change let `CanvasSessionRenewer`
  run only while the app is active, so a background wake that finds a
  day-old cookie leaves it for the next open. Both halves together keep
  sign-in exactly as proven while background refresh starts fetching
  deadlines. Verify with a DEBUG build and `debugRenewalLogV1`, plus Xcode's
  Debug → Simulate Background Fetch. (Done blind in `v8` on 2026-10-09,
  the entry just above; this one stays for the plan it records.)
- **Test with real Canvas and Gradescope data.** Every grade, submission and
  syllabus path has only been proven against fixtures. This is the
  highest-value check outstanding.
- **Sign in at a non-Penn school on a device.** Brown, Columbia, Cornell,
  Dartmouth, Harvard, Princeton, Yale and custom addresses exist since
  2026-09-23 and have only been exercised by tests.
- **Open a real pre-existing ledger after upgrading.** The `LedgerSchemaV1`
  migration has never opened an on-disk store from an older build. If it
  fails, the app silently falls back to an empty ledger.
- **Fix the `SessionCookieStoreTests` "calendar-link-only install" flake.**
  It fails most parallel full runs since the session-persistence commits
  (`fac110d`..`99609c0`, 2026-09-24); before them it was about one in ten.
  It passes alone and with `--no-parallel`.
- **Pin down the parallel test hang.** `swift test` sometimes freezes on the
  main thread in `SecItemCopyMatching` (sampled 2026-09-23; hit again
  2026-09-24). `--no-parallel` is the workaround and has never hung.
- **Walk the onboarding per-course setup on a device** with a real Canvas
  session. It's covered by tests but has never been walked.
- **Release mechanics.** Keep preview mode (App Review's only way in; see
  `CLAUDE.md` → Known gaps). Bump the `update-manifest` floor only once the
  build is actually downloadable.

## Next: features

- **Degree progress: pick a degree, see progress, try a what-if** (Olisa's
  ask, 2026-11-09; researched that morning, then **decided and built blind the
  same day on `v12`**: see Now. Olisa chose the Path@Penn-login route the
  report had parked, so the recommendation below is history).
  `docs/DEGREE_PROGRESS_RESEARCH_2026-11-09.md` is the report, its labelled
  source notes are in `docs/research/degree-progress/`, and a phone mockup of
  two concepts was published beside it. The recommendation: build it Penn
  first with no Path@Penn login. Requirement templates come from the public
  `courses.upenn.edu` endpoints Penn Labs' Degree Plan already reads (a
  Degree Works audit XML per program, dummy student, no credentials; read in
  Penn Labs' MIT-licensed source, live behaviour untested from the container),
  pooled like `catalog_courses`; the student's record is courses they mark
  (current classes prefilled from Canvas), kept on-device in its own store
  file, never the ledger; code decides, a model may only extract and explain;
  every screen names Path@Penn as the official audit and never says "on
  track". Phases: 0 settle the unknowns (confirm the endpoints from a Mac,
  ask Penn Labs and ISC about terms, one phone pass on Path@Penn), 1
  progress on-device for three programs behind `FeatureFlags.degreeProgress`
  (about 30 to 40 hours, +80 to +110 Swift tests), 2 pooled templates for
  every program (a migration and a small function, owner's go), 3 the
  what-if planner with prerequisites and offerings, 4 the richer record
  (Canvas past courses, an audit PDF, the tree's `# DEGREE` block with a
  PRIVACY.md change, and Path@Penn reading only with Penn's written
  position). The one finding that would change the plan: Penn or Penn Labs
  saying the public endpoints are not for third-party use. Seven questions
  for the owners are at the end of the report. Every Penn host was blocked
  from the research container; a `penn-dashboard` cloud environment with
  those hosts allowed now exists for the next session.

- **Megaphone: the model sorts posts into todo and prev** (Marco,
  2026-11-07: "prev being either from way before or unapplicable, need
  [the model] to sort based on text"). What ships first is the rule half
  (`AppState.announcementSheetSplit`): a post is todo when a find from it is
  still open, when a live `new_task` / `reschedule` / `cancel` /
  `scope_change` fact from it has no past date, or when it is under 7 days
  old; everything else is prev. The facts are already the model's reading
  of each post, so most of the sort is the model's; recency only covers
  posts it found nothing in. The model half, to replace the recency rule:
  1. `extract-facts` emits one document-level verdict beside the facts:
     `status: "current" | "past" | "fyi"` and `applies_until` (an ISO date
     or null), in the same call, same strict schema (`_shared/facts.ts`),
     so no new model cost beyond a few output tokens. "current" means the
     post still asks the student for something or tells them about a
     coming event; "fyi" is information with nothing to do; "past" is a
     post whose every date has gone by. The document's date and the
     meeting pattern are already in the prompt.
  2. Storage: two nullable columns on `course_fact_extractions`
     (`doc_status text`, `applies_until timestamptz`), written by
     `finish_fact_extraction`; the manifest's `facts` answer gains a
     `documents: [{documentID, status, appliesUntil}]` list for the
     requested courses (PROTOCOL.md → Facts). Nothing personal: course-level,
     like a fact.
  3. Phone: `AppliedFactStore` keeps the verdicts; the split reads
     `status`/`appliesUntil` first and falls back to the rules above only
     for documents without one (older extractions, or the pool's
     `assignment` rows which extraction skips).
  4. Bench: the round-4c corpus gains a `status` label per document (about
     120 judgment calls, Marco's); the gate is "no `past` on a post with a
     future date", measured before deploy as every prompt round has been.
  Needs the usual deploy with a person's go; `sync` is the facts path, not
  the collector, so no change to what Olisa's code collects.
- **A composed day: facts applied to the ledger, not a list built by a
  model** (Marco's idea, 2026-11-03; research only, nothing agreed or
  built). `docs/DAY_PLANNER_RESEARCH_2026-11-03.md` maps what is already
  collected (modules, pages, Planner, announcements, Ed, syllabus: nearly
  everything), finds the gap is reconciliation (no path can say "this
  post cancels that item"), and proposes a per-document `extract-facts`
  pass pooled per course on the server, applied on the phone with
  provenance, precedence and undo. Costs about $2 a month at 200
  students pooled versus $50-1,000 for a nightly per-student re-plan.
  Two findings to act on regardless: `ask`'s model `openai/gpt-4.1-mini`
  is scheduled for shutdown by OpenAI on 2027-01-14, and the JSON
  functions run on `glm-5.3-flash`, the candidate with the weakest
  evidence. Four decisions for Marco and Olisa are in the doc's Part 8.
  **Phase 0 started 2026-11-03 on `phase0/extract-facts-bench`** (off
  `v9`, Marco's go): `backend/supabase/functions/_shared/facts.ts` is the
  `extract-facts` prompt, strict JSON schema and parser (quote-in-text,
  target-in-index and 400-day checks reject a fact in code; 10 Deno
  tests), `backend/bench/extract-facts/` is the bench (OpenRouter runner
  with `json_schema` strict and `require_parameters`, a scorer with the
  Part 7 ship gates, a converter from a phone's `course-knowledge.json`,
  a pull script) and `corpus/synthetic/` holds 36 hand-labelled invented
  documents covering the Addendum B cases so the bench runs before real
  documents exist. Dry run writes all 36 request bodies; no model has
  been called (no OpenRouter key in this shell). Later that day the real
  corpus was pulled off Marco's phone (`pull-from-phone.sh`, 310 KB,
  synced 15:22 Eastern): 85 prose documents over five classes (45 Ed,
  22 Canvas announcements, 9 modules, 6 empty pages, 3 syllabi), all
  labelled by hand that afternoon, 35 expected facts and 55 "nothing
  changes" cases, under `corpus/phone/marco/` (untracked, real course
  text) with a `LABELS-*.md` per class listing about 40 judgment calls
  for Marco. Found on the way and fixed: a Canvas announcement can carry
  its whole fact in the title, so quotes are checked against title plus
  body; Ed `updatedAt` is the last edit, not the post date; the pool's
  index is today's state and must be rewound per file to the state as of
  the post; CIS 2620 has no `assignment` documents in the pool at all
  (its index is reconstructed from its own Ed posts and marked so);
  `devicectl` cannot copy root-level App Group files, so the ledger
  stays on the phone. Zero real cancellations in the set; the wrong-
  cancel gate rests on the synthetic cases until a real one appears.
  Also read off the plist that day, Olisa's area, untouched: the
  course-material sync reports `manifest failed · uploaded 0 · errors 7`
  and the Ed task pass a 502. **Measured the same evening with the
  OpenRouter key, two rounds, five models**
  (`docs/EXTRACT_FACTS_BENCH_2026-11-03.md`): Claude Haiku 5.5 is the
  only model that passes the ship gates on the real documents (90%
  precision, 85% recall, every task and date it emitted correct, $0.0004
  a document); today's extractor `glm-5.3-flash` invented quotes and
  cancellations. Decision: Haiku 5.5 for `extract-facts`. Left: Marco's
  pass over the `LABELS-*.md` calls; moving `ask` off gpt-4.1-mini on
  the canary; Phase 1 and the identity layer can start, Phase 2 needs
  Olisa's go.
  **Built 2026-11-04 on `v10`** (Marco: "make all the decisions"; Phases 1-3
  written, committed on `v10`, backend deployed 2026-11-05, nothing watched on a device; 3596 /
  345 green, Deno 686, `deno task check` clean; the SQL passed in a Docker
  Postgres the same day). *Phase 1*, phone only, no model:
  `CanvasStructuredSourcesClient`/`Reconciler` read Planner items, missing
  submissions, modules, `all_dates`, discussion topics and dated pages;
  `AppState+StructuredSources.swift` applies them (rows upserted; completions,
  dismissals and section dates as additive sets in `UserDefaults.lhf`, never
  as student edits). *Identity layer*: `WorkItemIdentity`/`Alias`/`Matcher`/
  `MergeRecord`. *Phase 2*, server: `extract-facts` and
  `_shared/factsExtraction.ts` on Haiku 5.5, `course_facts` migration,
  manifest `facts`/`factsCursor`, `posted_at` on documents, PROTOCOL.md
  "Facts", PRIVACY.md paragraph. *Phase 3*, phone: `AppliedFactStore` (its
  own SwiftData file), `FactApplication` (pure precedence engine),
  `AppState+AppliedFacts.swift`, card tags `cancelled`/`moved`/`changed`, a
  struck old date, `undo`, and the megaphone's `changed` and `needs a look`
  groups first. Decisions taken by the session: facts in their own store,
  never the ledger schema; `cancel` hides from todo with undo; a
  medium-confidence cancel goes to `needs a look` and is never applied; each
  half behind a compile-time flag (`FeatureFlags.structuredCanvasSources`,
  `.appliedFacts`); "Status: submitted" stripped from pooled assignment text
  (a privacy fix in Olisa's collector, landed and flagged). A live probe with
  Marco's key showed Haiku 5.5 accepting the exact production body. Left:
  deploy (Now, with Olisa's go); phone verification; the per-item module
  documents (Addendum C item 8) and the build-map first read (Addendum A);
  Phase 4 (the day view) and Phase 5 (feedback); Marco's `LABELS-*.md` pass;
  moving `ask` off `gpt-4.1-mini` (shutdown 2027-01-14), now a deploy/secret
  operation on the canary, not a code change. Known engine limits are under
  CLAUDE.md → Known gaps.
- **McGraw Hill (Connect, ALEKS)** (owner's request, 2026-11-02; research
  only, nothing built). `reports/McGraw Hill access for Smooth.md` is the
  write-up, with its notes in `research_notes/McGraw Hill access for
  Smooth/`. The verdict is in two halves:
  - Connect work an instructor deploys into Canvas probably already
    reaches the dashboard as ordinary Canvas cards. The risk is the done
    state: if Canvas never records `submitted_at` for a finished Connect
    set, the card stays overdue and the Sweeper rings for finished work.
  - Reading McGraw Hill directly, by an LTI launch like Ed's or a login
    like Gradescope's, runs into McGraw Hill's terms (robots and scrapers
    barred without written permission) and Apple 5.2.2. It waits on
    written permission or an explicit owners' decision.

  First step, no code: call
  `GET /api/v1/courses/:id/assignments?include[]=submission` on one real
  Penn Connect section, before starting, after finishing and after the
  due date. Also read that section's ICS event. McGraw Hill's own site
  was blocked from the research container, so its claims rest on search
  summaries.
  **2026-11-02, later:** Olisa asked for the direct reader to be built
  anyway. `docs/MCGRAW_HILL_READER_SESSION_PROMPT.md` is the brief for
  that session. It covers a remote kill switch in the update manifest
  (off unless turned on), on-device only, recon by Marco before any
  client, and compiling through the GitHub runner on a draft PR.

- **Improve the tree (ask)** (owner's request, 2026-10-24; the research
  is done, nothing implemented). `docs/TREE_IMPROVEMENT_PLAN.md` has the
  30-question set with verdicts (19 answerable today, 6 not in the pool,
  4 missed by retrieval, 1 answered badly), the live numbers (44 real
  questions ever, first word 2.4 s median, the hedge never fired) and a
  ranked list. Its three first steps, all phone-side: render dates in the
  student's zone (every "due tomorrow" after 8 pm Eastern is wrong today),
  chunk the `discover-websites` call by three (a student in four CIS
  classes never gets a website crawl; two of Olisa's classes have nothing
  in the pool but Ed), and keep table line breaks in excerpts plus a
  citation contract that names the title. Waiting on Olisa: a
  `course-knowledge.json` read off his phone for the retrieval bench, a
  canary go, and two decisions (concept questions; the completion-state
  sentence). `docs/TREE_RESEARCH_SESSION_PROMPT.md` was the brief.
  **Status 2026-10-25 (owner's go, "put your plan into action"):** items
  1 to 4 are written and not compiled: the zone-aware context document
  and the local-date line, the discovery call chunked by three, newlines
  and table cells kept in excerpts, the citation contract (title in
  `detail`, `ed` kind, newest-post rule) in `prompt.ts` with Deno
  468/0, a `citations` probe set in the phone's real excerpt format, and
  a `RetrievalBenchTests` that prints the exact excerpt block for the 30
  questions from a `course-knowledge.json` read off a phone. Predicted
  Swift delta +17 tests, +2 suites. The `ask-canary` deploy was refused
  by the session's permission classifier, so the new prompt is not on the
  canary yet; a 6-run baseline against the old prompt showed the model
  already preferring the newer post (2/2) and writing a linkable title in
  about half the `<sources>` details. Next: Olisa's compile, the canary
  deploy at his hand, then the three probe commands in the plan.
  **Status 2026-11-02 (Olisa's go): live.** `ask-canary` v8 from `v8`
  `dfb9d7f`, 20-run `citations` probe `cite-def`: 20/20 answered, a known
  title in 20/20 `<sources>` details (baseline 3/6), `ed` kind 15/20,
  Meyerson in 7/7 midterm answers (baseline 2/2), first word p50 3.3 s.
  Production `ask` is **v13** from the same tree, carrying the citation
  contract and the 2026-11-02 recording sentences (`history`, the
  schedule-is-not-a-cancellation rule). On Marco's phone the same day
  (`v8` `d434db8` Debug): the class-meeting question now answers from the
  Ed post; the "you should've said that" follow-up was not asked, so the
  history half is unproven (CLAUDE.md → Known gaps).
  **Status 2026-11-05:** the probe's new `history` set, run from the GitHub
  runner (`ask-probe` workflow), answered 10/10 and corrected the earlier
  turn every time, so `history` reaches the server and the model uses it;
  `meeting` 10/10 from the Ed post. Both still owed on a phone. The same
  day the tree's work list began reflecting applied facts and section
  dates, and steps 1-2 of the temporal research landed, all blind, all
  compiled green on the runner (3631 / 348).

- **Merge Marco's branches into `v8`** (plan written 2026-10-23,
  `docs/MERGE_PLAN_MARCO_2026-10-23.md`, owner's request). Seven live
  branches, three of them needing Olisa's decision (automatic PennKey
  capture reverses a recorded privacy rule; the launch refresh would post
  notifications at launch on `v8`; the parked sync fixes conflict with the
  2026-10-23 announcement window and must be salvaged as fresh patches).
  Low-risk first: `fix/submission-status`, `fix/canvas-signin-bulletproof`,
  the launch-prep handoff doc. **Done the same evening on `v8-merge-marco`,
  blind:** all seven merges (the owner chose automatic PennKey saving as
  Marco wrote it), plus three fresh patches (the launch pass without the
  notification drains, the partial-course sync semantics with 403 per
  course, the Ed tabs restore). Left: Olisa's compile (predicted 2736),
  the phone, `sync` from `v8` for the exam dates (v14 or later; v13 is the NUL guard alone; needs a go), and telling Marco.
- **An AI keep-check for the megaphone** (asked for by Marco on
  2026-10-23; **built that evening on `fix/megaphone-every-class`, with
  the phone side compiled and tested and the backend tested but NOT
  deployed**; Olisa, who took over announcements and Ed on 2026-10-18,
  has not reviewed it). `docs/ED_AND_MEGAPHONE_PLAN.md` is the full write-up
  and the ship order. The standing list rule is "the past 7 days plus
  each class's latest post".
  Marco: which posts matter "will kinda vary", so on top of that rule an
  AI should judge which announcements to keep. The proposed shape, built
  so it costs no extra model calls and sends nothing new off the phone:
  - `extract-announcement` already reads every post that might carry a
    task, once. Its response gains one optional field per post,
    `relevance: { kind, until? }`: `event` (an exam, a session, a room
    change; matters until `until`), `task` (matters while its found tasks
    are open), `standing` (a policy, a formula sheet, an OH schedule;
    matters all term), `news` (grades are out, slides posted; a few days).
    `backend/PROTOCOL.md` changes with it, and deploying needs a person's go.
  - The phone stores it on the post's log record (one judgment per post,
    never re-asked) and decides on the device. The list shows the
    standing set, plus older posts whose relevance is still live, minus
    posts whose relevance has run out or whose found tasks are all
    finished. Completion and turned-in state never leave the phone
    (`docs/PRIVACY.md`), which is why that last part cannot be the
    server's call.
  - Posts the on-device informational gate never sends get `news`
    locally. Non-Penn installs, or when over quota or offline, use the
    standing rule alone. The Ed task pass uses the same extractor, so Ed
    posts get the same field.
  - Open: whether a `standing` post older than the class's latest still
    shows (proposed: yes, below the dated ones), and whether the student
    can hide a post by hand.

- **Announcements for ask, from Canvas and Ed** (plan written 2026-10-23,
  `docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md`, owner's request). Canvas
  announcements have never reached ask (the collector's dead window); Ed
  reaches it with holes. Four phases: fix the collector's window and
  header; split the backend's gone rule into census and window kinds,
  paginate the manifest read (PostgREST `max_rows` is 1000, confirmed),
  reject a bad document alone, add `posted_at`; page the Ed read and
  keep the anonymous promise; later, one Canvas path on the phone.
  **Status 2026-10-23 evening:** Phases 1 to 3 are done, compiled
  (2606/237), `sync` v12 live, and the phone's first sync on the build
  uploaded 63 of this term's Canvas announcements and 36 Ed posts. Left:
  the tree's answer on a phone (asked for), the `posted_at` migration
  (Phase 2 step 5, needs a go) and Phase 4 (owners' decision). The review
  finding in the Ed coordinator (a class whose `/tabs` lookup fails had its
  stored posts dropped) was fixed blind the same evening
  (`ed-tabs-restore`, in the Marco merge) and compiled in PR #13's merge of
  that tree. The bigger one (the course-material collector deleted every
  re-synced class's Ed posts and saved before Ed restored them) is fixed in
  PR #13 (`fix/ed-posts-durable`); see CLAUDE.md → the "vanish" trap. Two
  shapes left alone: a class whose Canvas has an Ed tab but whose Ed course
  the matcher refuses is still dropped, and the collector drops `.file` and
  `.website` documents the same way (the server's downloads re-supply those).
- **A Smooth Chrome extension.** The owner named it on 2026-10-22 and
  nothing is designed yet. `docs/CHROME_EXTENSION_SESSION_PROMPT.md` is
  the brief for the session that starts it: the standing rules, what the
  browser has that the phone does not (the student's live Canvas,
  Gradescope and Ed sessions), the privacy line a laptop copy of the work
  list would cross, and the five scope questions to put to the owner
  before the first brief.
- **Hands-free voice mode for ask.** Today's mic (2026-10-22) dictates
  into the composer and the student taps send. The owner's full ask was a
  "voice mode": a spoken answer (`AVSpeechSynthesizer`, reading the
  streamed text as it lands), and perhaps listen → send on silence → speak
  → listen again on its own screen. Decided against auto-send in the first
  version so a misheard word never sends a question. Build it on
  `VoiceDictationController`; keep on-device recognition only, and keep
  `docs/PRIVACY.md`'s "audio never leaves the phone" true.
Roughly in priority order.

- **"Berserk mode" is the loud 10-minute alert.** Marco, 2026-10-19:
  "basically the 10-minute alert", for the moment right before an
  assignment goes unsubmitted, when the app "goes berserk and forces you to
  notice and either fix it or do something about it"; possibly not needed
  as a separate feature. Nothing separate is built. What the loud alert
  lacks against that description: the notification has no actions (no
  category, no notification delegate anywhere in the app), so it can only
  be noticed, not acted on; and it can fire for work handed in while the
  app was closed (`CLAUDE.md` → Known gaps, "Turned-in state"). Marco
  asked for "turned in" and "open in canvas" buttons on 2026-10-19; they
  are on `v8-loud-alert-actions` (its own worktree off `75dc7aa`,
  pushed 2026-10-19, not merged, not on a phone).
- **Silent renewal follow-ups** (from the 2026-10-09 review, none
  blocking): don't count a landing toward the latch when the six-hour
  credential cooldown suppressed the password; have the live `AppState`
  re-read the renewal summary after a background wake; return a real
  `success` from the background `run()`.
- **Let ask read Canvas Files** (slides, readings, PDFs). Probably the
  biggest remaining reason ask misses what is "in the class files". It
  is a decision before it is code: pooling instructors' files on the
  server changes `docs/PRIVACY.md` and the hosted policy; an on-device
  only store does not, but helps nobody's classmates.
- **Let a follow-up question carry the conversation.** Done blind on
  2026-11-02 at the owner's word (`ConversationHistory`, the last three
  exchanges sent as `history`, `docs/PRIVACY.md` updated); with it, a
  `.meeting` recency kind so "do I have class today" sees the newest
  posts. Compiled green on the GitHub runner the same day (3414/329);
  on Marco's phone 2026-11-02: the class-meeting question passes (answers
  from the Ed post); the "you should've said that" follow-up was not
  asked. Next: check `history` is sent (DEBUG request body or a canary
  probe with a `history` pair).
- **Give the tree better context to reason with** (research written
  2026-11-02 at Marco's request, `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`).
  His verdict on the first phone build of the tree work: recent posts
  are not put first when the question is about today or recency, and a
  general question should lean on the syllabus. The research maps what
  the model is given today (no time-frame classification, no freshness
  in scoring, the weekly schedule only in `COURSE STRUCTURE`, due-date
  questions left to the model's date arithmetic) and proposes, in order:
  a time-frame resolver on the phone, per-intent freshness in scoring,
  per-intent slot budgets with the schedule and the newest post side by
  side, dated passage labels, a computed verdict line before the
  question, then one server prompt pass. A frozen regression set in
  `swift test` measures it. Steps 1 and 2 (the resolver, `AskTimeFrame`,
  and per-intent freshness in `CourseSearch`) and the frozen regression
  set (`AskTimeFrameRegressionTests`) were written blind on 2026-11-05,
  not compiled; steps 3 to 6 need a decision on how the weekly schedule
  reaches the phone.
- **Make ask cite titles, so more source chips link.** The server prompt
  asks for "a few words locating the fact"; a chip only links when the
  model happens to write a document's title. One prompt line, behind an
  `ask-canary` run and a person's go. While there, teach the prompt the
  "ed discussion" source kind.
- **A real "rescan" for ask.** Asked for on 2026-10-09 and not built: the
  only way to force a course's material to be re-read is to override
  the sync's freshness rule, which is the sync (Tried and parked).
- **Edit a recurring task.** Since 2026-10-10 a student can delete a
  one-off task and stop a recurring one from its opened card; changing
  a saved recurring task's day, time or class still means stopping it
  and adding it again.
- **Show finished recurring occurrences on prev.** They are recorded in
  the ledger, but `DashboardViewModel.reload` never lists them, so a
  weekly reading ticked off does not count toward "N down this week"
  (`CLAUDE.md` → Known gaps). Needs a decision on what prev shows.
- **From the 2026-10-10 review, small and not done:**
  - tapping a reminder only opens the app; it should open the item;
  - tapping a card in prev un-completes it with no hint and no undo;
  - the dashboard's "today" section is the next 24 hours, so at 10pm
    tomorrow's 8am work sits under "today" (a design call);
  - appearance has no "system" option and defaults to light;
  - a class filter is not cleared when that class is hidden;
  - reminder triggers carry no time zone, so a travelling student's
    reminders shift until the app is next opened;
  - a work item cited by the on-device answerer does not link, because
    the feed stores a calendar URL (reuse `Assignment.sourceLinks`);
  - `canvasAssignmentID`'s UID fallback matches inside
    `event-sub_assignment-<n>`; pinned by a test, not yet anchored,
    because the id is a join key.
- **For the Ed scraper's owner** (2026-10-10 review; none touched):
  keep a class's Ed documents when a run stops on a 401; stop replacing
  the whole Ed set with the newest 100 threads; capture staff answers
  inside student questions; page past 100 threads; read Ed more often
  than the Canvas sync; richer XML-to-text (struck-through dates, tables,
  attachment names).
- **Streaks and per-class counts on prev.** For example, "3 weeks in a row
  with everything done" and "PHYS: 3" under "4 down this week".
- **A "this week" count on the widget.** The lock-screen circle shows
  what's due within 24 hours; a week-level "N left" to match the dashboard's
  todo is the missing piece.
- **Weekly-task templates.** Pick "discussion post" or "problem set" and the
  sheet fills the title; the class comes from the class picker.
- **Grade "what if".** Drag an upcoming score in Grade Watcher and watch the
  final grade move. The category map and predictor already exist.
- **Siri / Shortcuts: "what's due tomorrow?"**, answered by the on-device
  responder so it works offline and at every school.
- **Server features for non-Penn schools.** Pooled course materials, the
  server path of ask, and announcement AI assist are Penn-only because the
  backend keys course material by numeric Canvas course id. Namespacing it
  by Canvas origin unlocks them everywhere.
- **Ed Discussion, phase 2: verify on a device.** Built twice on
  2026-10-18/19 and merged into one pass on 2026-10-20, blind and not
  compiled: the Announcement Watcher reads `ed` announcements and pinned
  posts through `syncEdAnnouncementTasks` (`docs/ED_DISCUSSION.md`). Needs
  a compile, a test run, and a phone with a synced Ed class. The DEBUG
  "ed tasks" row under Profile → accounts says what the last run did.
- **Canvas access tokens**, the day Penn issues an OAuth developer key or
  lifts the student-token restriction. The plumbing is built and gated off
  (`FeatureFlags.canvasAccessTokens`).

## Later: quality and tech debt

- **`AppState` is ~6,000 lines.** Split it along the seams it already has
  (sync, dashboard buckets, sessions, recurring/manual work).
- **Source-grepping tests.** `VisualStructureTests` asserts on the text of
  `SettingsPage.swift`. `CLAUDE.md` already records why a test that greps
  the repo's own source proves little. Replace these with behavioural tests
  or delete them.
- **Refresh `docs/improvement-backlog.md`.** It dates from 2026-08-09, and
  much of it has been done or superseded since. Prune it, or fold what's
  left in here.
- **Delete merged branches.** `v8-features` and `V7-polish` are fully in
  `V7`, and the `claude/*` branches from August are stale.
- **iPad layout.** The app is iPhone-only (`TARGETED_DEVICE_FAMILY` 1). The
  Mac build exists; `v2.75` holds unmerged sidebar/landscape work.

## Tried and parked

Kept so nobody rebuilds them blind.

- **"Connect your own Claude / ChatGPT account" to ask** (researched
  2026-10-21, nothing built; `docs/AI_ACCOUNT_LINKING.md` is the report).
  Olisa asked for a smoother path than pasting an API key. Findings: a
  Claude account link cannot be built at all (Anthropic's legal page bans
  third-party Claude.ai login, routing through Pro/Max credentials, and
  even holding a session token; enforced through 2026); OpenAI's "Sign in
  with ChatGPT" plan usage exists (2026-09-29) but admits only open-source
  or local apps self-serve, Plus/Pro users, and a loopback redirect with no
  iOS path. Ranked: keep developer-pays and move `ask` to a cheaper cached
  model; add iOS 27 Private Cloud Compute (32K context, free under 2M
  downloads in the Small Business Program) as the on-device responder's
  upgrade; file OpenAI's interest form; OpenRouter PKCE sign-in and
  paste-a-key only as opt-in power-user doors, key kept on the phone.
  Re-check the OpenAI and OpenRouter wording live: those pages were read
  through mirrors and search snippets from the container.
- **Course-material sync fixes for ask** (2026-10-09). Written, tested
  (1636/160 on that branch), reviewed, and parked on
  **`parked/ask-course-sync-fixes`** the next day when Marco said not to
  touch the sync. Its commit message is the handover.
- **A "rescan class files" button in ask.** `refreshCourseKnowledge`'s
  `force:` only skips the phone's own gate; the server's 60-minute
  `coursesFresh` still removes the course from the fetch. A button built
  on the unmodified sync would do nothing most of the time.
- **Hiding past-due items from the widget's later timeline entries.**
  Built for an hour on 2026-10-10 and rejected: it also hid work that
  was already overdue, so a student whose only open work is overdue saw
  "all clear". `WidgetTimelinePlanner`'s comment says not to bring it
  back.
- **Deciding the sign-up cutoff inside `sync()`.** The first version
  (85a0c2b) moved the reconcile half of the sync into new functions. It
  worked, and it was the sync. The decision is taken at `init` and in
  `rebuildDashboardItems` instead (01afe8e).
- **"Completed onboarding means an existing install", on every launch.**
  Written and rejected the same day: a new student whose first syncs
  failed, and who relaunched after finishing onboarding, would have been
  read as existing and shown the whole backlog. It holds only on the
  first launch of a build that has the feature.
- **Dice "pick one for me".** A button that picked a random next assignment
  (the soonest in each class, due within two weeks); tapping the die
  rerolled, never repeating the last pick. It worked, but it cost a
  button's worth of room on a full control row. Lives on the
  **`v8-dice-toggle`** branch (`PickAssignmentSheet`,
  `DashboardViewModel.pickCandidates`, with tests).
- **Per-assignment steps.** A "break into steps" checklist inside an opened
  card, with a thin progress bar on the collapsed card. Removed 2026-09-24;
  it's in commit `7b2578a` if revisited. If it comes back, steps must live
  in the ledger (`StoredAssignment`), not `UserDefaults`, because they are
  the student's own work.
- **"all assignments" as a row under todo.** Folded todo and all into one
  page. Once the todo · all · prev switch was one tap, the row was
  redundant.
- **A "todo ▾" menu for the view switch.** It saved width but hid two of
  the three views behind an extra tap.
- **Foreground-only silent re-login, alone.** Considered and declined on
  2026-09-27 in favour of Olisa's exact logic. The same day's crash report
  showed background wakes never run anyway, so Olisa's logic already *is*
  foreground-only in practice; the guard is now part of the background
  crash fix (Now), not a standalone change.
- **Keeping Canvas cookies until the server rejects them.** `fac110d`
  (2026-09-24) dropped the 24-hour rule; it signed Marco out two days
  later and was reverted (`CLAUDE.md` → the 24-hour trap).

## Done recently

- **2026-11-07 (16:39 EST).** 3.4.1 (20) archived from `c3a4feb` and
  uploaded, superseding builds 18 and 19. Marco attaches 20 and submits.
- **2026-11-07 (evening).** The megaphone lists every post the phone keeps
  (no 7-day window, Ed staff posts included); todo is "still applies":
  an open find, a live fact, an event or task judgment not yet over, or
  under 3 days old; prev is the rest. The badge counts unread todo posts
  only; NEW shows only in todo. Marco's "push to appstore": build 20.
- **2026-11-07 (later).** The megaphone sheet is todo · prev over posts
  only, every row the same, split by open finds, live facts and a 7-day
  recency rule (`announcementSheetSplit`); the model's document verdict is
  designed under Next. 3700/351. On Marco's phone; not in build 19.
- **2026-11-07.** 3.4.1 (19) archived from `5bc1a9f` and uploaded at 15:38
  EST, superseding build 18 (which lacked the megaphone redesign and the
  final-exam dedup). The Debug build of the same tree is on Marco's phone.
  Marco attaches 19 and submits.
- **2026-11-06 (night).** The megaphone sheet takes the dashboard's own
  controls (to-do · brief switch, class filter menu and chip), one view at a
  time, flat uniform rows; a fact's new task no longer duplicates an exam the
  watcher already found (titles compared through `FactTitle.short`). Marco's
  phone had shown two Dec 14 final exams.
- **2026-11-06 (evening).** The megaphone sheet is two sections, to-do and
  brief, newest first, with `go to canvas` / `go to ed` under each arrow and
  no undo (Marco, from the phone). The Canvas-app link was confirmed working
  on his phone through the `canvas-courses://` scheme (`LHF-LINK` lines).
- **2026-11-06 (shipped to App Store Connect).** The facts backend
  redeployed from `bd9d20c` with the `finish_fact_extraction` migration
  (`sync` v22, `extract-facts` v6; steps 1-3 green), and **3.4.1 (18)**
  archived and uploaded at 14:00 EST. Marco submits in App Store Connect.
  The 3.4.1 (18) Debug build went onto Marco's phone at 14:06 EST (over
  3.4.0 (17)); the prev swipe-back and the `LHF-LINK` read are his checks.
- **2026-11-06 (the merge for production).** On top of the design pass:
  the prev swipe-back hang from `docs/TEST_REPORT_2026-11-06.md` finding 6
  fixed both ways (the latch resets; a Canvas-submitted item offers no
  swipe), the course-knowledge summary names which fetch fails (`error
  kinds`), and 3.4.1 (18) stamped with its What's New and checklist
  (`docs/appstore/`). The facts deploy (step 1 applies the missing
  `finish_fact_extraction` migration) and the archive wait on Marco's go.
- **2026-11-06 (dashboard design pass, merged into `v10` at Marco's go).**
  Exam cards are grey instead of black. Nothing-to-submit cards say "in
  class" under the due value instead of a caveat line (stripes were tried
  and rejected). "from announcements / ed / syllabus" moved into the opened
  card. Megaphone and profile buttons are squircles; filter and + stay
  round. The "N older hidden · show" line is gone from prev. On Marco's
  phone; 3698/352 green.
- **2026-11-06 (later).** Marco's two asks: a fact-created card shows the
  name of the work when collapsed ("Final exam") and the whole title when
  opened (`FactTitle.short`, display only; a matching prompt change lost two
  real tasks on the bench twice and was parked, round 5 in
  `docs/FACTS_PROMPT_OWNER_RULE_2026-11-05.md`); and the Canvas-app link
  question gets DEBUG `LHF-LINK` lines plus ask's answer links routed
  through the app opener (CLAUDE.md -> Known gaps). Handoff items 4-6
  scoped in `docs/HANDOFF_V10_2026-11-04.md`: item 4 is Olisa's collector
  shape, Phase 4 needs Marco's design answers, item 6 is a held deploy.
  3696/352 Swift, Deno 713, iOS simulator build green. Not on a phone.
- **2026-11-06.** The two open bug-hunt code items: the megaphone's changed
  row has `undo` (item 5), and Profile's "save pennkey" row shows after a
  failed Keychain save even with an older password on file (item 17); item
  22 (per-user extraction cap) is a schema proposal for the owners in
  `docs/FACTS_PER_USER_CAP_PROPOSAL_2026-11-06.md`. The on-device model no
  longer runs under `swift test` (a paraphrase flake, CLAUDE.md -> Traps).
  3691/351 Swift, Deno 711, iOS simulator build green. Not on a phone yet.
  The facts deploy (step 1-3, with the `finish_fact_extraction` migration)
  and the 3.4.1 (18) release are held at Marco's word until his parallel
  testing thread is done.
- **2026-11-05 (evening).** Round 4 of the facts prompt (stale posts) live as
  `extract-facts` v5 / `sync` v21 with Marco's go; and the fix pass for
  `docs/V10_BUG_HUNT_2026-11-05.md`: 29 of 33 items fixed on `v10` (facts
  precedence and undo durability, `must_view` completions and their undo,
  per-course facts cursor, withdrawn facts, quiz and page identities, the
  on-device answerer's cancels; the silent re-login's one-submission
  liveness, abort on disconnect, dead-probe flap, credential-less latch,
  Duo-vs-password reading, Keychain save failure; atomic
  `finish_fact_extraction`, the item index around now, offset-less dates,
  reschedule/title validation, the 8 s floor; whole-word policy matching
  and undated-post freshness in the tree; the ask-probe workflow's `eval`
  and the `ask` deploy gate). 3688/350 Swift, Deno 711, Node 29, iOS build
  green. Parked: per-user extraction cap (schema), Olisa's extension items
  29-31 and 33. On Marco's phone since 2026-11-06 16:26 UTC (Debug from
  `8d2dd35`): launched clean, syncs ran, flags clear, and Marco reported
  nothing wrong after using it the same day; **the new migration is not
  applied in production.**
- **2026-11-05 (01:20-01:45 UTC).** Facts backend live: migration
  `20261104090000_course_facts.sql`, `sync` v17, `extract-facts` v1; first
  extraction by hand gave six facts for $0.0067, two of them unwanted
  `new_task` items (see Now). Not yet seen on a phone.
- **2026-11-04.** Composed day, Phases 1-3 (`v10`, committed; backend deployed the next day):
  Canvas's structured sources and the identity layer on the phone; the
  `extract-facts` Edge Function, `course_facts` migration and manifest facts
  on the server; `AppliedFactStore`, the precedence engine, card tags with
  `undo` and the megaphone's `changed`/`needs a look` groups on the phone.
  3559/340 green, Deno 671. "Status: submitted" no longer goes into pooled
  assignment text. Device verification is open.
- **2026-11-01.** Probe before declaring the Canvas session expired
  (`v9`, `docs/SIGNOUT_2026-11-01.md`): the 24-hour cookie rule now
  starts a `GET /api/v1/users/self` check instead of the banner; alive
  re-stamps the cookies, dead renews as before, no answer changes
  nothing. Background and foreground renewals keep separate cooldown
  slots, a background timeout is recorded as timed out, and the refresh
  banner needs a real verdict. 3420/328 green; proven on Marco's phone
  2026-11-02 (aged launch: `session probe: alive`, no banner).
- **2026-10-30.** Onboarding polish (Marco, from the phone,
  `onboarding-polish-2026-10` off `origin/v8` `019e1a5`): the intro's first
  pane animates its scattered chips into an ordered list; Grade Watcher
  dropped from the intro's feature list; the preview door removed from the
  Canvas login pane (school pane keeps it) and the intro's Preview link
  centred under Get started; the Sweeper section's parenthetical line cut;
  the practice lesson's "You've got it" pause removed; the dashboard add
  button is a plain plus; `DuoPasscodeAutofill` marks Duo passcode fields
  for iOS one-time-code autofill (unverified on a device). Photos of the
  founders on the intro were considered and dropped the same day.
- **2026-10-23.** Automatic Penn credential saving after verified Canvas login;
  no duplicate password prompt or opt-out sheet. Added connection confirmation,
  pre-login disclosure, origin/lifetime guards, and Keychain error handling.
  Live PennKey/Duo/autofill validation remains required before release.
- **2026-10-23.** Smooth Sweeper settings (Marco, `codex/sweeper-settings`,
  PR 12): its own Profile section under Reminders with 5/10/15/20/30/60-minute
  timing, four sounds (Smooth's clip, a chime, a pulse, the system alarm) with
  previews, and a per-class selection; defaults unchanged (10 minutes, Smooth,
  every class). Merged into the 3.2.0 release on 2026-10-24 at Olisa's word,
  as build 15 (`release-3.2.0-sweeper`); build 14 was uploaded without it.


- **The Chrome extension** (2026-10-22, `3fa853b` through this commit on
  `v8`; owner's scope: a helper for the phone). Pure ES-module ports of
  the phone's parsing (course code, ICS, Gradescope, dedup, document
  builders, Ed) with 467 node tests; a popup in the Smooth design reading
  Canvas and Gradescope through the browser's own sessions; a collector
  for every announcement, page and course PDF plus Ed staff posts; QR
  pairing and end-to-end encrypted sync of completions, due edits and the
  student's own tasks; the backend's `collector` rule, `file` kind,
  `pair` and `device-sync` (406 Deno tests); the phone's half, never
  compiled. Nothing deployed, nothing loaded in a real Chrome yet.
- **2026-10-22: voice dictation in ask** (`v8`, 2485/227 green, built and working on Olisa's iPhone the same morning):
  a mic in the composer, on-device recognition only, tap to listen and
  tap send to send. The owner's "voice mode" request; the hands-free
  version is under Next.
- **2026-10-20: the debug diagnostics are off the Profile page** (`v8`,
  blind): the sign-in health lines, the ed status row, the three sync
  summaries and the "testing" section are behind
  `FeatureFlags.profileDiagnostics = false`, nothing deleted. The owner
  saw them on his DEBUG build and did not want them visible in this
  version.
- **2026-10-20: "Smooth Sweeper"** (`v8`, blind): the owner's student-facing
  name for the loud 10-minute alert, on the Profile switch, the takeover
  heading, the island card and the alarm permission text; and a "smooth
  sweeper" section with that switch (on by default) at the foot of the
  reminders page of onboarding. (It was a page of its own for a few
  hours; the owner saw both on his phone and had them combined.)
- **2026-10-20: the Berserk takeover screen** (`v8`; seen working on
  Olisa's phone the same day; `CLAUDE.md` → Profile → reminders). The whole window turns tomato the moment Smooth
  is on screen with the alarm ringing, when the app is opened while it
  rings, or when a loud buzz is tapped or lands in the foreground: a live
  countdown, the assignment, the class, "turned in" (through the same
  inbox as the notification button), "open in canvas", "not yet". iOS
  does not let an app take the screen while closed; this is the ceiling.
- **2026-10-20: the Berserk alarm's Live Activity is drawn by the widget
  extension** (`v8`; the tomato island card seen on Olisa's phone the same
  day; see `CLAUDE.md` → Profile → reminders). After
  Olisa rang the alarm on his phone and found the unlocked-phone alert "a
  little alarm notification drop in": the Dynamic Island and the
  lock-screen card are now Smooth's (tomato, class, assignment, live
  countdown), the metadata type moved to the Kit so the widget can decode
  it, `NSSupportsLiveActivities` is set, and the alarm id namespace is
  `v2` so alarms scheduled by the previous build are rescheduled once.
- **2026-10-20: the dashboard freeze** (2414/217 green on Olisa's Mac;
  not yet felt on the phone): the megaphone badge was recomputed in `ContentView.body`
  with a ledger fetch and an all-pairs regex scan per read. Now stored
  and refreshed at data changes; regexes cached; one course parse per
  item per rebuild; one view-model reload per burst. `CLAUDE.md` → Traps.
- **2026-10-20: "what's new on ed" gets the newest posts** (`RecencyIntent`,
  2409/216 green on Olisa's Mac, not yet on a phone): a recency question puts the newest dated Ed
  posts and announcements first in the excerpts, within the window named.
  Asked for after the tree listed Aug 28 to Oct 7 posts as "recent" and
  missed Oct 12 and Oct 18.
- **2026-10-20: ask can say where and when each section meets** (backend
  only, on `v8`; deployed the same day, `sync` v9 and `ask` v10). `sync` keeps each registrar section's
  room and instructors from Penn Labs, and `ask`'s COURSE STRUCTURE block
  lists every section's days, times, room and instructors with the
  student's own marked. Asked for after ask answered "where is my CIS 2400
  midterm" with no room; an exam room still has to come from an
  announcement, and this gives the lecture, lab and recitation rooms.
  Deno 366/0. Not yet seen answering on a phone.
- **2026-10-20 (`v8-merge-loud-alert`, written without a compiler, then
  compiled green on Olisa's Mac the same morning, 2397 / 214, and built to
  the phone): Olisa's `v8` and Marco's `v8-loud-alert-actions` merged.**
  Both lines had built the same two things:
  - **One Ed task pass.** Marco's (`syncEdAnnouncementTasks`) stays;
    Olisa's feeding of Ed posts through `syncAnnouncements` (and its
    `edAnnouncementsForExtraction` and `announcement-ed:` find ids) is
    removed. The survivor gained what the other had: the header's
    posting day as the post's date and window (`edPostDate`), a twin
    check against finds already made, a stop on a quota refusal, and a
    one-line `lastEdTaskSyncSummaryV1` shown beside the other two in the
    DEBUG rows. Staff posts that are neither announcements nor pinned are
    no longer read for tasks.
  - **One past-due rule.** Marco's `isHiddenAnnouncementTask` is the rule
    for announcement and Ed tasks; `AppState.isExpired` is the `.event`
    rule alone again. Ask's work pool now follows the rule too
    (`announcementItemsStillOpen`); the widget's ledger fallback keeps the
    dated half.
  - **Kept from Olisa's day:** the work-identity dedup tier ("HW 2" =
    "Homework 2"), the extraction retry cap, quota stop and one-hour
    back-off in the Canvas loop, the announcement and course-material
    sync summaries with the first error's kind, the Ed posting day in the
    megaphone rows, ask excerpts and the on-device answerer. **Kept from
    Marco's:** everything else in the entries below, Grade Watcher hidden
    included.
  - Merge hazards found and fixed: debug summary rows git had put inside
    the Release "sign in to canvas" row; the megaphone's past-due lists
    and one of Marco's tests still naming `isExpiredEvent`.
- **2026-10-19 (`v8`, written without a compiler; Olisa).** Announcement
  and Ed tasks (`.canvasAnnouncement`) disappear at their due time instead
  of turning overdue; the ledger is untouched and completed ones stay in
  prev. (Where it is implemented changed in the merge above.) Also that
  day: the Ed posting day shown on rows and used by ask; a one-line
  summary of each announcement and course-material sync; the retry cap
  and one-hour back-off for a failing extractor (the shared 40-a-day quota
  had been emptied in under an hour); the "HW 2" = "Homework 2"
  identity tier.
- **2026-10-19 (`v8-loud-alert-actions`, off `v8-announcements` at
  `75dc7aa`, pushed 2026-10-19, not merged): "Berserk mode" is the loud 10-minute alert,
  now with buttons.** Marco: right before an assignment goes unsubmitted
  it "goes berserk and forces you to notice and either fix it or do
  something about it". Each buzz has **"turned in"** (silences the rest,
  then marks the item done as a swipe does) and **"open in canvas"** (or
  "open in gradescope"). The notification delegate is now installed at
  launch, so a tap that cold-launches the app is not lost. On iOS 26 the
  buzzes become **one AlarmKit alarm** (Marco: the three buzzes "doesn't
  quite do enough"): full screen, through silent mode and Focus, with
  "turned in" as the only button that marks anything done and Stop
  opening the assignment. Older iPhones, the Mac and a refused permission
  keep the buzzes. A build from before the review fixes was installed on
  Marco's iPhone on 2026-10-19, and it rang (once alarms were allowed
  for Smooth). Then with his own alarm sound, the first 13 seconds of a
  song faded out and 20% quieter: "this is perfect for berserk mode".
- **2026-10-18 (`fix/submission-status`, off `v8-announcements` at
  `75dc7aa`, pushed 2026-10-19, not merged): turned-in accuracy.** From the stale PHYS 0151
  prelab report. Two ways the app could get "turned in" wrong are closed,
  each with tests:
  - A `.canvasModules` row and a calendar row with *different* Canvas
    assignment ids are never collapsed into one card ("Lab 3 Report" no
    longer hides behind "Lab 3").
  - A Gradescope assignment's own name no longer counts as its status, on
    the list row or on the detail page ("Graded Problem Set 3" with no
    submission stays on the dashboard).
  - Section-override rows are pinned through `isCompleted` (tests only).
  - The cold-launch refresh and the flaky-detail-page fix are written and
    parked (Now). **Not verified on a phone.** Mac tests and an iOS Debug
    compile only.
- **2026-10-18 (`v8-server-exam-dates`, off `75dc7aa`, local, not merged):
  the server's syllabus exam dates reach the app.** `extract-profile` has
  stored each class's `examDates` since the profile existed, but `sync`
  sent only the grading weights and components, so the phone read exams out
  of the syllabus text on its own. `sync`'s manifest now carries them, the
  app keeps them with the class's profile, and a dated server exam wins over
  the on-device parse of the same exam under the same `syllabus-...` id (the
  on-device parse stays as the fallback; `CLAUDE.md` → What the app does,
  exam cards). **Waiting on a deploy of `sync` that nobody has approved**;
  until then the app behaves as before. The Deno tests were written, not
  run (no Deno on this Mac). Edges in `CLAUDE.md` → Known gaps.

- **2026-10-18 (`v8-ann-rules`, off `v8-announcements` at `80c21ec`, not
  merged): the stale-card rules.** The owner's phone filled with tasks
  already taken or never needed ("Take quiz covering assignments 1 and 2"
  from a Sept 14 Ed post; "Attend the weekly rotation quiz"): "none of
  these previous ones are honestly helpful". Visibility rules at rebuild
  time, no row deleted (`CLAUDE.md` → What the app does, "Which
  announcement tasks show"; Traps):
  - A past, unfinished announcement task is in todo, all and prev
    **nowhere**; a finished one stays in prev. The "past" cards in prev
    (`DashItem.isPast`, `pastItems`, `lapsedAnnouncementItems`) are gone.
  - An undated one shows until 7 days after its post (log, Ed document, or
    when the ledger first saw it), then goes the same way.
  - A same-day "attend / come to / bring / join us / in class today" task,
    due within 12 hours of the post or on its day, is not a card.
  - The Ed pass reads only posts dated within the Canvas pass's 14 days,
    and skips an undated one.
  - **Open, for Olisa's code:** the Ed document's date is the thread's last
    *activity*, so a bumped old thread still gets read; carrying
    `createdAt` through `EdIngestion.documents` would close it.
  - **Not verified on a phone.** Mac tests (2207) and an iOS compile only.
  - **Applied to `v8-announcements`** with the sheet redesign below: the
    megaphone's found list and badge ask the same rule, so they no longer
    list a task the dashboard hides (that was this entry's open item).

- **2026-10-18 (`v8-announcements`): the megaphone sheet, redesigned.** The
  owner's notes: "just the most recent announcements from each class… a
  helpful filter by class… just the past 7 days… I like the summary of
  them, then the ones that are found, like Midterm 2 looks great like that."
  - **Two lists, found first.** Found: tasks and exams found in Canvas
    announcements and Ed posts, the syllabus's exams included, as the
    dashboard's own cards, only while still ahead (not finished, not hidden
    by the rule above); hidden when empty. Announcements: Canvas and Ed
    posts from the past 7 days, newest first, each with its summary and NEW
    tag. The log still keeps 60 days; the 7 are display only.
  - **Class filter** over both (the dashboard's menu, default all classes),
    "back to assignments" instead of "done", and a badge that counts only
    what the sheet can show.
  - **Colours.** The header megaphone circle is marigold; the dashboard's
    class filter is cobalt (ink glyph on a cobalt fill).
  - **Not verified on a phone.** Mac tests (2230) and an iOS compile only.

- **2026-10-18 (`v8-announcements`, not yet committed): ledger-safety fixes
  from the review of the announcement-task commit.**
  - **Aging no longer deletes a flagged announcement row.**
    `AssignmentStore.isAgedOut` exempts `.canvasAnnouncement` (and the
    widget's copy of it, which now also hides a flagged one); the test that
    pinned the deletion pins the opposite. `CLAUDE.md` → Traps.
  - **Two announcements are one task only on the same day**; a live twin is
    never hidden behind a lapsed one; a tick carries only between copies of
    the same day (never across a reschedule); an undated Canvas exam yields
    to a dated twin.
  - **A truncated fetch is not a deletion**: a class that returned nothing
    is not judged, and a post must be missing twice in a row.
  - **Edited due dates** survive their row being hidden.
  - **Ed pass**: re-checks the class after the read and before writing,
    and waits six hours before re-asking for a post whose read failed. The
    syllabus pass re-checks too.
  - **`docs/PRIVACY.md`** says the post's id goes with the AI-assist
    request.

- **2026-10-18 (`v8-announcements`, not yet committed): exam cards.** "If
  you ever have a midterm, the class finds it from the syllabus or from an
  announcement. Either way, don't duplicate it." Black in light mode, white
  in dark (the card style was already merged); this adds the finding and
  the one-card rule.
  - **From the syllabus.** `AppState+SyllabusExams.swift` reads each
    class's syllabus, course home page and course pages in the on-device
    course knowledge (`SyllabusExamRows`, `SyllabusExamExtractor`) at
    launch and whenever the material changes, and files one
    `.canvasAnnouncement` row per exam with a `syllabus-{course}-{exam}` id
    (no new source, no schema change). A date with no time is stored at the
    end of its day, as Canvas all-day entries are.
  - **One card per exam** across Canvas or Gradescope, Canvas and Ed
    announcements and the syllabus, by exam identity and date
    (`ExamDetection.isSameSitting`): a feed item first, then an
    announcement, then the syllabus, so an announced new date replaces the
    syllabus's. Unnumbered against numbered, and Midterm N against Exam N,
    only when the days are within one. A tick on the hidden twin follows to
    the shown card.
  - **Rules.** Shows for every visible class whatever the "announcements
    on dashboard" and "nothing to submit" switches say; past and unfinished
    drops off the dashboard (finished stays in prev);
    the ordinary reminders, never the loud 10-minute alert; not in the
    megaphone.
  - Also in this tree and now described in `CLAUDE.md`: the loud
    10-minute alert switch (Profile → reminders) and "the vault" PennKey
    sheet.
  - **Not verified on a phone**: tested on the Mac (64 new tests, 2164
    total) and compiled for the connected phone only. Edges are in
    `CLAUDE.md` → Known gaps.

- **2026-10-18 (`v8-announcements`, not yet committed).** Grade Watcher
  removed at the owner's call, and the megaphone takes its place.
  - **Grade Watcher off.** `FeatureFlags.gradeWatcher = false`: no
    grades button, no "grade posted" notifications. The Canvas grade
    fetch keeps running on purpose (auto-submitted state, "turned in",
    the 401 renewal probe, course intel, course knowledge). Code and
    tests kept; re-enabling is one line.
  - **Megaphone in the header**, 48pt, left of profile, always shown;
    out of the control row. Empty list says "no announcements".
  - **Profile → accounts.** DEBUG sign-in lines back in plain view
    under the canvas row (the collapsed disclosure is gone); a Release
    "sign in to canvas" button when Canvas is connected with no saved
    login.
  - **Tasks found in announcements are cards** (owner's call), Canvas and
    Ed alike. Every task, submission or preparation, is a dashboard card
    for a class whose "announcements on dashboard" switch is on (default);
    only wording that reports something done ("grades posted") stays in
    the megaphone. Undated ones sit under "later" in all, like any undated
    item. Ed announcements and pinned posts are read for tasks by the same
    extractors and the same "ai assist" switch as Canvas posts, once each
    (`AppState+EdAnnouncementTasks.swift`); `docs/PRIVACY.md` says so.
    Rows are `.canvasAnnouncement` with an `ed-` sourceID, so no schema
    change and an older build reads them as announcement rows.
  - **Past, not completed.** (Superseded the same day by the next entry
    up: such a task now leaves the dashboard entirely instead of sitting in
    prev as "past".) Ordinary Canvas, Gradescope and manual work is
    untouched.
  - **Deleted posts.** A Canvas post that stops coming back inside the
    fetched window has its cards hidden (rows flagged `isGoneFromFeed`; a
    finished task stays in prev); an empty or failed fetch hides nothing,
    nor does a class the fetch returned no post for, and a post must be
    missing twice in a row. The rows are never deleted: until the review
    pass the same day, the ledger's aging rule deleted a flagged row 14
    days after its date, so this said "never deleted" and was not true
    (`CLAUDE.md` → Traps). Not done for Ed, on purpose: see Known gaps in
    `CLAUDE.md`.
  - **One card per task** across Canvas, Ed and the feed, with a tick
    carried to the card that is shown.
  - **Not verified on a phone yet**: only compiled for the connected
    phone (Debug) and iOS Release, and tested on the Mac.

- **2026-10-09/10 (`v8-launch-prep`).** Marco's launch-prep list, on top
  of `v8`. Nothing in sign-in or the sync changed.
  - **Links.** An opened card has "open in canvas" / "open in
    gradescope" (`a0e7e04`).
  - **Reminders.** An opt-in "10 minutes before" (`a99c9f3`); the
    assignment's name in the body, "Problem Set 4. Due in 1 hour"
    (`13b2acb`); titles use the renamed class; a saved empty selection
    is no longer read back as the defaults; switches reschedule.
  - **Sign-up.** A new student's dashboard no longer opens on a
    semester of overdue work: unfinished feed items more than a week
    overdue at sign-up are withheld, with "N older hidden · show" at the
    foot of prev (`85a0c2b`, reworked in `01afe8e`). Existing installs
    see no change.
  - **Announcements.** The megaphone is a real list: every Canvas
    announcement from the last 60 days, plus Ed announcements and pinned
    posts, with extracted tasks on top (`67d5957`, `b5ed8a1`, `2ef85cc`).
    It used to list only extracted tasks, which was nearly always
    nothing.
  - **ask.** The on-device search finds what the materials say
    (`ac45b9b`); eight whole passages per question and follow-ups that
    remember their class (`24c4349`); Ed posts dated and included in
    "latest announcements" (`1acde04`); short canned text (`33d83b5`);
    source chips that open their source (`0a47762`).
  - **Less text.** Profile → accounts has no sign-in prose; banners,
    sheets, onboarding, Grade Watcher and the widget are cut to what a
    student needs (`9058d0a`, `46657ce`).
  - **Your own work.** An edited due date is saved and used on the
    phone (`2bafd94`, `83865fc`); a one-off task can be deleted and a
    recurring one stopped from its opened card (`e5031ec`).
  - **Small fixes.** "8m" instead of "1h" under an hour, 44pt targets on
    + and the megaphone, a true todo empty state, VoiceOver on the due
    column, a "not saving on this phone" banner, the widget trusting an
    empty snapshot and re-rendering when work goes overdue (`9e1ccae`,
    `31336d5`).
  - **Found, not fixed** (the sync is off limits): the course-material
    sync has never collected an announcement, and a half-failed sync
    erases documents for the class. See Now.
- **2026-10-09 (`v8`, blind, second round).** Review fixes for the
  sign-out commit: the background wake awaits its renewal and tears it
  down on expiry; a failed navigation is unknown, not a landing; a
  persisted Duo stand-down for background wakes; the attempt cooldown
  seeded from persistence; a proven-alive session resets the landing
  streak; the reconnect banner hidden while a renewal is in flight;
  Profile's health lines in plain words with the rejected and
  waiting-on-Duo states; "switch school?" confirmation in the picker;
  `docs/SIGNOUT_VERIFICATION.md`.
- **2026-10-09 (`v8`, blind).** The App Store sign-out investigation and
  fix: `docs/SIGNOUT_INVESTIGATION.md`. Olisa's "never signed out" phone
  turned out to run the same App Store build 11; the difference was a
  saved password, Duo trust and daily use. Fixes: the pre-login purge keeps
  Duo trust; reconnect starts at the Canvas login, not the school picker;
  the background-refresh crash is fixed with a never-latch guard; foreground
  renewals retry on a cooldown instead of latching on one timeout; a
  secret-free last-renewal summary and a sign-in health line in Profile;
  Gradescope cookies re-stamped on sync; stamped 3.0.1 (12).
- **2026-10-10.** Ed Discussion backend live: the `ed` kind migration
  applied and `sync` version 7 deployed, with Olisa's go. On 2026-10-09
  the DEBUG probe proved the access path on a real phone (LTI launch
  lands on Ed; the session is a `localStorage` token, now captured into
  the Keychain and sent as `x-token`; Ed answered 200 with 19 courses).
  Still to do: one full sync on a device.
- **2026-10-02 (`v8`, blind).** Ed Discussion ingestion end to end
  (`docs/ED_DISCUSSION.md`); the `ed` document kind on both sides of the
  wire.
- **2026-10-08.** Found why the live build keeps asking for a refresh
  (see Now). DEBUG builds gain `-LHFSessionDiagnostics`, a launch-time
  readout of the saved password flag and saved Canvas cookies (names and
  dates only). No behaviour changed.
- **2026-09-28.** 3.0.0 (11) approved and released on the App Store.
- **2026-09-27.** Stay signed in works like Olisa's phone again: the
  24-hour cookie rule and Penn's cookie handling restored byte for byte
  from `39b2fff`, so the app re-logs in on open after a day away (PennKey
  auto-fill, Duo's remembered device, back to Canvas). Proven on Marco's
  phone with a real PennKey (renewed in 8 s, hands-free). DEBUG builds
  gain `-LHFAgeCanvasSession` and the `debugRenewalLogV1` attempt log.
  3.0.0 build 11 archived and uploaded; in App Store Connect the updated
  developer agreement was accepted, the version renamed 3.0.0, and What's
  New plus concise review notes saved (`docs/appstore/REVIEW_NOTES.md`).
  Found the silent background-refresh crash (Now).

- **2026-09-25.** The dark-mode "chill"
  Buddha is a positive image (`Resources/chill-dark.png`, generated by a
  border flood fill, tinted light blue) instead of a colour-inverted
  negative. The add sheets' class field is a wrapping grid of per-class
  coloured chips (`CoursePicker`, `courseAccent(for:)`), and the class
  filter menu shows each class's open count and colour dot. From the same
  day's audit: the widget has a dark mode and Dynamic Type (capped at
  xxLarge); `DesignSystem.swift`, the dead pre-Smooth palette, is deleted
  (`Color(hex:)` moved to `RedesignTokens.swift`); the header and
  `DashboardViewModel` cache their `DateFormatter`s; the control-row
  circles and todo · all · prev switch have 44pt hit areas with unchanged
  visuals.
- **2026-09-25.**
  - `CLAUDE.md` rewritten to match the app: the session protocol, a
    screen-by-screen "what the app does", schools, the current test
    baseline, and branches.
  - The PennKey offer is Penn-only; other schools were being asked for a
    PennKey after every Canvas sign-in.
- **2026-09-24/25 (`V7`).**
  - Settings: removed course-materials status, "report a problem",
    troubleshooting, the Grade Watcher row and "1 week before" reminders
    (the scheduler also skips saved `.d7`).
  - Disconnecting Canvas now also deletes server data (per
    `docs/PRIVACY.md`).
  - Stay signed in: no toggle; offered after each manual Canvas sign-in at
    Penn.
  - PennKey sheet: lock icon and a one-line disclaimer.
  - Prev (Done): leads with "N down this week"; earlier work opens in place.
  - Unread-only announcement badge, with NEW tags on rows.
  - Full-width todo · all · prev switch and a class filter.
  - Class picker on the add sheets; classless recurring tasks are filed
    under the class their title names.
  - Wave-and-shine animation when you tap the Smooth wordmark.
- **2026-09-23/24.**
  - Multi-school sign-in (`fbfc702`).
  - Canvas and Gradescope sessions kept alive until the server rejects them,
    not a local 24-hour clock (`fac110d`..`99609c0`).

### 3.4.0 onboarding work (2026-10-28)

Marco's PR #16 was folded into the release, now **3.4.0 (17)** on
`release/3.4.0`. School search runs locally over 220 bundled US university
Canvas sites, with a manual address as the fallback. A two-step practice
lesson on a sample dashboard runs while the first Canvas sync does: swipe
right to complete, tap or swipe left in "prev" to undo. Done cards take a
left swipe to undo a completion. Gradescope is a two-button choice, "Continue
with Canvas only" or "Add Gradescope". Preview labels all read "Preview",
bottom-right, hidden under the keyboard. The empty AI screen has no
suggestion buttons: a placeholder example, the Smooth mark as the send
control, the shared `SmoothFormShapes` cluster top-right and the rotating
greeting centred under it. Chats are saved on the device as per-conversation
files under Application Support, scoped by Canvas host, never synced; a
history icon reopens them and "New chat" archives the current one. The
matching backend prompt change is live since `ask` v13 (2026-11-02).
Assignment-card Canvas links try the Canvas Student app before HTTPS. The
connect flow confirms first: a "Canvas connected" page with a disabled
"Syncing Canvas…" button over the still-mounted login pane, then Continue
starts the practice lesson (a Canvas-only reconnect completes directly). The
PR's rewrite of Canvas sign-in detection was not taken: v8's host-marker
detection and `CanvasConnectRetryRule` are restored verbatim, since the
proven phone behaviour is the standard and the rewrite was never checked with
a live sign-in; the author's later `isCheckingCanvasPage` page-hiding
addition was dropped with it. Details in CLAUDE.md → 3.4.0 section.

Open, from the 2026-10-28 verifier pass (details in CLAUDE.md → 3.4.0 → Review
notes): the chat-history store is rebuilt on every Ask re-render (move it into
the `StateObject` autoclosure), the first-run "Syncing Canvas…" overlay has no
X, the store's error banner never clears, viewing a chat bumps its date, the
empty streaming row is saved early, saved chats carry no schema version, and
"Add Gradescope" has no back. Open: Marco's live Penn sign-in test on his phone; the Canvas app hand-off,
unchecked on a device. The prompt change went live in `ask` v13 on 2026-11-02.
