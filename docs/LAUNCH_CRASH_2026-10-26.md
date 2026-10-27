# The launch-day crash (2026-10-26): what it is, what is proven, the plan

On 2026-10-26 Smooth was handed out with smoothies and a few hundred
people installed it. Some of them reported the same thing: open the app,
and a moment later it quits. A few people had reported it before the
launch too. This is the record of what was found that evening, from the
code and from what this Mac could reach, and the plan that follows.

## What is live

**3.2.1 (15)**, released 2026-10-25 at 18:46 UTC (public iTunes lookup,
read 2026-10-26), archived from `4fe7a4f` on `v8`. Everyone who installed
on launch day got it. The `update-manifest` floor is 3.2.0, so it is
not forcing anyone anywhere that matters here.

## The cause, as far as the code can prove it

**Two Canvas assignment groups whose names reduce to the same id crash
the app on every launch, for every student in that course.** This is
item 2 ("A1") of `docs/HARDENING_PLAN_2026-10-25.md`, found by the
reliability audit the day before the launch, before anyone had a
symptom to pin it to.

The chain, read in the 3.2.1 source (`4fe7a4f`):

1. The automatic sync runs on every launch and every refresh tick
   (`AutoSyncCoordinator.swift:63` → `AppState.refreshGradeWatcher`). It
   fetches grades for every selected course, in Release, even though the
   grades screen is hidden from the UI.
2. Each successful course fetch records today's grade
   (`GradeWatcherStore.refresh` → `recordHistory` → `breakdown`), which
   runs `GradeEngine` with `effectiveCategoryMap(courseID:)`.
3. With no syllabus map, that is `GradeCategoryMapBuilder.mirroringCanvas`,
   which gives each Canvas assignment group the id
   `"map:" + GradeCategoryMap.slug(name)`. The slug lowercases and keeps
   only alphanumeric runs, so "Homework" and "homework", "Quiz (EC)" and
   "Quiz - EC", "Labs" and "LABS", or a recycled course that carries two
   "Assignments" groups from a course copy, all collapse to one id.
4. `GradeEngine.swift:181-196` builds `Dictionary(uniqueKeysWithValues:)`
   on those ids. A duplicate key is a Swift runtime trap: the process is
   killed with `EXC_BREAKPOINT`. There is no catch for it.

Why it fits what people saw:

- The dashboard appears first and the app dies a few seconds later, when
  the grade fetch returns. That is "open the app, then it crashes".
- It happens on every launch, and reinstalling does not help, because
  the groups live in Canvas, not on the phone.
- It is per course: everyone enrolled in a course with colliding group
  names crashes, and nobody else does. The same bug has been in every
  build since Grade Watcher existed, which is why a few people crashed
  before the launch too.
- A few hundred new installs means a few hundred course lists. Each new
  course is one more chance that some instructor named two groups the
  same way, and every student in that course then crashes. That is the
  whole of the "more downloads, more crashes" effect. There is no
  server-side load involved: the crash is in arithmetic over Canvas's
  own data, after the fetch has already succeeded.

Two things ruled out on the way:

- **AlarmKit on iOS 17 and 18.** The app imports AlarmKit, an iOS 26
  framework, and the store listing allows iOS 17. If it were linked
  strongly, every pre-26 phone would die before the first frame. `otool
  -l` on the 3.2.0 (14) archive on this Mac (built 2026-10-23, the same
  linking as 3.2.1) shows `LC_LOAD_WEAK_DYLIB` for AlarmKit in both the
  app and the widget. Not this.
- **The grade predictor's `Int(...)`** (`GradeCountPredictor.swift:232`)
  is guarded by `elapsedWeeks >= 1`, so its ratio is finite. Not this.

## What this Mac could not reach (and how to reach it)

None of the following was readable on 2026-10-26, so the cause above is
proven from the code and not yet from a crash report. Any one of these
turns it into proof:

- **Xcode → Organizer → Crashes** holds the crash reports that App Store
  users who share analytics with developers send. The Organizer opened
  but said "A developer account is required for downloading crashes
  list". Sign Marco's Apple ID into Xcode (Settings → Accounts) and the
  list fills in; the crash to look for has `EXC_BREAKPOINT`, the
  crashing thread inside `GradeEngine` / `Dictionary.init`, and a message
  like `Duplicate values for key: 'map:homework'`. Organizer also shows
  which iOS versions and devices, which answers the "different phones"
  question directly.
- **A crashing student's own phone.** Settings → Privacy & Security →
  Analytics & Improvements → Analytics Data, files named
  `Smooth-<date>.ips`; AirDrop one over. It is JSON: one header line, then
  a body whose `triggered: true` thread is the one that died.
- **Marco's or Olisa's phone over USB**, with the commands in CLAUDE.md
  → Commands (`xcrun devicectl ... --domain-type systemCrashLogs`).
  Neither was connected that evening.
