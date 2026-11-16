# The Sweeper rings only when it should: the build plan

Written 2026-11-16, planning only: no app or backend code changed, nothing
deployed, nothing on a phone. This is the brief a build session is handed.
It replaces `docs/REMINDER_SUBMISSION_FIX_SESSION_PROMPT.md` (2026-11-04,
whose four parts it keeps, reordered and widened) and it rests on
`docs/SWEEPER_STATUS_RESEARCH_2026-11-16.md`, which is where every claim
about iOS, APNs and Canvas below was read from and sourced; this document
does not repeat the citations. Read `CLAUDE.md` and `ROADMAP.md` first,
then this, then the research where a "why" is not enough.

**The decision this plan rests on.** Marco, 2026-11-16, after reading the
research's one question ("May the server hold, per install, an APNs device
token and the minutes at which that install wants to be woken?"): "Yes,
plan it." So the server may hold a device token and ring minutes per
install, and nothing else: no course, no work, no session, no submission
state. Everything in Release 2 is bounded by that sentence.

**Standing rules, restated so the build session need not hunt for them.**
The server never holds a student's Canvas or Gradescope session or password.
The alarm's stop never means turned in; only the "turned in" button does.
The ledger never deletes. The copy rule is the least text that works. A
privacy-relevant behaviour goes into `docs/PRIVACY.md` in the same commit as
the behaviour. CLAUDE.md and ROADMAP.md are updated with the work they
describe, in the same commit. Olisa's sync and Ed code are not touched
(`AutoSyncCoordinator`'s course-knowledge and Ed paths,
`CourseKnowledgeCollector`). A change that has not been compiled is not
done; a change that has not been on Marco's phone is not verified.

Paths: `LUI/` is `LowHangingFruitKit/Sources/LowHangingFruitUI/`, `LK/` is
`LowHangingFruitKit/Sources/LowHangingFruitKit/`. Line numbers are from the
tree of 2026-11-16 (`6a2a488`) and will drift; the symbols will not.

## 0. The problem and the shape of the answer

