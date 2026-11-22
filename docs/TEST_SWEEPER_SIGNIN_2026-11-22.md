# Sweeper and sign-in: hostile test pass, 2026-11-22

Branch `claude/test-sweeper-signin-1cb733`, cut from the release line
`claude/ambassador-header` at `c694ce7` (the force-quit merge), the night
before 3.5.0 (21) was to be reviewed and shipped. Scope: the week's Sweeper
accuracy work (cancel at observation, `SubmissionRead`, the last-hour poll,
buzz-only delivery), the Duo work of 2026-11-21/22 (the trust renewal, the
missed-push notice, the warmed cookie jar) and the merged force-quit check
(the notification extension, the cookie copy, the handoff). No phone was
available, so nothing here ran on a device; everything below ran on Marco's
Mac in filtered `swift test --no-parallel` runs. `CanvasSessionRenewer.swift`
and `LoginNavigationObserver.swift` were being edited by another session and
were read only; findings about them are reported, not fixed.

## Summary

- **Findings:** 1 high, 2 medium, 5 low, 6 info. The high, one medium and two
  lows are fixed on this branch; the rest are listed with their one-line fix.
- **New tests:** 25 `@Test` functions in 8 suites, one file
  (`SweeperSignInTestPassTests.swift`), several parameterized. The three H1
  tests were run against the old rule and fail there (9 issues), so they
  pin the finding and not the fixture.
- **Existing suites re-run after the fixes:** 267 tests / 29 suites, green
  (every suite that touches `SubmissionRead`, the planner apply, the handoff,
  the status line, the renewal outcomes and the wake bodies).
- **Not covered:** anything on a phone or against real Canvas, the extension
  process itself (iOS only; its decision table `SweepCheck` is what the Kit
  tests drive), and whether Canvas's planner really omits
  `plannable.assignment_id` for a plain assignment (H1 is fixed either way:
  the new rule reads `plannable_id` first and falls back to the field).

The invariants held wherever they could be reached: no path cancels an alarm
or a buzz on anything but a `.submitted` verdict; an incomplete, rate-limited
or expired planner page cancels nothing in the poll, the push wake or the
extension; no trace line in the files under test carries a title, an id, a
URL or a cookie; a forced Duo-trust attempt that reaches Duo, the login page,
a timeout, a refusal or an abort latches nothing and disables nothing.

## Findings

