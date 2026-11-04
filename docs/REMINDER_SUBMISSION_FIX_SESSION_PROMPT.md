# Session brief: reminders must not fire for work already turned in, and the Sweeper must earn its ring

Written 2026-11-04 for the session that builds this on `v10`. Read
`CLAUDE.md` and `ROADMAP.md` first, then this. Marco agreed to all four
parts on 2026-11-04. Paths: `LUI/` is
`LowHangingFruitKit/Sources/LowHangingFruitUI/`, `LK/` is
`LowHangingFruitKit/Sources/LowHangingFruitKit/`.

## The problem, in one paragraph

On 2026-11-03 Marco submitted an assignment on Canvas and about fifteen
minutes later Smooth reminded him it was due. Reminders are local
notifications handed to iOS days ahead (`LUI/NotificationScheduler.swift:752`,
ids `due:<assignment id>:<offset>`), and the loud "Smooth Sweeper" alert
is the same or an AlarmKit alarm (`:947`, `BerserkAlarmDelivery.swift:207`).
They ring whether or not the app is running. The only thing that unsets
one is a replan after a Canvas grades fetch has seen the submission
(`CanvasGradesClient.swift:107`, `AppState.swift:8967`,
`AssignmentStore.applySubmissionState` at `:1268`). That fetch runs at
most every 15 minutes (`AutoSyncCoordinator.swift:22`, `:86-89`), only
while the app is in the foreground, and the replan that removes the
request happens later in the same pass (`ContentView.swift:875`), never
at the moment of observation. So a submission within about 20 minutes
of a reminder, or any submission while the app is closed, cannot stop
the ring. CLAUDE.md → Known gaps already records the closed-app case.

## What to build, in order. Each part ships alone.

### 1. Cancel at observation

When `updateSubmissionState` learns of a newly submitted Canvas id (or
Gradescope sets `gradescopeSubmitted`), remove that item's pending
notification requests (`due:<id>:*`) and its AlarmKit alarm right there,
and stop a ringing alarm, instead of waiting for the next full replan.
The existing plan-diff removal in `applyNotifications`
(`BerserkAlarmDelivery.swift:297`) stays as the backstop.

Acceptance: a test that feeds a submission observation and asserts the
scheduler's removal was called with exactly that item's identifiers and
nothing else; the ledger invariant tests unchanged; nothing added to the
ledger (this touches notifications, not storage).

### 2. A fast, cheap submissions poll near deadlines

Add a submissions-only fetch (the per-course
`/api/v1/courses/:id/students/submissions?student_ids[]=self`, or the
assignment-groups call with `include[]=submission` already used, whichever
is lighter after measuring one real course) that is exempt from the
15-minute grades throttle. Run it on the 5-minute tick, and every minute
while any non-completed item is due within the next 60 minutes and the
app is open. Keep the grades fetch itself on its throttle. Respect
`X-Rate-Limit-Remaining` (back off per course, never fail the run).

Acceptance: a test that the poll cadence tightens to one minute inside
the hour and relaxes outside it; a device check where a submission made
on canvas.upenn.edu with Smooth open in the foreground clears the
reminder within two minutes (read `debug` lines, no screenshots needed).

### 3. Let the background wake do its job, and prove it runs

`LHFBackgroundRefresh.run()` (`LUI/BackgroundRefresh.swift:210-224`)
already fetches grades and replans, but it hits the same 15-minute
throttle, and no wake has ever been observed on a phone (the crash trap
in CLAUDE.md; the fix is unverified). Give `run()` a throttle bypass for
the submissions poll from part 2, keep the rest, and then prove on
Marco's phone that a wake runs at all: a DEBUG `LHF-BG` log line kept
in `UserDefaults.lhf` (time, what ran, how long), readable with the
device-forensics copy, and `xcrun simctl`-free (real device only, per
the owner's rule). If wakes never arrive in 48 hours, say so in Known
gaps; do not fake it with a timer.

Acceptance: at least one `LHF-BG` line on Marco's phone showing a wake
that ran the poll, plus Deno/Swift green.

### 4. The Sweeper gate: the loud alert has to earn its ring

Marco, 2026-11-04: before the Sweeper runs, something has to make sure
the assignment really needs alarming, "since it can be quite annoying".

The constraint first: an alarm registered days in advance rings no
matter what. So the gate cannot be a check at ring time; it has to
change *when* the loud alert is armed and *what* qualifies.

- **Arm late, not early.** Register the Sweeper alarm for an item only
  inside a short window before it is due (60 minutes is the first
  value; make it a constant), from a pass that has just run the
  submissions poll from part 2 and confirmed the item is still
  unsubmitted. Items the app has not been able to confirm in that window
  (app closed the whole hour, no Canvas session) get no loud alert, only
  the normal quiet reminder. That trades a missed ring for a wrong ring,
  which is the owner's stated preference. The quiet reminders keep their
  current days-ahead scheduling.
- **Qualify with rules before any model.** The Sweeper already skips
  completed items, no-submission items, recurring tasks and found exams
  (`NotificationScheduler.swift:957`). Extend the rule set with what
  Canvas states as data: `submission_types` of `none`, `on_paper` or
  `not_graded`; `points_possible` 0; `omit_from_final_grade`; titles
  matching a short list ("optional", "practice", "survey", "extra
  credit", "ungraded", "attendance"); and items whose course the
  student has muted for loud alerts. Every rule is a pure function with
  a test, and the DEBUG rows under Profile → accounts show, per item,
  why it did or did not qualify.
- **The model gate, pooled, later.** Where rules cannot tell (a
  normal-looking assignment that classmates would consider optional), a
  per-assignment judgment can come from the same pooled `extract-facts`
  path chosen in Phase 0 (`docs/EXTRACT_FACTS_BENCH_2026-11-03.md`,
  Haiku 5.5): a course-level `alarm_worthy` verdict on the assignment
  document, computed once per course, never per student, nothing
  personal sent. Do not build this in this session; leave a seam (a
  protocol with the rules implementation behind it) and note it in
  `ROADMAP.md` → Next. It needs Olisa's go because it rides his sync.

Acceptance: a test that an item due in 3 hours has no Sweeper alarm
registered; a test that the same item, confirmed unsubmitted at due
minus 50 minutes, gets one; a test that each disqualifying rule removes
it; on Marco's phone, one real item rings once at the lead time with
the app having been open in the hour, and one submitted from the Canvas
website 20 minutes before does not ring.

## Boundaries

- Do not touch Olisa's sync or Ed code (`AutoSyncCoordinator`'s course
  knowledge and Ed paths, `CourseKnowledgeCollector`); the submissions
  poll is a new, small client beside `CanvasGradesClient`.
- Nothing here changes what leaves the phone; `docs/PRIVACY.md` is
  unchanged unless the model gate is built, which it is not.
- Keep copy minimal (owner's rule): no new Settings prose. One DEBUG
  row per decision is fine.
- Compile and run `swift test --no-parallel` before claiming done
  (baseline 3457 / 331 on `v10`); install on Marco's connected phone,
  never the Simulator; check which build is on the phone first
  (another thread also installs there).
- Record the device results in CLAUDE.md → Known gaps ("Turned-in
  state" and the loud-alert entries) and `ROADMAP.md` → Done recently.

## What this will not fix

Submitting on the Canvas website, never opening Smooth, and iOS never
waking it in time: the quiet reminder still fires. Only a server-side
check could stop that, which would mean the server learning submission
state, a privacy-line decision for Marco and Olisa, not for this
session.