On 2026-11-03 Marco submitted an assignment on Canvas and about fifteen
minutes later Smooth reminded him it was due. The loud alarm has the same
flaw and a louder consequence. Reminders and the Sweeper are planned days
ahead at every refresh from the ledger's not-done cards
(`NotificationScheduler.reschedule`, `plannedAlarms`, `loudAlerts`,
`SweeperSettings.qualifies`), and handed to iOS as local notifications and,
on iOS 26, an AlarmKit alarm. They ring whether or not the app is running.
The only thing that unsets one is a replan after a read has seen the
submission: the Canvas grades fetch (`AutoSyncCoordinator.refreshCanvasGrades`,
at most every 15 minutes, foreground) or the structured-sources run (the
planner's `submitted` flag, same cadence), followed by `settleAfterFetch`'s
`reschedule`. So a submission inside about 20 minutes of a ring, or any
submission while the app is closed, cannot stop it.

The research settled what cannot be built: nothing of ours runs at the
moment an alarm fires, so the ring can never be gated at ring time. What
can be built is the reverse, in two releases.

**Release 1, on the phone only.** Never arm the Sweeper until a read inside
the last hour has confirmed the item unsubmitted; cancel it the moment any
later read says otherwise; read as often as iOS allows while the app is
open, and prove how often it lets us read when it is not. Four phases, each
shipping alone, each ending the 2026-11-03 case a little more completely.
Nothing new leaves the phone, so `docs/PRIVACY.md` does not change.

**Release 2, the server as a timer.** The phone tells the server "wake me at
these minutes"; the server sends a silent push at each; the phone wakes for
about thirty seconds, reads the planner, and cancels or keeps its alarm.
Best effort by Apple's own words, never after a force-quit, and the only
way to reach a closed app at all. One key from Olisa, one short paragraph
in `docs/PRIVACY.md`, one table.

**The wrong fix, named once here and not again:** arming the alarm days ahead
and trying to cancel it in time. Cancelling needs our process, and iOS lends
it to a closed app rarely and never at a minute of our choosing. Every phase
below moves the decision to *arming*, where our process is certain to be
running, and treats every later chance to read as a bonus.

## 1. Release 1: the phone alone

### Phase 1. Cancel at observation

**What.** The moment any read marks an item submitted, its pending
notification requests and its AlarmKit alarm are taken back then, and a
ringing alarm for it is stopped; not at the next full replan.

**Why.** Today `updateSubmissionState` (`LUI/AppState.swift:9517`) rebuilds
`submittedCanvasAssignmentIDs`, writes `canvasSubmitted` through
`AssignmentStore.applySubmissionState` (`LK/Persistence/AssignmentStore.swift:1268`)
and rebuilds the dashboard; the removal happens later in the same pass,
when `ContentView.settleAfterFetch` (`LUI/ContentView.swift:1100`) calls
`scheduler.reschedule(from: vm.items)` and `applyNotifications`
(`LUI/BerserkAlarmDelivery.swift:297`) diffs the pending ids against the new
plan. Between the observation and that diff sit the rest of the fetch
chain and a view-model reload; and the background wake's `replan`
(`LUI/BackgroundRefresh.swift:267`) can be cut off by its 30-second budget
before it reaches the alarm. Cancelling at the observation closes that
window to nothing and makes the later diff a backstop rather than the
mechanism.

**The pure rule to extract and test first.**
`SubmissionObservation.cancellations(newlySubmitted: Set<String>, items: [DashItem], settings: SweeperSettings) -> (requestIDs: [String], alarmIDs: [UUID])`
in a new `LUI/SubmissionObservation.swift` (or in `LK/Alarms/` if it needs
nothing from `DashItem`): given the ids a read has just seen go to
submitted, return exactly the `due:<assignment id>:<offset>` request ids
(the shape `NotificationScheduler.plannedRequests` builds; read the
prefix from the scheduler, never re-type it) and the alarm ids
`BerserkAlarmPlan.alarmID(assignmentID:fireDate:sound:)` for every
(minutes, sound) the Sweeper can resolve to (the enumeration
`BerserkAlarmDelivery.applyReminders` already does over
`sweeperMinuteOptions` and `SweeperSound.allCases` to find finished alarms,
`LUI/BerserkAlarmDelivery.swift:232`). Items that are a hidden twin or a
`linkedID` of the submitted one count too (`shownAssignment(forItemID:)`
is the lookup `completeAfterAgentSubmit` uses). Nothing else's ids may
appear in the answer; that is the test.

**Where it is called.** Three observation points, each a few lines:
`updateSubmissionState` after `observedSubmitted` is known (the set the
"turned in" notices already diff from); `applyStructuredSources`
(`LUI/AppState+StructuredSources.swift:181`) when a planner item's
`submitted` flag adds an id to `structuredCompletedItemIDs`; and the
Gradescope path where `gradescopeSubmitted` flips to true inside
`syncGradescope` (`LUI/AppState.swift:5669`; read the exact write site
before touching it, and touch only the hook, not the scrape). Each hands
the ids to the scheduler through a new `NotificationScheduler.cancelForSubmitted(_:)`
that calls `sink.removePending(identifiers:)` and
`activeAlarmBackend()?.stopRinging(among:)` plus `cancel(id:)` for idle
ones, inside the `RescheduleSerializer` so it cannot interleave with a pass.
`AppState` reaches the scheduler the way `disconnectCanvas` does, through
`reminderReplanner` (`LUI/ContentView.swift:278`): add a sibling closure,
`submissionCanceller`, bound beside it. The background wake binds its own
scheduler in `run()`; give it the same closure.

**Acceptance.** A test feeds one submission observation into a scheduler
with a fake `PendingNotificationSink` and a fake `BerserkAlarmBackend` and
asserts removal was called with exactly that item's request ids and alarm
ids and nothing else; a second test observes two ids and asserts both
sets and no third; a third asserts a submitted item that is the hidden twin
of a shown card cancels the shown card's ids. The ledger invariant tests
are unchanged. Nothing is added to the ledger: this touches notifications,
not storage. `swift test --no-parallel` green; the count rises by the new
tests and falls by none.

**Device check.** Debug build on Marco's iPhone, an item due within the
hour with an alarm set (read the Sweeper page's countdown), submit it on
canvas.upenn.edu with Smooth open; the alarm's countdown card disappears
at the next 5-minute tick without waiting for the 15-minute grades
throttle only if Phase 2 is in; with Phase 1 alone the check is that once
the fetch *does* see it, the alarm is gone before the dashboard reloads,
which the DEBUG log line below shows as `cancel-at-observation 1 request(s)
1 alarm(s)` ahead of `reminder pass`.

**CLAUDE.md and ROADMAP.md lines.** What the app does → Profile → reminders:
one sentence that a read which sees a submission cancels that item's alarm
and buzzes at once, the replan being the backstop since <date>. Known gaps
→ "Turned-in state": strike "the replan that removes the request happens
later in the same pass". ROADMAP → Done recently: the phase, the date, the
test count.

**What must not change.** The alarm's stop button still opens the page and
marks nothing. `markCompleted` is not called from here: a Canvas-observed
submission is already written as `canvasSubmitted`, and a completion
written by the phone on Canvas's word is the trap CLAUDE.md records under
"Canvas-derived completions … are not student edits". The ledger is only
read.

### Phase 2. A planner poll every minute inside the last hour

**What.** While the app is in the foreground and any armed alarm's ring
time (or any qualifying item's due time) is inside the next 60 minutes,
read `planner/items` once a minute with the student's session and feed
each answer through Phase 1's hook. Outside the hour, nothing new: the
5-minute tick and the 15-minute grades throttle stay as they are.

**The call, exactly.**
`GET https://canvas.upenn.edu/api/v1/planner/items?start_date=<now-1h ISO8601>&end_date=<now+1h ISO8601>&per_page=100`
with the Keychain's Canvas cookies, no CSRF header (a GET), the same request
`CanvasStructuredSourcesClient.fetch` already builds for a 134-day window
(`LK/Canvas/CanvasStructuredSourcesClient.swift:112`). Fields read:
`plannable_type`, `plannable_id`, `plannable.assignment_id` (a quiz's backing
assignment, the id a feed row carries), `plannable.due_at`, `course_id`,
`submissions.submitted` (the source builds it as `submission&.has_submission?`),
`submissions.missing`, `submissions.graded`, `planner_override.marked_complete`;
all already decoded by `CanvasPlannerItem` (`LK/Canvas/CanvasStructuredSources.swift:73`).
A two-hour window returns a page or less, so the cost is one request a
minute per student, every course at once, no per-course fan-out. The
research's measure: Canvas's leaky bucket leaks ten a second, so this is
two orders of magnitude under the leak; the cost Canvas charges per request
is not published, so **read `X-Rate-Limit-Remaining` and `X-Request-Cost` off
the first real response on a phone and write the numbers into CLAUDE.md**.
The client already reads the remaining header and stops under
`rateLimitFloor` (50) or on a 403 whose body says "Rate Limit Exceeded"
(`:256`, `:298`); the poll inherits that and adds its own rule: a 403 or a
remaining value under 100 backs the poll off to the 5-minute tick for the
rest of the hour and counts it (§4). If Penn's deployment hides the header
for cookie requests (the research could not tell), the 403 rule alone
applies, and a note goes into CLAUDE.md saying so.

**Why the planner and not the per-course submissions call.** The old brief
left the choice open ("whichever is lighter after measuring"). The research
settled it: `planner/items` is the one call that covers every course, it is
already decoded and already consulted for Planner ticks, and a student with
five classes would otherwise make five calls a minute. `courses/:id/students/submissions`
stays as the per-course heavy read the grades fetch uses.

**The pure rule to extract and test first.**
`LastHourPoll.cadence(now: Date, nextRing: Date?, nextDue: Date?, lastPoll: Date?, backedOffUntil: Date?) -> PollDecision` (`.poll`, `.wait(until:)`, `.idle`) in
`LK/Alarms/LastHourPoll.swift`: inside the hour and a minute since the last
poll, `.poll`; inside the hour but under a minute, `.wait`; outside the
hour, `.idle`; under a back-off, `.wait(until: backedOffUntil)`. The "next
ring" comes from `SweeperSettings.nextSweep` (`LUI/SweeperPlan.swift`), which
the Sweeper page already uses, so the poll and the countdown card agree on
what is coming. A second rule, `LastHourPoll.window(now:) -> (start, end)`,
pins the two-hour window.

**Where it runs.** A new small coordinator, `LastHourPoller` (`LUI/`), owned
by `ContentView` beside the 5-minute loop, started on scene active and
stopped on background: each tick asks the cadence rule, and on `.poll` calls
a new `CanvasStructuredSourcesClient.fetchPlannerWindow(start:end:)` (the
planner leg of `fetch` factored out, nothing else in that client changed)
and hands the items to `AppState.applyPlannerWindow(_:)`, which applies only
the `submitted` and `marked_complete` signals through the same additive set
`applyStructuredSources` writes (`structuredCompletedItemIDs`) and then
Phase 1's cancel hook. It does not touch dismissals, section dates or
module rows: a partial read must never retire anything, which is the rule
`applyStructuredSources` already keeps for an incomplete planner run. It is
exempt from `canvasGradesMinInterval` because it never calls the grades
fetch at all. The 15-minute throttle on `refreshCanvasGrades` is untouched.

**Acceptance.** Tests: the cadence tightens to one minute inside the hour
and relaxes to idle outside it; a back-off is honoured and expires; the
window is two hours around now; an answer with `submitted: true` for a
planner item whose `assignment_id` matches a card produces exactly that
card's cancellation (Phase 1's rule, driven end to end with a canned run
through `structuredSourcesRunForTesting`); an answer that is rate-limited
changes no state and records the back-off. Device check: Smooth open in the
foreground, an item due in 40 minutes, submit on canvas.upenn.edu; the
Sweeper page's countdown card and the pending reminder are gone within two
minutes (read the DEBUG log, no screenshot needed), and the first response's
rate-limit headers are written down.

**CLAUDE.md and ROADMAP.md lines.** What the app does → Background: the
last-hour poll, its cadence, its endpoint, its back-off, foreground only.
Commands: the DEBUG line to read. Known gaps → "Turned-in state": strike the
15-minute sentence for the foreground case; the closed-app case stays until
Release 2. Traps, if the header turns out hidden on Penn's deployment.

**What must not change.** `AutoSyncCoordinator`'s course-knowledge and Ed
paths; `refreshCanvasGrades` and its throttle; the structured-sources run's
replace rules for dismissals. The poll reads, it never writes a completion
as the student's own.

### Phase 3. Arm the Sweeper only from a confirmed read inside the last hour

**What.** The loud alarm (and its three-buzz fallback) is registered for an
item only once a read taken inside the last 60 minutes before its ring time
has seen the item still unsubmitted. An item the app could not confirm in
that window gets no loud alarm, only the ordinary quiet reminders, which
keep their days-ahead scheduling. That trades a missed ring for a wrong
ring, which is Marco's stated preference (2026-11-04: before the Sweeper
runs, something has to make sure the assignment really needs alarming,
"since it can be quite annoying").

**Why this is a change to arming, not a check at ring time.** An alarm
registered days ahead rings no matter what (research §1). The only thing
our code controls is whether it is registered, and when.

**The pure rule to extract and test first.** Two additions to
`SweeperSettings` (`LUI/SweeperPlan.swift`), the one eligibility rule both
the planner and the Sweeper page read, so the countdown card can never
promise an alarm the planner will not set:

1. `armingWindow: TimeInterval = 3600` and
   `SweeperSettings.mayArm(_ item: DashItem, now: Date, confirmation: SubmissionConfirmation?) -> Bool`:
   true only when `ringAt - now <= armingWindow` and `confirmation` is a
   read of this item's Canvas id, taken at or after `ringAt - armingWindow`,
   that said unsubmitted. `SubmissionConfirmation` is a small value
   (assignment id, read at, source: planner | grades | gradescope,
   submitted: Bool) that Phase 1's observation points and Phase 2's poll
   record into a memory map `AppState.lastSubmissionReads` (never persisted:
   a confirmation older than an hour is worthless and a relaunch starts
   clean). `plannedAlarms` and `loudAlerts` consult it; `nextSweep` shows
   the card for an item that *will* qualify once confirmed, with the word
   "checking" under the countdown until it is (one word, the copy rule).

2. `SweeperSettings.neverRings(_ item: DashItem, facts: SweeperItemFacts) -> SweeperQuietReason?`,
   the quiet rules, each one line and each a case of the enum, returned so
   the DEBUG row can say why:
   - `.nothingToSubmit`: `showsNothingToSubmit` (Canvas `none`, `on_paper`,
     `not_graded`, `.event`), already a rule, kept;
   - `.inClass`: an on-paper item or a title naming a quiz or exam that is
     not a found exam, the rule `NothingToSubmitLabel.text` already uses to
     say "in class" (`docs/QUIZ_MISSED_2026-11-09.md`: nothing loud rings for
     an in-class quiz; a morning-of notice is a separate decision of Marco's
     under ROADMAP → Next, not this plan's);
   - `.zeroPoints`: `points_possible == 0`, from the grades fetch's
     `GradeItem.pointsPossible` (`LK/Canvas/CanvasGradesClient.swift:330`;
     `omit_from_final_grade` is decoded beside it at `:511` and counts the
     same way);
   - `.optionalTitle`: the title, lowercased, contains one of a short fixed
     list: optional, practice, survey, extra credit, ungraded, attendance;
     one `static let`, one test per word, one test that "Optional reading
     response 3" is quiet and "Problem Set 3" is not;
   - `.gradescopeOnly`: an item with no Canvas assignment id, so no planner
     read can ever confirm it; it rings only if a Gradescope scrape inside
     the window still read "No Submission" (the scrape's cadence is Olisa's;
     this plan asks nothing of it, so in practice such an item is quiet until
     the scrape happens to land in the hour, and CLAUDE.md says so);
   - `.foundExam`: `isFoundExam`, already a rule, kept;
   - `.recurring`: `RecurringTask.isOccurrence`, already a rule, kept;
   - `.classOff`: the class's Sweeper or reminders switch, already a rule, kept.
   `SweeperItemFacts` carries the few per-item facts the rule needs (points,
   omit flag, submission types, has Canvas id) snapshotted at `reload` like
   `requiresNoSubmission` is, so `DashItem` stays a presentation value.

**What the student sees instead.** Nothing new on the dashboard. A quiet item
keeps its ordinary reminders. The Sweeper page's countdown card names the
next alarm that will actually ring; a DEBUG build with
`FeatureFlags.profileDiagnostics` flipped shows one row per item in the
next 24 hours with its `SweeperQuietReason` or "arms at <time>" or
"confirmed <m> min ago"; a Release build shows none of it (the copy rule,
and the owner's 2026-10-20 call on diagnostics).

**The model gate, later, not here.** Where rules cannot tell, a pooled
course-level `alarm_worthy` verdict from `extract-facts` was proposed on
2026-11-04. Leave the seam: `SweeperQuietReason` has a `.pooledVerdict` case
nobody produces, and a `SweeperQualifier` protocol with the rules
implementation behind it. It rides Olisa's sync and needs his go; it goes
into ROADMAP → Next, not into this release.

**Acceptance.** Tests: an item due in 3 hours has no alarm registered and no
loud buzz planned; the same item at due minus 50 minutes with a planner
confirmation 2 minutes old has one; the same with a confirmation 70 minutes
old has none; with no confirmation, none, and the quiet reminders are
unchanged in both cases; each quiet reason removes its item and leaves the
others; the Sweeper page's `nextSweep` and the planner's `plannedAlarms`
agree on every fixture (a parametrised test over the existing fixtures).
`BerserkAlarmTests`' parity test ("every loud item ends with exactly one of
alarm or buzzes") is extended with the confirmation, not loosened. Device
check: one real item rings once at its lead time with the app having been
open inside the hour; one submitted from the Canvas website 20 minutes
before its ring does not ring and is not on the Sweeper page; an item due
in 3 hours shows "checking" on the page and no alarm in `storedAlarms()`
(the DEBUG row lists the AlarmKit store).

**CLAUDE.md and ROADMAP.md lines.** What the app does → Profile → reminders:
the Sweeper arms inside the last hour from a confirmed read, the quiet
rules by name, what "checking" means. Traps: a new entry, "an alarm armed
days ahead cannot be unarmed", pointing at the research. Known gaps: the
closed-app case rewritten as "an item the phone could not confirm in the
hour gets no alarm; Release 2 adds the wakes that make confirmation likely".
ROADMAP → Next: the pooled verdict seam.

**What must not change.** `BerserkAlarmPlan.alarmID` (a reschedule stays
idempotent; nothing about the id changes); the stop button; the ordinary
reminders' days-ahead plan and their 64-slot budget arithmetic
(`reservedForeignSlots` and the ambassador carve-out); the ledger.

### Phase 4. Prove the background wake, and let it run the poll

**What.** Settle whether `BGAppRefreshTask` wakes ever arrive on a real
phone, how often, and whether a wake can finish the last-hour poll inside
its 30 seconds; then let a wake inside the hour run the poll regardless of
the 15-minute grades throttle.

**Why fourth.** Phases 1 to 3 make the read decisive; this phase only adds
chances to read while the app is suspended. No wake has ever been watched on
a phone (CLAUDE.md, Known gaps; the crash of 2026-08-24 to 2026-10-09 ran
unseen for six weeks). Apple documents no cadence, Low Power Mode switches
it off, and a force-quit ends it (research §1). So "proven" has to be
measured, not assumed.

**The debug read-off.** A `DebugWakeLog` beside `DebugRenewalLog`
(`LUI/DebugRenewalLog.swift`), DEBUG only: one line per wake kept in
`UserDefaults.lhf` `debugWakeLogV1` (last 50): time, what ran (keepalive,
feed sync, grades, planner poll, replan), how long each step took, how it
ended (completed, expired, cancelled), and the counts of §4; never a title,
id or URL. Read with the device-forensics plist copy (CLAUDE.md →
Commands). The wake's `handle` already has an expiration handler; the log
line is written first thing in `run()` and finished in `completeOnce`.

**What "proven" means.** At least three `debugWakeLogV1` lines on Marco's
phone over 48 hours in which `run()` started, with their spacing written
into CLAUDE.md; at least one in which the planner poll ran to completion
inside the budget. If no line appears in 48 hours with the phone used
normally, that is the result: Known gaps says "no wake in 48 hours", and
nothing is faked with a timer. The wrong fix is a `BGProcessingTask` "for
more time": it is not a timer either, and it runs once after a force-quit
and then waits.

**The throttle bypass.** In `run()` (`LUI/BackgroundRefresh.swift:178`), after
`refreshCanvasGrades` (which may well return at its throttle), ask
`LastHourPoll.cadence` with `lastPoll` from the poll's own stamp; on `.poll`
run `fetchPlannerWindow` and `applyPlannerWindow`, then the existing
`replan`. Keep `rescheduleWithoutPrompting` (a wake can never show the
AlarmKit prompt). Nothing else in `run()` moves; in particular the renewal
wait and the turned-in drain stay after the replan, for the reasons the
file's own comments give.

**Acceptance.** `LaunchRefreshStructureTests`-style source scans pin the
order (poll after grades, before replan) and that the wake's poll goes
through the same `applyPlannerWindow` as the foreground's; a test that a
wake outside the hour makes no planner call. Device: the three lines, read
off the plist. `swift test` does not compile `BackgroundRefresh.swift`
(iOS only), so the `xcodebuild` for `generic/platform=iOS` is part of "done"
here, as CLAUDE.md's Test baseline says.

**CLAUDE.md and ROADMAP.md lines.** Known gaps → the background-refresh
entries: replaced by the measured cadence or by "no wake in 48 hours".
Commands: `debugWakeLogV1`. What the app does → Background: the wake runs
the last-hour poll past the grades throttle.

**What must not change.** The wake never prompts, never latches a session
dead (the never-latch guard), never posts a turned-in notice before the
replan, and still awaits a pending silent renewal before completing.

## 2. Release 2: the server as a timer (research route A)

Everything here is behind one compile-time switch, `FeatureFlags.sweeperWake`
(false until the whole phase is on a phone), and one server switch,
`LHF_SWEEPER_WAKE_DISABLED` (§2.9). It ships only after Release 1 is on the
App Store, because it is only another chance for the read Release 1 makes
decisive; on its own it decides nothing.

### 2.1 The APNs setup, Olisa's part as Account Holder

- In the Apple Developer portal, Certificates, Identifiers & Profiles →
  Keys: create an **APNs authentication key** (the `.p8` file, downloadable
  once). Record its **Key ID** (10 characters) and the **Team ID**
  (`24A3TDB277`, already in `project.yml`). One key serves every app on the
  team and both the sandbox and production APNs hosts, so this is a
  one-time act. The `.p8` is a secret: it goes nowhere but the server's
  secret store, and never into the repo, a chat, a log, or this document.
- On the Supabase project, three function secrets: `APNS_KEY_P8` (the PEM
  text), `APNS_KEY_ID`, `APNS_TEAM_ID`; and `APNS_TOPIC` =
  `com.lhf.lowhangingfruit` (the bundle id; a background push's topic is the
  app's bundle id). Set with `supabase secrets set` or the Management API,
  by Olisa or by Marco with the token in `~/lhf-bench/supabase.token`.
- In the App ID's capabilities: Push Notifications enabled (the portal
  regenerates the provisioning profile; `-allowProvisioningUpdates` picks it
  up at the next build). Olisa, or Marco if his role allows it.
- In the app: `aps-environment` in `App/LHFApp.entitlements` (iOS only, like
  the Time Sensitive key; `development` in the Debug file, `production` in
  the archive, which Xcode rewrites at archive time when the entitlement is
  present; verify by reading the archived `.app`'s embedded entitlements
  with `codesign -d --entitlements -`). `project.yml` carries the plist keys
  as today (nothing new is needed in `info.properties` for a background
  push; `UIBackgroundModes` gains `remote-notification`, and that key *does*
  belong in `project.yml` and `App/Info.plist`, both, the xcodegen trap).

### 2.2 The phone's registration

- **Token.** `UIApplication.registerForRemoteNotifications()` at the first
  foreground after onboarding on a Penn install with a backend, the opt-in
  on and the Sweeper on. There is no app delegate today (`App/LHFApp.swift`
  is a plain `App`); add a minimal `UIApplicationDelegateAdaptor` whose only
  job is `didRegisterForRemoteNotificationsWithDeviceToken` → hex string →
  `AppState.noteDeviceToken(_:)`, and `didFailToRegister…` → log a count. A
  background push needs no user permission prompt, so nothing is asked of
  the student; the existing notification permission is for the alerts and
  stays as it is.
- **Ring minutes.** The phone computes, from `plannedAlarms` and the quiet
  rules, the set of moments at which it wants to be woken: for each item
  that will qualify for the Sweeper (confirmed or not yet), `ringAt - 15 min`
  and `ringAt - 3 min` (two chances per alarm; Apple: "two or three per
  hour", and every item due at 11:59 PM is one moment, so a day's list is
  short), truncated to the minute, UTC, at most 24 moments and only inside
  the next 48 hours. Nothing about which item: the server receives a list
  of timestamps. `SweeperWakePlan.moments(from: [PlannedAlarm], now:) -> [Date]`
  is the pure rule, tested, with a test that two alarms at the same minute
  make one moment.
- **Sending.** `PUT /sweeper-wake` `{ token, moments: [ISO8601], platform:
  "ios", environment: "production" | "development" }` with the anonymous
  account's JWT, from `settleAfterFetch` after the replan, at most every 10
  minutes and only when the moments or token changed (a hash kept in
  memory). Foreground only.
- **Deletion.** `DELETE /sweeper-wake` on: the Sweeper's opt-out (there is
  no Sweeper switch after onboarding today, so this is the onboarding
  switch going off, or every class excluded), reminders off, Canvas
  disconnect (`disconnectCanvas` already calls `delete-account`, whose
  `deleteUserData` gains the row; the explicit delete is the belt), and the
  flag off. A token Apple reports invalid (410 `Unregistered`, or 400
  `BadDeviceToken`) is deleted by the server itself. iOS can rotate a device
  token; the delegate callback re-registers it on the next launch and the
  PUT replaces the row.

### 2.3 The backend contract, to add to `backend/PROTOCOL.md`

A new section "The Sweeper wake (`sweeper-wake`)", after the agent
connection, in the register of the sections around it.

**Table `sweeper_wakes`**, service role only (RLS on, no policy for `anon`
or `authenticated`, like the agent tables): `user_id uuid references
auth.users on delete cascade`, `device_token text` (hex, 64 chars; one row
per token, `primary key`), `environment text check in ('production',
'development')`, `moments timestamptz[]` (at most 24, inside 48 hours,
enforced by the function), `updated_at timestamptz`, `last_sent_at
timestamptz`, `failures smallint default 0`. One user may have several
tokens (a reinstall before the old row is deleted); the cascade from
`auth.users` is the deletion of record. No column may hold a course id, an
assignment id, a title or a URL, and `test/rls.test.sql` pins the columns.

**Edge Function `sweeper-wake`** (`verify_jwt = true`): `PUT` upserts the
caller's row for the token (validates the hex, the count, the horizon,
drops moments in the past); `DELETE` removes every row of the caller;
`POST /tick` (service role only, from pg_cron, refused for any other
caller) selects rows with a moment in `[now - 60 s, now)` and
`last_sent_at` not in the same minute, sends one background push per row,
and stamps `last_sent_at`. The push: `POST https://api.push.apple.com/3/device/<token>`
(`api.sandbox.push.apple.com` for `development`), headers `apns-push-type:
background`, `apns-priority: 5`, `apns-topic: <bundle id>`, `apns-expiration:
<now + 120 s>` (a push older than two minutes is useless: the moment has
passed), `authorization: bearer <ES256 JWT>`; body `{"aps":{"content-available":1}}`
and nothing else. The JWT is signed with the `.p8` and cached in the
isolate for 50 minutes (Apple: refresh no more than once every 20 and no
less than once every 60). APNs is HTTP/2 only; **whether an Edge Function's
`fetch` negotiates HTTP/2 to Apple is the first thing the probe (§2.8)
settles**, and the connector front on Vercel is the fallback host for the
send if it does not. Since `X-Smooth-Version` gating is fail-open and this
function is new, it requires the header from day one (its floor is the
first build that sends it).

**The scheduled job.** `select cron.schedule('sweeper-wake-tick', '* * * * *',
$$ select net.http_post(url := '<functions base>/sweeper-wake/tick', headers
:= '{"Authorization": "Bearer <service role>", ...}') $$)` in a migration
(`20261117090000_sweeper_wake.sql`), the pattern Supabase documents; the
service-role key reaches the SQL through Vault, never a literal in the
migration. Once a minute is the floor the moments are truncated to.

**Idempotency.** A moment is sent at most once per row: `last_sent_at` is
compared at minute grain, and the `UPDATE` that stamps it is conditional
(`where last_sent_at is distinct from date_trunc('minute', now())`), so two
overlapping ticks cannot double-send. A second push in the same minute is
harmless anyway (iOS coalesces and the phone's poll is idempotent), so this
is thrift, not correctness. A tick that fails part way leaves the unsent
rows unstamped for the next minute, and a moment is dropped from the
array once sent or once it is more than 5 minutes past.

**Logged, and never logged.** Per tick: rows considered, pushes sent,
APNs status codes counted by code, the time taken. Per push failure: the
status code and Apple's `reason` string (`BadDeviceToken`, `Unregistered`,
`TooManyRequests`, `ExpiredProviderToken`…), the row's `failures` count, never
the token. Never: a token, a user id in a log line (the row has it; the
log does not), any moment's timestamp (which would say when a student's
work is due). After three `failures` or one `Unregistered`, the row is
deleted and counted.