- **The backend** (how many of today's new accounts ever completed a
  sync) needs the Supabase management token, which is not on this Mac.

## The plan

1. **Fix A1 on `fix/duplicate-category-ids`** (branched from `v8`
   `e3a57b3`, worktree `.claude/worktrees/fix-dup-category-ids`).
   Colliding ids get the Canvas group id as a suffix; ids that never
   collided stay byte-identical, because student edits and the server's
   suggested mappings are keyed on them. Every
   `Dictionary(uniqueKeysWithValues:)` keyed on Canvas, Gradescope,
   syllabus or server data becomes first-wins. `Int(...)` in
   `GradeExplanation` is clamped. Regression tests cover "Homework" +
   "homework" through the builder and the engine. The status of this
   step is at the end of this file.
2. **Confirm with one crash report if one arrives within hours; do not
   wait longer.** The fix is right on its own and costs nothing if the
   log later shows a second cause.
3. **Ship 3.2.2 (16).** Install the Debug build over the store copy on
   Marco's phone first and watch one refresh. Then the archive and
   export commands in CLAUDE.md → Commands (no `xcodegen`; bump
   `CURRENT_PROJECT_VERSION` to 16 in both `project.yml` and
   `project.pbxproj`). In App Store Connect, submit and **request an
   expedited review** (Contact Us → App Review → request expedited
   review, reason: crash on launch for a subset of users, fixed). Apple
   usually grants these the same day.
4. **Raise the `update-manifest` floor to 3.2.2 only once 3.2.2 is
   downloadable**, as CLAUDE.md → Update gate says. A floor above what
   the store serves locks everyone out, including the people who are
   fine today.
5. **Tell the affected students what to expect.** Nothing in the app can
   help them before the update: hiding the course needs the dashboard,
   and the crash comes before they could reach the class picker. The
   update installs over the crash and keeps their data (the ledger
   never deletes, and the App Group container survives an update).
6. **Then the rest of Release A** in `docs/HARDENING_PLAN_2026-10-25.md`
   (A2 reconnect lock-out, A3 the analytics cookie), each with its
   sign-off.
7. **Never find out about a crash from a smoothie table again.** Keep
   Xcode signed in and open Organizer → Crashes the day after each
   release. A MetricKit crash subscriber that reports to the backend
   would be faster, but it is analytics by any name and would need a
   `docs/PRIVACY.md` change in the same commit; that is Marco's call,
   not a default.

## Status of step 1 (2026-10-26, evening)

Done on `fix/duplicate-category-ids`, uncommitted at the time of writing:

- `GradeCategoryMapBuilder.disambiguatedIDs` keeps the bare id for one
  holder of a slug and suffixes the rest. In `mirroringCanvas` the holder
  with the lowest Canvas group id keeps the bare id, whichever order
  Canvas returned them in (a fetch order is not a key), and the others get
  the group id as a suffix (`map:homework-202`). In `suggested`,
  `fromSharedMapping` and `SyllabusGradingScheme.from(profile:)` the
  first in the persisted order keeps it and later ones get a 1-based
  ordinal (`quiz-2`). A suffix is bumped if it would land on a bare id
  another category owns. `fromSharedMapping` still gives a mapping's
  claimed groups to the last scheme category with the same key, as
  before (an independent review caught a first-wins slip there).
- Every `Dictionary(uniqueKeysWithValues:)` keyed on Canvas, Gradescope,
  syllabus or server ids (15 sites across the Kit and UI modules) is now
  first-wins. `GradeExplanation` clamps before `Int(...)`;
  `BerserkAlarmActivity` reads `Date.now` once;
  `GradeReportView.truncatedName` is `nonisolated`.
- `DuplicateCategoryIDTests` (17 tests, two of them for the lowest-id rule
  in both array orders and with ids "9" and "10"). Run against the original source
  they fail with exactly the production trap, `Fatal error: Duplicate
  values for key: 'quiz'`, signal 5; against the fix they pass. One test
  seeds a `GradeWatcherStore` with colliding groups and runs
  `effectiveCategoryMap` then `breakdown`, the chain `recordHistory`
  runs; `refresh` itself builds its own client and cannot be stubbed
  without new infrastructure, so it is not under test.
- `GradeCourseCardView`'s `formatPercent` and `formatPoints` clamp too.
- Gates: `swift build` clean; `swift test --no-parallel` 2924 tests / 263
  suites, one failure, the pre-existing `AskCitationLinkTests` golden;
  the iOS Simulator Debug build of app plus widget succeeded on the first
  round (the second round, the id rule and the two clamps, was compiled
  by `swift build` only).
- Not yet done: a device install, the 3.2.2 (16) stamp, the archive and
  upload, and reading one real crash report (step 2).
