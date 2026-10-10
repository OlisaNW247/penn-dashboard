# Smooth roadmap

The plan: what blocks the next release, what's next, and what was tried and
set aside. `CLAUDE.md` is the engineering reference (what the app does, how
the code works, the traps it has hit). **Every session reads both at the
start and updates both before it ends** (`CLAUDE.md` → "Start here" has the
table of what goes where). When an item lands, move it to **Done recently**
with its date and commit, rather than deleting it.

Last updated 2026-10-10, on `v8-launch-prep`.

Live on the App Store: **3.0.0 (11)**, since 2026-09-28 by the public
iTunes lookup (`v8`'s notes say about 2026-10-01). The next release is
**3.0.1 (12)**, the sign-out fix, from `v8`. `v8-launch-prep` is Marco's
launch-prep work on top of `v8` (2026-10-09/10), pushed and waiting to
be merged into it; whether it rides in 3.0.1 or follows it is Marco's
and Olisa's call.

---

## Now: before the next release

These block shipping, or would make shipping risky.

- **Look at the launch-prep work on a phone** (`v8-launch-prep`). Marco's
  phone has builds up to `b5ed8a1`; everything after is compiled for iOS
  and tested on the Mac only. In order of how much could be wrong:
  1. The megaphone: Canvas announcements reach today (re-read
     `announcement-log.json` off the phone; the first install showed the
     28-day-window bug), Ed rows for an Ed-only class, row layout.
  2. Profile → accounts with no sign-in prose, and the collapsed
     "sign-in diagnostics" in the DEBUG section.
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
- **Ship 3.0.1 (12), the sign-out fix** (`v8`, 2026-10-09, blind;
  `docs/SIGNOUT_INVESTIGATION.md`). 3.0.0 (11) went live about 2026-10-01
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
- **Ed Discussion, phase 2.** The Announcement Watcher reading `ed`
  documents through the same gate as Canvas announcements, once phase 1
  has completed a sync on a device (`docs/ED_DISCUSSION.md`).
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