**Rate and budget.** At most one push per row per minute by construction;
per row, at most 24 moments in 48 hours, so at most 24 pushes in two days
for one install, well inside "two or three per hour". The function refuses
a PUT with more than 24 moments (400) and never trims silently, so a client
bug shows up as a count rather than a quiet loss.

### 2.4 The wake handler on the phone

`application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` on the
same adaptor, with the `remote-notification` background mode. Budget: about
30 seconds, so it does one thing: `LiveAppStateRegistry.shared.beginWake()`
(the same context the BGTask wake uses, so every renewal it could start is
`.background` and latches nothing), the planner window poll
(`fetchPlannerWindow`, two-hour window) through `applyPlannerWindow`, Phase
1's cancel hook, then `replan` with `rescheduleWithoutPrompting`, then the
completion handler with `.newData` or `.noData`. No feed sync, no grades
fetch, no course material, no Ed, no turned-in notice (the drain stays in
the foreground and the BGTask wake). If the Canvas session is dead
(`SessionCookieStore.isExpired`, or the poll answers 401), the wake does
nothing and counts it; a wake never starts a Duo push. The wake writes a
`debugWakeLogV1` line tagged `push` so Phase 4's read-off tells the two
kinds of wake apart.

### 2.5 The privacy paragraph and the App Store label