| # | Severity | Finding | Evidence | Fixed |
|---|---|---|---|---|
| H1 | High | **A plain assignment's planner row produced no read, so the poll, the push wake and the extension could never cancel its alarm.** `SubmissionRead.verdicts` keyed a read on `plannable.assignment_id` alone. That field is a quiz's or a graded discussion's pointer to the assignment that backs it; the full structured run (`CanvasStructuredSourcesReconciler`, the planner switch) keys a `plannable_type == "assignment"` row by `plannable_id`, and nothing else in the app relies on `assignment_id` being present for an assignment. A student who hands in a problem set inside the last hour would have had the poll read the window every minute, find the row, make no read of it, count nothing, and the alarm would ring; the push wake and the force-quit extension share the function and would do the same. Only the grades fetch (15-minute throttle) could cancel. Every existing fixture put `assignment_id` inside `plannable` for assignments too, which is why 4,375 tests were green over it. | `SubmissionRead.swift:65` (old). `TestPassPlannerIDTests` (5), `TestPassPlannerApplyTests` (2): run against the old rule, 3 tests fail with 9 issues (`reads.count → 0`, the extension's `alarmIDsToCancel → []`, the applier's canceller never called). | Yes: `SubmissionRead.canvasAssignmentID(of:)` resolves a plain assignment by `plannable_id` (falling back to the field) and every other type by `plannable.assignment_id`; a quiz's own id is never used (another id space). The applier, the push wake and the extension all go through `verdicts`, so one change covers the three. |
| M1 | Medium | **The live cookie read never warmed the store, so a cold process saw only the clock-gated persisted jar.** `AutoSyncCoordinator.canvasCookies(forHost:)` asked `LoginDataStores.canvas.httpCookieStore` for all cookies without attaching a web view first; WebKit loads a non-default store's jar lazily, so in a process that has not yet shown a web view the live half is empty (the 2026-11-22 trap, seen on Marco's phone for the Duo cookies). The persisted half is `SessionCookieStore.load`, which the 24-hour rule empties a day after the last save. Readers that run in a cold process: the background and push wakes' planner read and grades fetch, the launch pass's poll (`refreshSessionSourcesAtLaunch` runs before the dashboard's first `refreshDuoRememberSummary`, which was the only warm). The 2026-11-21 poll fix moved the guard onto this read on the strength of the live half being present; in a cold wake it is not. | `AutoSyncCoordinator.swift:157`. `TestPassCookieWarmTests` (2): the warm precedes `getAllCookies` in the function body; the warm is inert under the test runner. | Yes: `LoginDataStores.warmCanvasStore()` is the first statement of `canvasCookies(forHost:)`, a no-op after the first call and under tests. |
| M2 | Medium | **The push wake's own gate reads only the persisted jar.** `runPush` guards on `state.hasCanvasCredentials && !SessionCookieStore.isExpired(service: .canvas)`, both the clock-gated Keychain copy, before it ever reaches `pollPlannerWindow`, whose `fetchPlannerWindowForPoll` already applies the right rule (the live-merged jar first) and already counts and logs a no-session read. A day after the last save the push wake answers `pushNoSession` over a session WebKit still holds, the exact shape of the 2026-11-21 poll fault. With M1 the live half is now readable in a cold process, so dropping the gate makes the wake correct; keeping it makes M1 useless for the push. | `BackgroundRefresh.swift`, `runPush`, the `guard state.hasCanvasCredentials, !SessionCookieStore.isExpired(service: .canvas)` block; `PushWakeTests` pins the gate's presence by source scan. | No (iOS-only file, read only in this pass). One-line fix: drop the guard and let `fetchPlannerWindowForPoll`'s nil answer be the no-session case (it counts `readsUnknown` and writes "planner no-session"), or guard on `await AutoSyncCoordinator.canvasCookies(forHost:)` being empty. `PushWakeTests` line 31 then changes with it. |
| L1 | Low | **A forced Duo-trust renewal showed "slow connection · reconnecting".** `canvasSessionStatusLine` returned `.reconnecting` for any in-flight renewal older than 3 s. The weekly forced sign-in (`renewDuoTrustIfDue`) runs over a live session for 6 to 27 s (Marco's phone, 2026-11-22), so every week the dashboard would have said the connection was slow while nothing was being reconnected. | `AppState.swift`, the pure rule and `startSilentCanvasRenewal`. `TestPassForcedStatusLineTests` (3). | Yes: `silentRenewalIsForced` is set with the attempt and cleared with it; the rule takes `forcedRenewal:` and skips `.reconnecting` for it. A push the forced attempt sent still shows "approve the duo push on this phone", because that one is the student's to answer. |
| L2 | Low | **The Sweeper's copy of the Canvas cookies was kept with nothing armed.** `writeSweepHandoff` saved the Keychain copy whenever the wake's gates passed, an empty plan included, so the second copy of the login outlived the last alarm until reminders or Canvas were switched off. The file's own comment says a copy is not kept without a consumer; with no alarm there is no push and no consumer. | `AppState+SweepHandoff.swift`, the save after the manifest. `TestPassEmptyHandoffTests` (2): an empty plan deletes the manifest; the empty-plan guard also deletes the copy (source, since the Keychain call is inert under tests). | Yes: an empty entry list deletes the manifest and the copy and returns; the next pass that arms an alarm writes both. `docs/PRIVACY.md`'s promise ("deleted when you disconnect Canvas") is unchanged and still true; the copy now also goes whenever nothing is armed. |
| L3 | Low | **The manifest goes stale between foreground passes.** It is written from `sweeperWakePass` (a refresh pass) and not from the reschedule a swipe triggers, so a card the student finished in Smooth stays listed. The extension then finds it near its ring time, reads the planner, and writes "PS7 · not turned in yet" as a passive line for work the student marked done (or, if the planner says submitted, cancels alarm ids that no longer exist, which is harmless). | `AppState+SweepHandoff.swift` (one writer), `NotificationScheduler.reschedule` (no call). Read from the code. | No. One-line fix: have the extension skip an entry none of whose `alarmIDs` AlarmKit still holds and none of whose `requestIDs` is pending (it already reads `AlarmManager.shared.alarms` to cancel), or call `writeSweepHandoff` from the reschedule pass. |
| L4 | Low | **`debugRenewalLogV1` carries a URL path.** `CanvasSessionRenewer`'s failed-navigation line records `webView.url?.host` and `webView.url?.path` ("navigation failed: <host> <path> <domain>/<code>"). CLAUDE.md says that log never holds "a cookie, URL or credential"; a host plus a path is a URL less its scheme, and a Canvas path can name a course or an assignment. DEBUG only, and read off the phone only by the owners, so low. | `CanvasSessionRenewer.swift:1528`. `TestPassTraceTests` scans the seven files under test and found nothing there; this file was out of scope for edits. | No (excluded file). One-line fix: log the host alone, or a fixed word per host class (penn, duo, canvas, other) and the error code. |
| L5 | Low | **An aborted forced attempt spends the week.** `performSilentCanvasRenewal` stamps `duoTrustRenewalAttemptAtKey` for every forced outcome but `.notAttempted`, so an attempt the login pane aborted, or one whose account generation changed under it, counts as the week's attempt. Harmless in both cases today (an interactive login re-issues the trust itself; a switched account has a new trust), so left alone. | `AppState.swift`, the `if forceReauthentication { if case .notAttempted = outcome {} else {...} }` block. | No. One-line fix: exclude `.abortedByLoginPane` too. |
| I1 | Info | The extension's `alarmNote` can carry AlarmKit error descriptions, which may include alarm UUIDs. Those are SHA-256-derived alarm ids, not assignment ids or titles, and the line is written only in DEBUG. | `NotificationService.swift`, `cancelAlarms`. | Not a bug. |
| I2 | Info | **`DuoWaitNotice` races.** A refresh pass and a background wake both call `postDuoWaitNoticeIfDue` on the same main-actor `AppState`; the latch date is recorded before the `await` and rolled back only when nothing was posted, so two callers post once. The notice's `shouldPost` refuses a live session, a future latch, a latch under an hour and a latch already posted for. Disconnect reaches `latchCleared()` through `disableStayLoggedIn`. | `TestPassUnchangedRulesTests.noticeGuards`; `DuoWaitNoticeTests` already pins the rest. | Not a bug. |
| I3 | Info | **The forced attempt and the hand-off to the Canvas Student app.** On Marco's phone the one forced attempt ended `landedOnLoginPage` through `WebKitErrorDomain/102` on the hop back to Canvas and the app left the foreground in the same second (Known gaps). The hidden renewer has no app-link guard; the other session is adding one. Two things to read off the phone after it lands: whether the forced flow's `force_login=1` made Canvas rotate the live session cookie (if so the persisted copy is stale until the next 401 starts an ordinary renewal; a 401 is an unknown read, so the Sweeper is not at risk), and whether the warm web view from M1 changes WebKit's app-link decision for the hidden renewer (it should not: a programmatic load is never a candidate). | Known gaps, the Duo trust entry. | For the other session. |
| I4 | Info | **Cookie copy lifetime against `docs/PRIVACY.md`.** Written only from a foreground pass while the wake's gates pass (Penn, backend, flag, token, reminders and Sweeper on); deleted by `SessionCookieStore.clear()` and `remove(.canvas)` (disconnect, the reconnect purge, account deletion through disconnect), by a pass whose gates fail, and now by a pass with nothing armed. Not deleted by deleting the app, which PRIVACY says of every Keychain item. The copy is at most as fresh as the last foreground pass, so at ring time it is often dead; the extension then reads `sessionExpired` and the alarm rings, which is the floor the design names. The host filter keeps the Canvas host's and its parent domain's cookies and drops Duo's, the identity provider's and `sso.canvaslms.com`. | `TestPassUnchangedRulesTests.mirrorScope`; `SweeperForceQuitKitTests` already pins the codec. | Promise holds. |
| I5 | Info | **The extension on an expired session or a half page.** A 401 sets `sessionExpired`, a cut-off page clears `completed`, a 403 sets `rateLimited`; in every case `reads` stays nil, `SweepCheck.decide` marks every entry unknown, cancels nothing, removes nothing, writes no inbox record and leaves the server's generic text. A row the planner did not list is unknown too. | `TestPassHostilePlannerTests.duplicateRows` (the nil case); `SweeperForceQuitKitTests` "nil reads make everything unknown". | Holds. |
| I6 | Info | **Other sessions were testing on this Mac during the pass.** `pgrep` showed six `swift test` invocations from the `release-review-3766d5` worktree while mine ran. Two runs at once share one defaults domain (CLAUDE.md, the shared-defaults trap); every new test here uses a scratch suite or `disablePersistenceForTesting`, and all runs were green, but none of tonight's counts is a baseline for the full suite. | `pgrep -fl swift`, 20:45 local. | Flagged. |

## What was hunted, and the result

### A read that is not a confirmed submission cancelling something

Every cancel path was traced to its verdict. The grades fetch cancels
`observedSubmitted` minus the previous set, where `indicatesSubmitted` is
`submitted_at` or a `submitted`/`pending_review` workflow state and never
`graded` or `missing`; the deadline-passed auto-set is folded into the
persisted ids but deliberately not into the cancel. The structured run
cancels only completions whose module requirement type means done
(`must_submit`, `must_mark_done`, `min_score`, `must_contribute`) and planner
`submitted`/`marked_complete`. Gradescope cancels rows whose `submitted` went
true in this read, after `preservingUnverifiedSubmissions`. The poll's applier
and the extension share `SubmissionRead.verdicts`, which answers `.submitted`
for `submitted == true`, a Planner tick or `excused == true`, and `.unknown`
for a missing flag; both refuse an incomplete page outright. Hostile shapes
(`"submitted":"true"`, `1`, `null`, an array, an object, `"excused":"true"`,
a `submissions` that is `null`, `[]`, `true` or a string, an override with
`"marked_complete":"true"`) all decode to unknown
(`TestPassHostilePlannerTests`, 19 parameter cases). Ids of the wrong kind
(`55.5`, `-55`, `""`, `true`, `"55 "`, a quiz with `assignment_id: true` or
`1e300`) never resolve onto `"55"`. A page that is not an array, or has junk
among its rows, yields no false read. Two rows for one assignment: the
submitted one wins in `SweepCheck`, as it does in the applier (Canvas does
list an assignment twice under section overrides). **The one real hole was
H1**, in the other direction: a true submission that produced no read.

### An item that should ring going quiet by accident

`SweeperSettings.quietReason` has six reasons, none of which a default
reaches: `requiresNoSubmission`, `submitsOnPaper` and `isExternalTool` on
`DashItem` default to false, so an item the grades fetch has not listed yet
is armed, not quiet; a `.canvasModules` row with no Canvas id is buzz-only,
not quiet; a found exam, a recurring occurrence and a class switched off are
the owner's rules. `nextSweep` and `plannedAlarms` share `qualifies`.
`SubmissionObservation.ids` enumerates every lead time and sound, so a
changed setting never leaves an orphan alarm uncancelled (and the manifest
adds the planned alarm's own id on top). `vm.items` keeps completed items
(prev), so the canceller still finds a just-completed card's due date after
the rebuild. The poller stops only on `.background` and is restarted by
every refresh pass; a nil read backs it off five minutes and counts nothing
(`TestPassUnchangedRulesTests.nilReadBacksOff`). Nothing new found here
beyond H1 and M1.

### The forced Duo attempt

`shouldRenewDuoTrust` refuses a dead or missing trust, an expired session,
a Duo wait, a rejected password, an attempt in flight, the login pane, an
attempt inside a week, a password inside ten minutes and a failed one inside
an hour (`DuoTrustRenewalTests` already pins the table).
`applyRenewalOutcome(forced:)` returns before any latch for `.needsDuo` and
`.landedOnLoginPage`; `.timedOut`, `.notAttempted` and `.abortedByLoginPane`
go through the ordinary path, which latches nothing for them either
(`TestPassUnchangedRulesTests.forcedOtherOutcomes`). The once-per-open Duo
retry is not spent (`madeForegroundRenewalThisProcess` is set only for
unforced attempts) and `duoRetryGrantedForThisAttempt` is false by
construction (`awaitingDuo` must be false to start). `.passwordRejected`
disables the password as for any attempt: real evidence, by design, with the
standing caveat that `credentialErrorWords` is a guess until the identity
provider's error element is captured (CLAUDE.md, Known gaps). What a forced
attempt did change wrongly was the dashboard's words (L1).

### The cookie jar in a cold process

`refreshDuoRememberSummary` warmed the store since `6e2f123`; nothing else
did (M1). Twelve readers go through `canvasCookies(forHost:)`; the renewer
reads the store itself but builds a web view in the same attempt; the Ed
launcher, the Path portal and the onboarding pane all have a web view on
screen. M1 is the one gap.

### The extension and the handoff

Read through `NotificationService.check`: a missing manifest, no entries
near now, no cookies, a failed or incomplete read and an unknown outcome each
leave the original content and cancel nothing; only `outcome.submitted`
cancels, removes and appends. `cancelAlarms` cancels only ids AlarmKit holds
(or every id when the list itself cannot be read, so a refusal still shows).
`serviceExtensionTimeWillExpire` and the check deliver through one
`OnceDeliverer`. The inbox fold goes through `applyPlannerWindow`, so the
student's un-tick override and the twin rules hold, and a DEBUG probe record
(no Canvas id) is skipped. The manifest window, the inbox drain's rename and
the codec are pinned by `SweeperForceQuitKitTests`. Found: L2 and L3.

### Traces

`TestPassTraceTests` gathers every `DebugWakeLog.record(`,
`DebugRenewalLog.record(`, `SweepDebugLog.append(`, `log("` and `print(`
statement (multi-line calls included) in `LastHourPoller.swift`,
`AppState+LastHourPoll.swift`, `AppState+SweepHandoff.swift`,
`AppState+SweeperWake.swift`, `DuoWaitNotice.swift`, `BackgroundRefresh.swift`
and `LHFSweeperCheck/NotificationService.swift`, and refuses `title`,
`canvasAssignmentID`, `itemID`, `.url`, `URL(`, `cookies[`, `.value`,
`assignmentID:`, `manifest.canvasBaseURL`, `\(id)` and `\(ids`. All clean.
The Duo trust check's lines are the fixed refusal words plus day counts. The
one line outside those files that carries part of a URL is L4.

## Not fixed, by design or out of scope

- A student's un-tick in Smooth over a Canvas submission keeps the alarm
  armed (`structuredCompletionOverrides` wins in the applier). Documented
  behaviour: the student said it is not done.
- A `.canvasAnnouncement` task, a syllabus exam and a manual task have no
  Canvas id and can never be confirmed; they ring unless swiped. Marco's
  rule: silence is the dangerous side.
- The extension's `UNUserNotificationCenter.current()` removing the app's
  pending requests, and an extension cancelling an AlarmKit alarm at all, are
  unproven and need the device test in Known gaps.

## Changes on this branch

- `LowHangingFruitKit/Sources/LowHangingFruitKit/Alarms/SubmissionRead.swift`:
  `canvasAssignmentID(of:)`, used by `verdicts` (H1).
- `LowHangingFruitKit/Sources/LowHangingFruitUI/AutoSyncCoordinator.swift`:
  `canvasCookies(forHost:)` warms the store first (M1).
- `LowHangingFruitKit/Sources/LowHangingFruitUI/AppState.swift`:
  `silentRenewalIsForced`, the `forcedRenewal:` input of
  `canvasSessionStatusLine` (L1).
- `LowHangingFruitKit/Sources/LowHangingFruitUI/AppState+SweepHandoff.swift`:
  an empty plan deletes the manifest and the cookie copy (L2).
- `LowHangingFruitKit/Tests/LowHangingFruitKitTests/SweeperSignInTestPassTests.swift`:
  the 25 tests.
- `CLAUDE.md`: a Traps entry for H1 and the Test baseline line.
- This report.

## Final gates

All on Marco's Mac, 2026-11-22 (evening of 2026-11-21 US Eastern), on this
branch's final tree, with other sessions' filtered runs on the machine
(I6):

- `swift test --no-parallel --filter TestPass`: **25 tests / 8 suites, all
  green** (0.37 s of tests).
- The same filter against the old `SubmissionRead` rule (the fix reverted in
  place, then restored): 3 tests red with 9 issues, the rest green.
- `swift test --no-parallel --filter` of the 20 existing suites that touch
  the changed files (`SubmissionReadTests`, `PlannerWindowApplyTests`,
  `PlannerWindowClientTests`, `SweepHandoffTests`, `SweeperWakePassTests`,
  `SilentRenewalCoreTests`, `LastHourPollerWiringTests`, `LastHourPollerTests`,
  `SweeperForceQuitKitTests`, `DuoTrustRenewalTests`, `DuoWaitNoticeTests`,
  `PushWakeTests`, `CancelAtObservationTests`, `SubmissionObservationTests`,
  `StructuredSourcesWiringTests`, `CanvasStructuredSourcesTests`,
  `LaunchRefreshStructureTests`, `BackgroundWakeReplanTests`,
  `StayLoggedInTests`, `SignInHealthTests`): **267 tests / 29 suites, all
  green** (4.9 s).
- Unsigned iOS Debug build (`generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`,
  its own DerivedData): **BUILD SUCCEEDED**, the compile of `AppState.swift` and
  `AutoSyncCoordinator.swift` inside the app target (the Kit change compiles in
  both; the extension target was not touched).
- The full suite was not run here (the master session's); the predicted count
  is the line's 4375 / 441 plus 25 / 8.

Not covered: anything on a phone, anything against real Canvas, the push
backend (not deployed), and the extension as a running process.
