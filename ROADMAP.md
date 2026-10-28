# Smooth roadmap

The plan: what blocks the next release, what's next, and what was tried and
set aside. `CLAUDE.md` is the engineering reference (what the app does, how
the code works, the traps it has hit). **Every session reads both at the
start and updates both before it ends** (`CLAUDE.md` → "Start here" has the
table of what goes where). When an item lands, move it to **Done recently**
with its date and commit, rather than deleting it.

Last updated 2026-10-28 on `release/3.3.1` (the 3.3.1 release). Before
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
**3.3.1 (17)**, the two crash fixes plus the hardening round, from
`release/3.3.1` (`docs/RELEASE_3.3.1_PLAN.md`). Marco's launch-prep work
(2026-10-09/10, built on `v8-launch-prep`) was merged into `v8` on
2026-10-10 through pull request 9, at his instruction, so it now rides
in whatever is built from `v8` next. Most of it has not been on a phone:
the first item under Now is the check that should happen before a build
from `v8` goes to TestFlight.
Marco's `fix/canvas-signin-bulletproof` (last updated 2026-10-08, on `V7`,
when 3.0.0 (build 11) had been live since 2026-09-28 and the next release
was 3.0.1 with the sign-in fixes at the top of Now) is merged in on
`v8-merge-marco` (2026-10-23); his Now and Done entries keep their own
dates.

---

## Onboarding review — 2026-10-28

Work moved to `codex/onboarding-current`, based on current `origin/v8` 4316bba
(includes release 3.3.1). The old onboarding checkout was based on 3.0.0 and
must not be installed again. The current Canvas credential capture is retained:
no post-login vault sheet or second credential entry. Search includes 220
curated sites with relevance and typo ranking; Preview hides with the keyboard;
Gradescope is optional with the explanatory paragraph removed. Device login
and automatic reconnection still require interactive verification.

## Now: before the next release

These block shipping, or would make shipping risky. The launch-prep
work of 2026-10-09/10 is summarised, with the order to take these in,
in `docs/LAUNCH_PREP_HANDOFF.md`.

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
  7. A fresh install in mid-semester: old overdue work withheld, "N
     older hidden · show" at the foot of prev.
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
- **Let a follow-up question carry the conversation.** Follow-ups search
  better on the phone since 2026-10-10, but the model still sees each
  question alone (`history: []`). The server already accepts ten turns;
  sending them is a privacy-policy change that needs a yes.
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

2026-10-28 verification on `codex/onboarding-current`: 61 targeted tests in
8 suites passed (catalog/ranking, credential capture/write, Canvas login
hardening, failure recovery and reconnect behavior). iOS Debug device build
succeeded; 3.3.1 (17) installed and launched on the owner's iPhone 17 Pro.
No Xcode UI or simulator used. Interactive sign-in/renewal is still for device
review; these tests do not claim a live authentication result.

### Canvas sync lesson and undo gestures — 2026-10-28

Full onboarding now shows one concise completion lesson while Canvas syncs.
A local practice card teaches swipe-right to mark done and tap/swipe-left in
`prev` to undo; it never touches real assignments. Continue waits for verified
connection and credential persistence, then goes to the optional Gradescope
choice. Fast sync leaves the lesson visible; failure returns to the retained
login web view. Settings reconnects keep their existing confirmation.
Completed dashboard cards now support left-swipe undo through the same persisted
`markActive` path as tapping. Vertical scrolling and short nudges do not undo.
These actions only change Smooth's completion state, never Canvas submissions.

Final validation on 2026-10-28: `swift test --package-path LowHangingFruitKit
--jobs 2 --no-parallel` passed 3,388 tests in 324 suites, with the pre-existing
known `EdFilterParityTests` anonymous-thread issue. The iOS Debug device build
passed; installed on the owner's iPhone 17 Pro and opened the practice lesson.
Catalog regeneration is deterministic; `git diff --check` is clean. No Xcode
UI or simulator used. Live multi-school sign-in remains outside this automated
coverage. The owner approved the preceding onboarding screens on-device.