In `docs/PRIVACY.md` → "What is sent to our server (and why)", a new bullet,
in that section's voice, and a line under "What we keep and for how long"
and "Deleting your data". Draft, to be fitted to the page by the build
session and not lengthened:

> **A wake-up call for the Sweeper (iOS 26, optional).** The Smooth
> Sweeper is an alarm iOS rings whether or not the app is running, so the
> app has to decide beforehand whether your work is still unsubmitted.
> To give it a chance to check close to the deadline even when it is
> closed, your phone sends our server two things: the device token Apple
> issues this install for push notifications (it identifies the install to
> Apple, not you), and a short list of minutes at which the phone would
> like to be woken, at most twenty-four over two days. At those minutes
> our server sends your phone a silent push, with nothing in it; your
> phone wakes for a few seconds, asks Canvas whether the work is in, and
> keeps or cancels the alarm. The server never learns which class, which
> assignment or whether you submitted; the minutes are just minutes.
> Apple may deliver these pushes late or not at all, and never after you
> force-quit the app, so they help the alarm, they do not control it. The
> token and the minutes are deleted when you turn the Sweeper off, turn
> reminders off, disconnect Canvas or delete your account, and the minutes
> are replaced every time the app refreshes.

App Store privacy label: under **Identifiers → Device ID**, "used for app
functionality, linked to the user" (the token is linked to the anonymous
account, so "linked" is the honest answer; it is not used for tracking).
Nothing else on the label changes: the minutes are not a listed data type.
`docs/appstore/REVIEW_NOTES.md` gains two sentences saying what the push is
and that it carries no content.

