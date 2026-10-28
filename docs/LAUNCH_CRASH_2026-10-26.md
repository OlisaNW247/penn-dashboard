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

**2026-10-27, morning.** Committed on the branch at Marco's say: the fix
as `b73b603`, the 3.2.2 (16) stamp as `f4e448a` (by hand in both
`project.yml` and `project.pbxproj`, no `xcodegen`). Two products were
then built from that tree, both exit 0 with no `error:` lines, both
reading 3.2.2 (16), AlarmKit weak-linked in the archive's app binary:

- the Debug device app, for the phone test:
  `.claude/worktrees/fix-dup-category-ids/build/DerivedData/Build/Products/Debug-iphoneos/Smooth.app`
- the Release archive, ready for `-exportArchive` (the upload step),
  **not uploaded**:
  `.claude/worktrees/fix-dup-category-ids/build/Smooth.xcarchive`
  (created 2026-10-27 16:03 UTC)

Marco had no USB-C cable that day, so the phone test waits. When the
phone is plugged in (CoreDevice id `8A287085-9C88-5A87-816B-1A8EF80D67AD`;
it already runs a developer build, so the container stays readable):

```bash
xcrun devicectl device install app --device 8A287085-9C88-5A87-816B-1A8EF80D67AD /Users/marcoopertti/penn-dashboard/.claude/worktrees/fix-dup-category-ids/build/DerivedData/Build/Products/Debug-iphoneos/Smooth.app
```

```bash
xcrun devicectl device process launch --device 8A287085-9C88-5A87-816B-1A8EF80D67AD com.lhf.lowhangingfruit
```

Then open it, let one refresh run, and read the phone's crash log
folder for any new `Smooth-<date>.ips` (CLAUDE.md → Commands).

## Release A on the same branch (2026-10-27, afternoon)

At Marco's say, A2 and A3 from `docs/HARDENING_PLAN_2026-10-25.md`
landed on `fix/duplicate-category-ids` after the crash fix, each in its
own commit so either can be dropped, each read by an independent
verifier before it was committed:

- **A2, `a3af5b9`: a reconnect is a cover over the dashboard.** Tapping
  the Canvas banner, a Profile → accounts row or the grades screen's
  reconnect now presents the sign-in walk over the dashboard
  (`fullScreenCover` on iOS, a sheet on macOS) with an xmark on every
  step, and never writes `hasCompletedOnboarding = false`; a force-quit
  mid-login lands on the dashboard. The launch-time refresh is re-run
  when the cover closes. The preview footer is hidden for a signed-in
  install. Leaving preview no longer wipes the grade history. "Start
  over" and preview keep the old root swap.
- **A3, `9350b2a`: "expired" is decided by whether a session cookie is
  still fresh.** `SessionCookieStore.load` returns empty for a Canvas set
  whose `canvas_session` has aged out while `_ga` lives on, so the
  24-hour renew-on-open trigger fires again on polluted phones. The
  harvests and the renewer are untouched; a parity test pins the two
  cookie-name matchers together.
- **`d4c1d78`: the stale citation-link golden fixed**, so the suite is
  all green: 2953 tests / 266 suites.

**What a phone has to answer before any of this ships** (none of it has
run on a device):

1. A2, from Profile → accounts: the row calls `dismiss()` and then
   presents the cover in the same tick; the cover must appear every
   time, there and from the banner and the grades screen.
2. A2, the xmark on each step (Canvas login, the school picker through
   the back chevron, the connected pane, the Gradescope step), and that
   closing lands on the dashboard unchanged with a refresh running.
3. A2, a reconnect that completes: the dashboard reflects the fresh
   session without waiting for the five-minute tick.
4. A2, the refresh loop keeps running under the cover now; a silent
   renewal may start while the school picker is showing and is aborted
   when the login pane appears. Watch the `LHF-RENEW` log for one.
5. A2, dark mode and the Berserk takeover or update wall arriving while
   the cover is open (they sit under it until it closes).
6. A3, on Marco's phone (polluted on 2026-10-08): run
   `-LHFSessionDiagnostics` (the `| session` marker shows which saved
   cookies are session cookies), then `-LHFAgeCanvasSession`, and expect
   `canvasSessionExpired false -> true` in `debugRenewalLogV1` and a
   renewal in that launch.