### Dashboard practice (2026-10-28)
The standalone practice card and six-step feature tour are replaced by two
sample-dashboard states during first Canvas sync. The real AssignmentCardView
swipes right into prev; the real DoneCardView taps/swipes left back into todo.
The surrounding sample cards and dashboard controls are muted. After swipe and
undo practice, Next introduces lists, classes, adding tasks, announcements, AI,
and settings one at a time, with a highlighted control, arrow, one-sentence
explanation, and Back/Next navigation. Continue requires finished lessons and
successful sync. Gradescope choices are centered vertically/horizontally, with
“Continue with Canvas only” and “Add Gradescope.”
All fixtures and progress are local to CanvasCompletionGuide; nothing is loaded
into AppState or persisted. The underlying login WebView stays mounted. Optional
Gradescope and reminder setup follow as before, then the real dashboard opens.
The feature lessons stay inside the practice flow; reconnect does not replay them.
DEBUG review: `-LHFFullOnboardingReview -LHFSkipIntro -LHFCompletionGuideHarness`.
Installed on iPhone 17 Pro and verified via Mirroring: swipe right enters prev,
swipe left restores todo, and Continue opens the optional Gradescope question.
School-search screen and bottom-right Preview were visually confirmed. All
Preview labels now use exactly “Preview,” including intro and Sweeper audio.
Full authenticated sign-in remains separate from this sample-data review.
Validation: iOS Debug build and 25 focused tests in 5 suites passed.
Latest revision: iOS build and 26 focused tests passed; installed the centered
Gradescope choices and separate feature steps. Verified swipe-first entry on
the phone; Mirroring input errors blocked the new feature-step tap-through.


### AI presentation and onboarding routing (2026-10-28)
AssistantView now uses a single example as the input placeholder, regular sans
text, a rounded multiline composer, and idle-only rotating greetings (Ask about classes / How
can I help? / Happy weekday). Rotation pauses for typing or a conversation and
is disabled by Reduce Motion. Answer formatting preserves paragraphs and source
links while removing strong emphasis. Backend prompt changes request concise,
phone-readable answers without bold; those instructions require backend deploy.
Late/repeated Canvas completion callbacks are ignored outside canvasLogin or
once the guide is ready, preventing backward routing into the Gradescope
choice. The reported duplicate question still needs live reproduction.
Assignment-card Canvas links try universal links, then canvas-courses:// with
the same host/course/item/query, then fall back to HTTPS. Other providers and
macOS keep normal links. Scheme reference: https://instructure.github.io/mobile-app-api/
Validation: 62 targeted Swift tests / 9 suites, 20 backend prompt tests, and
iOS Debug build passed. Installed and visually checked AI on iPhone 17 Pro;
Mirroring input errors prevented completing the live repeat-question check.
Canvas app handoff remains to be checked on device. Backend is not deployed.

AI empty-state refinement: removed suggestion buttons and the top-left logo.
“What’s due this week?” is placeholder text only; it does not populate the draft.
The Smooth mark is the send control. A compact noninteractive geometric cluster
sits in the top-right corner of the empty screen and disappear while typing or reading a conversation.


### Centered AI entry and chat history (2026-10-28)
The empty AI screen centers its regular-weight rotating greeting below the
exact SmoothFormShapes component shared with Profile. A top-right history
icon opens locally saved conversations; reopening restores message IDs,
answers, and citations and allows follow-up questions. New chat archives the
current transcript. History uses atomic per-chat files in Application Support,
scoped by Canvas host, and does not participate in app cloud/paired sync.
Preview/demo sessions stay in memory. Partial answers checkpoint during
streaming and save on stop/exit; request IDs prevent cancelled streams from
altering a newly opened chat. Older unsaved conversations cannot be recovered.

### Onboarding review polish (2026-10-28)
Verified Canvas connection now shows the Canvas Connected confirmation first.
Continue starts the practice dashboard and feature tour for full onboarding;
Canvas-only reconnect still completes directly. After practice undo, the sample
card fades and the instruction points to Next. The Sweeper keep-on note sits
below its toggle. The login pane stays mounted until verified connection.

### Canvas sign-in presentation polish (2026-10-28)
Candidate Canvas documents are hidden before rendering while authenticated ENV
evidence is checked. Verified sign-in immediately displays Canvas Connected over
the still-mounted login pane during sync/credential saving; failures return to
retry, and Continue stays gated until completion. This confirmation has no dots.
The optional Gradescope page has its heading near the top and buttons below,
without the repeated Canvas-connected label.