### 2.6 Apple's failure modes and how each degrades to Release 1

- **Throttling** ("two or three per hour", held and delayed, only the newest
  held push kept): a late push wakes the phone after the ring. Degrades to
  Release 1 exactly: the alarm that rang was armed from a confirmed read
  inside the hour, and the two moments per alarm mean the earlier one often
  lands even when the later is dropped. No retry: a second push is the
  "newest" and displaces nothing useful.
- **Low Power Mode**: Background App Refresh is off; whether background
  pushes are delivered is undocumented. Degrades to Release 1. The DEBUG
  wake log records `ProcessInfo.isLowPowerModeEnabled` at each wake so the
  48-hour read-off can say whether any push arrived in it.
- **Force-quit**: the held push is discarded and the app is never woken.
  Degrades to Release 1, and this is the case Release 1's "arm only from a
  confirmed read" exists for: an item the phone never confirmed in the hour
  has no loud alarm, only the quiet reminder.
- **Device offline at the moment**: APNs holds the push until the device
  connects or `apns-expiration` passes (two minutes), then drops it. Same
  as a late push.
- **Token rotation or reinstall**: Apple answers `Unregistered`; the server
  deletes the row; the next foreground re-registers and PUTs. Until then,
  Release 1.
- **APNs or the function down**: no push. The cron keeps ticking; a tick's
  failure is counted and the next minute tries the rows still due. Release 1
  meanwhile.
