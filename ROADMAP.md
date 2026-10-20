# Smooth roadmap

The plan: what blocks the next release, what's next, and what was tried and
set aside. `CLAUDE.md` is the engineering reference (what the app does, how
the code works, the traps it has hit). **Every session reads both at the
start and updates both before it ends** (`CLAUDE.md` → "Start here" has the
table of what goes where). When an item lands, move it to **Done recently**
with its date and commit, rather than deleting it.

Last updated 2026-10-20, on `v8-merge-loud-alert` (Olisa's `v8` merged
with Marco's `v8-loud-alert-actions`; not compiled).

Live on the App Store: **3.0.0 (11)**, since 2026-09-28 by the public
iTunes lookup (`v8`'s notes say about 2026-10-01). The next release is
**3.0.1 (12)**, the sign-out fix, from `v8`. Marco's launch-prep work
(2026-10-09/10, built on `v8-launch-prep`) was merged into `v8` on
2026-10-10 through pull request 9, at his instruction, so it now rides
in whatever is built from `v8` next. Most of it has not been on a phone:
the first item under Now is the check that should happen before a build
from `v8` goes to TestFlight.

---

## Now: before the next release

These block shipping, or would make shipping risky.

- **Check the merge of 2026-10-20 on the phone** (it compiled green,
  2397 / 214, and was installed on Olisa's iPhone that morning; nothing in
  it has been watched running yet). The DEBUG rows under Profile →
  accounts (announcements, ed tasks, course material) say where each sync
  stopped; the Berserk alarm, the exam cards and the megaphone sheet are
  the things to look at. Where the two sides' tests could disagree:
  `AnnouncementFindExpiryTests` against `AnnouncementTaskRulesTests`.
- **Try the section details on a phone** (deployed 2026-10-20): ask
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
- **Decide the three sync questions** (Marco and Olisa; nothing here is
  merged, because Marco said not to touch the sync):
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

Roughly in priority order.

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