**Rebuilt from this tip on 2026-10-27**, both exit 0 with no `error:`
lines, both 3.2.2 (16), AlarmKit weak in the archive's app binary: the
Debug device app at the same path as above (16:46 UTC) and the Release
archive at `build/Smooth.xcarchive` (16:48 UTC; the earlier archive was
replaced). The install commands above are unchanged. The archive was
built with the tree at `9350b2a`; `d4c1d78` after it changes a test and
CLAUDE.md only, so the binary is the branch tip's.

Still not done: reading one real crash report (step 2), the upload, and
A4 onward of the hardening plan.

## A second crash, read off Marco's phone (2026-10-27)

Five reports, builds 12 to 14 (2026-10-19 to 10-26): every tap on a
notification aborted the app (`SIGABRT`). The stack, in one line: the async
`NotificationResponseDelegate.userNotificationCenter(_:didReceive:)` thunk
calls iOS's completion handler on a cooperative-pool thread, and
`_updateSnapshotAndStateRestorationWithAction` asserts it is on the main
thread. This is unrelated to the duplicate-key trap. It is fixed on
`release/3.3.1` in `NotificationResponseRouter.swift` (completion-handler
form, completion called from a `@MainActor` task). The duplicate-key crash is
still unproven by any report. (Proven the next morning; see the section
below.)

## Proven: the App Store crash reports (2026-10-28, morning)

With an Apple ID signed into Xcode, Organizer → Crashes for Smooth listed
eight crash groups for the last two weeks (read 2026-10-28, about 15:00
UTC). Every one of them is a crash this branch already knows:

| Group (Organizer's label) | Devices | Binary | What it is |
|---|---|---|---|
| `Smooth: specialized _NativeDictionary.init(capacity:)` | 6 | 3.2.1 (15), 100% | **The launch crash.** `_assertionFailure` ← `_NativeDictionary.merge(isUnique:uniquingKeysWith:)` ← `Dictionary.init(uniqueKeysWithValues:)` ← `GradeRegrouper.apply(_:to:)` ← `GradeEngine.compute` ← `GradeWatcherStore.breakdown` ← `recordHistory` ← `refresh` ← `AppState.refreshGradeWatcher` ← `AutoSyncCoordinator.refreshCanvasGrades` ← `ContentView.fetchSessionSources` ← `refreshSessionSourcesAtLaunch`. Exactly the chain in "The cause" above. The trapping site is `GradeRegrouper.swift:39` of `4fe7a4f`; on this branch both of that file's dictionaries are first-wins. |
| `UIKitCore: -[UIApplication _perfor…]` | 4 | 3.0.1–3.2.x | **The notification-tap crash.** `_updateStateRestorationArchive` / `_updateSnapshotAndStateRestoration…` ← `@objc closure #1 in NotificationResponseDelegate.userNotificationCenter(_:didReceive:)` ← `completeTaskWithClosure(swift::AsyncContext…)`. Fixed in `fc74fee`. |
| `UIKitCore: -[UIApplication _perfor…]` (second group) | 2 | | Same stack as the row above. |
| `libswift_Concurrency.dylib: _swift_task_ch…` | 2 | 3.0.0 (11) | **The background-refresh crash** (CLAUDE.md → the background-refresh trap): `_swift_task_checkIsolatedSwift` ← `closure #1 in LHFBackgroundRefresh.register()` ← `BGTaskScheduler _runTask`. Known, unfixed on purpose, and 3.0.0 is below the floor. |
| `AttributeGraph: AG::swift::metadata::…` | 1 | 3.0.0 | Same background-refresh stack. |
| `BoardServices: +[BSXPCServiceConne…]` | 1 | 3.0.0 | Same background-refresh stack. |
| `libdispatch.dylib: _dispatch_thread_m…` | 1 | 2.0.1 / 3.0.0 | Same background-refresh stack. |
| `Smooth: NO_CRASH_STACK` | 1 | 3.0.0 | Same background-refresh stack on the crashed thread. |

So there is no third cause. 3.3.0 (16) had no reports yet (live for
under a day). The honest caveats above ("proven from the code, not yet
from a crash report") are closed by this table.