- **The phone's session dead at the wake**: the wake confirms nothing and
  cancels nothing; the alarm armed earlier stands, as under Release 1.

In every row the student is never worse off than under Release 1, because
nothing in Release 2 arms, keeps or cancels an alarm without a read, and a
missed wake is a missed read.

### 2.7 The one open design choice, and the recommendation

**Should the phone send moments (timestamps) or offsets ("wake me 15 and 3
minutes before each of my alarms", with the alarms' times)?** They are the
same information in different clothes, and the research's wording, and
Marco's yes, were for *minutes*. Recommendation: **send moments, as above**.
The server then holds no notion of an alarm, a lead time or a per-class
setting, and the table has no shape that could grow into "which item"; it
is a list of timestamps a device asked to be pinged at, nothing more. The
alternative (alarm times plus offsets) tells the server when the student's
work is due, which is one step closer to the thing the rule forbids, for no
gain. A second, smaller choice is folded into the recommendation: two
moments per alarm (15 and 3 minutes before), not one, because Apple's
throttling is per device and per hour and a single late push is the common
failure.

### 2.8 The end-to-end probe

`backend/scripts/sweeper-wake-e2e.mjs`, the `agent-e2e.mjs` pattern, run
from any Node 22 shell with the Management token: (1) a throwaway anonymous
user PUTs a fake token with one moment one minute ahead; (2) the script
waits for the tick and reads the function log (`function_edge_logs`, the
query shape in CLAUDE.md → Traps, "the Management API's logs moved") for the
tick's `sent 1` and APNs's answer; against a fake token Apple answers 400
`BadDeviceToken`, which is the proof the request reached Apple over HTTP/2
with a valid provider JWT; (3) DELETE, and the row is gone; (4) a PUT with
25 moments is a 400; (5) a PUT with a moment 3 days out keeps none. The
first run of (2) is the HTTP/2 question of §2.3: a `fetch` that cannot speak
HTTP/2 to Apple fails at the connection, not with a 400, and then the send
moves to the Vercel front. A real-token run is the phone check: Marco's
Debug build registers, the Sweeper page shows an alarm 20 minutes out, and
the plist's `debugWakeLogV1` gains a `push` line within a minute of each of
the two moments (or does not, which is also the measurement).

### 2.9 The kill switch

Server: `LHF_SWEEPER_WAKE_DISABLED=1` makes `/tick` a no-op that still
answers 200 and counts, and makes `PUT` answer 200 without storing (so an
older phone build keeps working and nothing accumulates). Phone:
`FeatureFlags.sweeperWake = false` registers nothing, sends nothing and
sends one `DELETE` at the first foreground if a row may exist (a defaults
flag remembers that a PUT was ever made). Either switch alone leaves the
app on Release 1's behaviour; neither touches an alarm.

## 3. Effort, order, needs, and how it is measured

| Phase | Days | Needs from Marco | Needs from Olisa |
|---|---|---|---|
| R1.1 cancel at observation | 1 | a phone session for the check | nothing |
| R1.2 last-hour planner poll | 2 | the rate-limit headers read off his phone | nothing (the poll is beside his sync, not in it) |
| R1.3 arm from a confirmed read, quiet rules | 2 | the word list approved; "checking" approved | nothing; the pooled verdict is a later ask |
| R1.4 background wake proven | 1 plus 48 h of normal phone use | the phone on the cable twice for the plist | nothing |
| R2 server timer push | 5 to 7 | the deploy go, the privacy label edit in App Store Connect, the phone | the APNs key (Key ID, Team ID, `.p8` into the Supabase secrets), Push Notifications on the App ID, the PRIVACY.md paragraph's sign-off |

Order: R1.1, R1.2, R1.3, R1.4 (its 48 hours overlap R2's build), then R2,
and R2 only after Release 1 is on the App Store. R1.1 to R1.3 are one
release, 3.6.0 or whatever follows 3.5.0 (21); R1.4 is a Debug-build
measurement that changes one line of production code (the bypass) and
ships with them if it is done in time; R2 is the release after.

**How we will know the Sweeper now rings only when it should.** Counts on
the phone, in `UserDefaults.lhf` under one key (`sweeperCountsV1`), DEBUG and
Release alike, never a title, id or URL, shown as one DEBUG row and read off
the plist:
- `armed`: alarms registered from a confirmed read;
- `withheld.unconfirmed`: items that reached their arming window with no
  read inside it (the number Release 2 exists to lower);
- `withheld.quiet.<reason>`: one per `SweeperQuietReason`;
- `cancelledAtObservation`: Phase 1's cancellations;
- `rang`: alarms whose id was missing from `storedAlarms()` at the next
  launch while the item was still unsubmitted at that launch (a ring that
  should have rung);
- `rangSubmitted`: the same, but the item read as submitted by then, with
  a sub-count of how many minutes before the ring the submission was seen
  (a wrong ring, the number this whole plan exists to drive to zero);
- `polls`, `pollsBackedOff`, `wakes.bg`, `wakes.push`, `wakes.lowPower`.

The plan has worked when, over two weeks on Marco's and Olisa's phones,
`rangSubmitted` is zero, `rang` is not, and `withheld.unconfirmed` falls
once Release 2 is on. Those three numbers, dated, go into CLAUDE.md →
Known gaps each time they are read, and a `rangSubmitted` above zero is a
bug report with the minutes-before figure attached.

## 4. What this plan will still not fix

A student who submits on the Canvas website, never opens Smooth in the
hour, has force-quit the app, and whose phone iOS never wakes: with Release
1 their alarm was never armed (no confirmation), so they hear the quiet
reminder only. That is the designed outcome, not a gap: a missed ring in
place of a wrong one. Making the ring itself conditional on a check at fire
time would need the server to know submission state, which is the line
Marco and Olisa have drawn, and the research found no iOS mechanism that
would run the check on the phone instead.
