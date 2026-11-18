# Sweeper accuracy for 3.5.0: the build plan

Written 2026-11-18 on `claude/sweeper-build-0a4dd0`, cut from the release
line `claude/ambassador-header` at `65d3558` with the server design docs
merged in (`01116e0`). This is the ordered list of what gets built, in which
files, with which tests, and how each phase is accepted. It builds exactly
two briefs and adds nothing to them:

- `docs/SWEEPER_ACCURACY_PLAN_2026-11-16.md` (Release 1, phone only), and
- `docs/SERVER_SWEEPER_DESIGN_2026-11-17.md` (Release 2, the server wake).

Marco approved both for 3.5.0 (21) on 2026-11-17/18. His rule, verbatim,
which every line below obeys: **"no dont want no alarm option as this cd
lead to someone missing an assignemnt."** The alarm is armed days ahead as
today; only a confirmed "submitted" read from Canvas or Gradescope, made on
the phone with the student's own session, cancels it; a failed, timed-out,
partial or missing read cancels nothing; the server never decides to ring
or cancel and never holds the Canvas session.

**Not built here, by Marco's decision:** the force-quit path (a visible
push, a Notification Service Extension, the filtering or Critical Alerts
entitlements), anything on the agent connection, any deploy, any phone
install, any change to how `ask` or the course-material sync work.

Paths: `LUI/` is `LowHangingFruitKit/Sources/LowHangingFruitUI/`, `LK/` is
`LowHangingFruitKit/Sources/LowHangingFruitKit/`, `F/` is
`backend/supabase/functions/`. Gate for every phase: `pgrep -f
LowHangingFruitKitPackageTests` empty, `defaults delete
swiftpm-testing-helper`, `swift test --no-parallel` alone on the Mac (the
baseline is 4158 tests / 406 suites at `65d3558`, every change in the count
accounted for), and the unsigned iOS build (`xcodebuild -destination
'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`) for anything behind
`#if os(iOS)`; for phase 2 also `cd backend && deno task test` and `deno
task check`, and `backend/scripts/sql-check.sh` where Docker is up.

## Where the code stands today (read 2026-11-18 at `65d3558`)

- `NotificationScheduler.reschedule` runs one pass at a time through
  `RescheduleSerializer`; `applyReminders` (`LUI/BerserkAlarmDelivery.swift`)
  diffs pending request ids against the plan and already enumerates every
  `(minutes, sound)` pair over `sweeperMinuteOptions × SweeperSound.allCases`
  to find finished alarms. Request ids are `due:<assignment id>:<offset>`
  (`NotificationScheduler.identifier(for:)`, private).
- `SweeperSettings.qualifies` (`LUI/SweeperPlan.swift`) is the one
  eligibility rule, shared by `loudAlerts` and the Sweeper page's
  `nextSweep`. Today it excludes: done, undated, past, beyond the horizon,
  `showsNothingToSubmit` (Canvas `none` / `on_paper` / `not_graded` /
  `.event`, which is also the "in class" and "off canvas" set), recurring
  occurrences, found exams, excluded classes, classes with reminders off.
- A Canvas submission is observed in `AppState.updateSubmissionState`
  (`observedSubmitted`), a Planner tick or `submitted` flag in
  `AppState.applyStructuredSources` (additive `structuredCompletedItemIDs`),
  and a Gradescope one inside `syncGradescope` → `reconcileGradescopeFetch`
  (the ledger's `gradescopeSubmitted`). None of the three touches the
  scheduler; the cancel happens at `ContentView.settleAfterFetch`'s
  `reschedule`, or the wake's `replan`, later in the same pass.
- `AutoSyncCoordinator.refreshCanvasGrades` is throttled to 15 minutes
  (`canvasGradesMinInterval`) and chains into the course-material and Ed
  sync (Olisa's, not touched). `CanvasStructuredSourcesClient.fetch` already
  builds the `planner/items` request with a window and reads
  `X-Rate-Limit-Remaining`; its planner leg is not callable alone.
- `LHFBackgroundRefresh.run()` (`LUI/BackgroundRefresh.swift`, iOS only) is
  the one background entry; `LiveAppStateRegistry.beginWake` marks the state
  `.background` so no renewal latches and `backgroundMayUseCredentials`
  decides whether the saved password may be typed (never a Duo push).
- `App/LHFApp.swift` is a plain `App` with no delegate; `UIBackgroundModes`
  is `[fetch]` in both `project.yml` and `App/Info.plist`; the entitlements
  file carries Time Sensitive and no `aps-environment`.
- `BackendClient` has one wire, `post(function, body)`, with the anonymous
  JWT and `X-Smooth-Version`. `requireUser` resolves the caller;
  `deleteUserData` (`F/_shared/db.ts`) is what `delete-account` runs.
  `agent-snapshot` is the register for a per-student function with
  `action: put | delete` bodies.

## Phase 0: this document (done with this commit)

Merge of `claude/server-sweeper-3dea9b` (docs only), this plan, a report to
the overseer. 1 hour.

## Phase 1: Release 1 on the phone

Four pieces, one commit each where a piece compiles alone, one gate at the
end of the phase. About 16 hours.

### 1a. Pure rules in the Kit and the UI package, with tests (4 h)

New files:

- `LK/Alarms/SubmissionRead.swift`: `SubmissionRead` (assignment id, read
  at, `source: planner | grades | gradescope`, `verdict: submitted |
  unsubmitted | unknown`) and `cancels: Bool` (true for `.submitted` only).
  `SubmissionRead.verdicts(fromPlanner: [CanvasPlannerItem])` maps each
  planner item with an `assignmentID` to a read: `submitted == true` or
  `markedComplete` → `.submitted`; `submitted == false` → `.unsubmitted`;
  anything else → `.unknown`. An item absent from the page is no read at
  all (nothing is inferred from absence).
- `LK/Alarms/LastHourPoll.swift`: `LastHourPoll.cadence(now:nextRing:lastPoll:backedOffUntil:)
  -> PollDecision` (`.poll`, `.wait(until:)`, `.idle`): inside the hour
  before `nextRing` and 60 s since `lastPoll` → `.poll`; inside the hour but
  sooner → `.wait`; no ring inside the hour → `.idle`; under a back-off →
  `.wait(until: backedOffUntil)`. `LastHourPoll.window(now:) -> (start, end)`
  pins `[now - 1 h, now + 2 h]` (the design's §4.2 window; the plan's two
  hours around now is inside it). `LastHourPoll.insideTheHour(now:nextRing:)`
  is the one predicate the throttle lift (1c) reads.
- `LUI/SweeperQuietReason.swift`: `enum SweeperQuietReason` (`nothingToSubmit`,
  `inClass`, `offCanvas`, `recurring`, `foundExam`, `noConfirmableID`,
  `classOff`, `remindersOff`, `pooledVerdict` reserved and never produced)
  and `SweeperSettings.quietReason(for: DashItem, facts: SweeperItemFacts,
  courseRemindersOn:) -> SweeperQuietReason?`. `qualifies` becomes
  `quietReason(...) == nil` plus the date checks, so the planner and the
  Sweeper page keep sharing one rule. `SweeperItemFacts` carries
  `hasCanvasAssignmentID`, `hasGradescopeID`, `submitsOnPaper` and is
  snapshotted at `DashboardViewModel.reload` like `requiresNoSubmission`
  is. **Quiet by kind, per the overseer's brief:** nothing to submit, in
  class, off canvas, recurring, found exam, no Canvas or Gradescope id
  (a manual task, or a module row Canvas never resolved). The plan's
  `zeroPoints` and `optionalTitle` rules are left out: the plan itself
  lists the word list as needing Marco's approval, and nobody has given it.
  **Note for Marco:** the "no confirmable id" rule silences the Sweeper for
  the student's own manual tasks, which ring today; the overseer's brief
  asked for it and the rule is one line to flip if he disagrees.
- `LUI/SubmissionObservation.swift`:
  `SubmissionObservation.cancellations(submittedAssignmentIDs: Set<String>,
  items: [DashItem], settings: SweeperSettings) -> (requestIDs: [String],
  alarmIDs: Set<UUID>)`: for every item whose own id, `linkedID` or
  `canvasAssignmentID` is in the set, every `due:<id>:<offset>` request id
  (read from `NotificationScheduler.requestIdentifierPrefix`, made internal,
  never re-typed) and every `BerserkAlarmPlan.alarmID(assignmentID:fireDate:sound:)`
  over `sweeperMinuteOptions × SweeperSound.allCases`. Nothing else's ids
  may appear; that is the test.
- `LUI/DebugWakeLog.swift`: DEBUG only, `UserDefaults.lhf`
  `debugWakeLogV1` (last 50 lines), one line per wake or check: time,
  source (`foreground`, `launch`, `poll`, `bg`, `push`), duration,
  outcome, counts of cancelled requests and alarms; never a title, id or
  URL. Modelled on `DebugRenewalLog`. Beside it, `SweeperCounts`
  (`sweeperCountsV1`, Release and DEBUG): `armed`, `cancelledAtObservation.<source>`,
  `readsUnknown`, `polls`, `pollsBackedOff`, `wakes.bg`, `wakes.push`,
  `moments.sent`. Counts only.

Tests (new suites in `LowHangingFruitKit/Tests/`): `SubmissionReadTests`
(each verdict; `cancels` true for `.submitted` only; planner mapping, absent
item → no read); `LastHourPollTests` (the cadence table, the back-off, the
window); `SweeperQuietReasonTests` (one test per reason; an item due in 3
hours with a Canvas id is armed, the test that pins Marco's decision;
`nextSweep` and `plannedAlarms` agree on every existing fixture);
`SubmissionObservationTests` (one id → exactly its request and alarm ids; two
ids; a hidden twin / `linkedID`; nothing else's ids); `DebugWakeLogTests`
(a source scan that no title, id or URL reaches the line; the cap).

### 1b. Cancel at observation, wired (4 h)

- `NotificationScheduler.cancelForSubmitted(_ ids: Set<String>, items:
  [DashItem]) async`: inside the `RescheduleSerializer`, computes the
  cancellations and calls `sink.removePending(identifiers:)`,
  `activeAlarmBackend()?.stopRinging(among:)` and `cancel(id:)` for idle
  alarms; records the counts. Never `markCompleted`: a Canvas-observed
  submission is `canvasSubmitted`, not the student's tick (CLAUDE.md →
  Traps, "Canvas-derived completions … are not student edits").
- `AppState.submissionCanceller: (@MainActor (Set<String>) async -> Void)?`,
  bound beside `reminderReplanner` in `ContentView` and in
  `LHFBackgroundRefresh.run()`.
- Three observation points call it with the newly submitted ids:
  `updateSubmissionState` (the `observedSubmitted` minus previous set, the
  one "turned in" notices already diff from), `applyStructuredSources`
  (ids newly added to `structuredCompletedItemIDs`), and `syncGradescope`
  after `reconcileGradescopeFetch` (the Gradescope rows whose `submitted`
  went false → true, read from the store before and after). Only the hook,
  not the scrape.
- Tests: `CancelAtObservationTests` with a fake `PendingNotificationSink`
  and a fake `BerserkAlarmBackend`: one observation → removal called with
  exactly that item's ids; two ids; a twin; an `.unknown` read → nothing
  called; a source scan that the three observation points call the
  canceller and that `markCompleted` is not called from it.

### 1c. The last-hour poll and the throttle lift (5 h)

- `CanvasStructuredSourcesClient.fetchPlannerWindow(start:end:) async ->
  PlannerWindowResult` (`items`, `completed: Bool`, `rateLimited: Bool`,
  `sessionExpired: Bool`, `remaining: Double?`): the planner leg of `fetch`
  factored out, nothing else in that client changed.
- `AppState.applyPlannerWindow(_ result:) -> [SubmissionRead]`: applies only
  `submitted` / `markedComplete` to `structuredCompletedItemIDs` (additive,
  the same set `applyStructuredSources` writes), then calls the canceller
  with the newly submitted ids. Never touches dismissals, section dates or
  module rows; a partial, rate-limited or 401 answer applies nothing and
  counts `readsUnknown`.
- `LUI/LastHourPoller.swift`: a small `@MainActor` coordinator owned by
  `ContentView` beside the 5-minute loop, started on scene active, stopped
  on background; each tick asks `LastHourPoll.cadence` with `nextRing` from
  `SweeperSettings.nextSweep` and the pending alarms; on `.poll` runs
  `fetchPlannerWindow` and `applyPlannerWindow`; a 403 or `remaining < 100`
  backs off to the 5-minute tick for the rest of the hour and counts it.
  Foreground only. Exempt from `canvasGradesMinInterval` by construction (it
  never calls the grades fetch); the 15-minute throttle on
  `refreshCanvasGrades` is untouched.
- The throttle lift (brief item c): `refreshSessionSourcesAtLaunch` and the
  `.active` branch of `onChange(of: scenePhase)` run one planner-window read
  at once when `LastHourPoll.insideTheHour` says an alarm is within the
  hour, before the grades fetch and without regard to its throttle; the
  `.refresh` background wake does the same after `refreshCanvasGrades` and
  before `replan` (the plan's Phase 4 bypass; the 48-hour measurement
  itself is a device step, listed under Known gaps).
- Tests: `LastHourPollerTests` (cadence inside/outside the hour against a
  fake client and a fixed clock; a `submitted: true` planner item for a
  card produces exactly that card's cancellation end to end; a rate-limited
  answer changes no state and records the back-off; no call outside the
  hour); `PlannerWindowClientTests` (the request's path and window, the
  header read); `LaunchRefreshStructureTests` additions (the launch and
  foreground reads sit before the grades fetch; the wake's poll sits after
  `refreshCanvasGrades` and before `replan`; both go through
  `applyPlannerWindow`).

### 1d. Docs and gate (3 h)

CLAUDE.md (What the app does → Profile → reminders: cancel at observation,
the quiet rules by name, "an unknown read is not an unsubmitted one";
Background: the last-hour poll, its cadence and back-off, the throttle lift;
Commands: `debugWakeLogV1` and `sweeperCountsV1`; Test baseline; Known gaps:
the device checks and the rate-limit headers still to read off a phone;
Traps: "an unknown read is not an unsubmitted one"), ROADMAP.md (Release 1
from Now to Done recently; the pooled-verdict seam to Next), then the
gate. `docs/PRIVACY.md` does not change in phase 1: nothing new leaves the
phone.

**Acceptance for phase 1.** The suites above green in `swift test
--no-parallel` alone; the count rises by exactly the new tests and falls by
none; the unsigned iOS build succeeds (the wake path is `#if os(iOS)`); a
grep shows `markCompleted` is not reachable from any cancel path; the
Sweeper page's `nextSweep` and `plannedAlarms` still agree.

## Phase 2: the server wake

Two halves that touch no common Swift or TypeScript file, so they are
built in parallel and gated together. About 30 hours.

### 2a. Backend (12 h)

- Migration `backend/supabase/migrations/20261118090000_sweeper_wake.sql`,
  re-runnable: the `sweeper_wakes` table exactly as the design's §2.2
  (`device_token` primary key, `user_id` cascading from `auth.users`,
  `environment`, `moments timestamptz[]`, `plan_hash`, `updated_at`,
  `last_sent_for`, `failures`), RLS on, revoked from `anon` and
  `authenticated`, granted to `service_role`, a user index; `create
  extension if not exists pg_cron` and `pg_net`; the `cron.schedule` of the
  design's §2.3 reading the tick URL and the tick secret from
  `vault.decrypted_secrets` (`sweeper_wake_tick_url`,
  `sweeper_wake_tick_secret`; created by hand, never in the migration),
  `timeout_milliseconds := 5000`; and one SQL function
  `claim_sweeper_wakes(at timestamptz, limit int)` that does the design's
  claim in one statement (`update … set last_sent_for = $1 where $1 = any(moments)
  and last_sent_for is distinct from $1 returning device_token, environment,
  user_id`). The sql-check gains the migration and an idempotency line, and
  `test/rls.test.sql` pins the column list and that `anon` and
  `authenticated` cannot read the table.
- `F/_shared/apns.ts`: the APNs client. `signProviderToken(key, keyID,
  teamID, now)` (ES256 through `crypto.subtle` over the PEM imported as
  PKCS#8; `kid` header, `iss` and `iat` claims), a 50-minute cache per
  isolate, `sendBackgroundPush(token, environment, deps)` with the exact
  headers of the design's §3.3 (`apns-push-type: background`,
  `apns-priority: 5`, `apns-topic`, `apns-expiration: now + 120 s` in unix
  seconds, `authorization: bearer`), body `{"aps":{"content-available":1}}`,
  the host by environment, and `readAPNsAnswer(status, body)` mapping Apple's
  reasons to the design's §3.4 table (`ok`, `badToken`, `remint`, `unregistered`,
  `tooMany`, `serverError`). Injectable `fetch` and clock.
- `F/_shared/sweeperWake.ts`: validation (`validateWakeBody`: hex token 64
  to 200, `environment`, at most 24 moments, each a whole minute in `(now,
  now + 48 h]`, past dropped, over-horizon refused, `plan` 16 hex or absent,
  any other key → `forbidden_field`), the store interface (`upsert`,
  `deleteAll(userId)`, `claim(minute, limit)`, `markFailure`,
  `deleteToken`, `pruneMoments`) with a PostgREST implementation and an
  in-memory one for tests, and `runTick(deps)`.
- `F/sweeper-wake/index.ts`, `verify_jwt = false` in `config.toml` and in
  `deploy-function.mjs`'s `PUBLIC_SLUGS` (the `agent-auth` / `mcp` shape):
  `POST /` with `{ action: "put", token, environment, moments, plan }` or
  `{ action: "delete" }`, both through `requireUser` and
  `enforceMinimumVersion` with the header **required** (`headerOptional:
  false`, a new function has no old callers); `POST /tick` refused without
  `x-sweeper-tick-secret` equal to `LHF_SWEEPER_TICK_SECRET`, claims rows
  for `date_trunc('minute', now())` and the minute before, answers `202
  {"claimed": n}`, sends inside `EdgeRuntime.waitUntil` with a concurrency of
  32, prunes moments more than 5 minutes past, logs one line of counts.
  `LHF_SWEEPER_WAKE_DISABLED=1` makes `/tick` a no-op `200 {"disabled":
  true}` and `put` answer `{"stored": 0}` without writing. **Departure from
  the design, for the phone's sake:** the design's `PUT` and `DELETE` are
  `POST` with an `action`, because `BackendClient` has one wire (`post`)
  and `agent-snapshot` already uses that shape; the semantics are the
  design's.
- Secrets contract (names only, no values anywhere): `LHF_APNS_KEY_P8_PRODUCTION`,
  `LHF_APNS_KEY_ID_PRODUCTION`, `LHF_APNS_KEY_P8_SANDBOX`,
  `LHF_APNS_KEY_ID_SANDBOX`, `LHF_APNS_TEAM_ID`, `LHF_APNS_TOPIC`
  (`com.lhf.lowhangingfruit`), `LHF_SWEEPER_TICK_SECRET`,
  `LHF_SWEEPER_WAKE_DISABLED`. Two keys because Apple now scopes team keys
  per environment (design §11.1).
- `deleteUserData` gains `sweeper_wakes` (so `delete-account` and the
  Canvas disconnect remove the row); `deploy-agent.mjs`'s pattern is reused
  as `deploy-sweeper.mjs` (migration, then `sweeper-wake` and
  `delete-account`), never run here.
- `backend/PROTOCOL.md`: the new section "The Sweeper wake (`sweeper-wake`)"
  after the agent connection with the routes, bodies, answers, validation,
  the table and its "no column may hold…" sentence, the APNs request
  verbatim, Apple's answers, the claim rule, the kill switch; Principle 2
  gains the clause; the service-role-only table count goes to seven;
  Limitations gains "delivery is Apple's best effort, a 200 is acceptance".
- Deno tests: `sweeperWake.test.ts` (validation table, `forbidden_field`,
  the claim through the memory store, idempotent double tick, prune),
  `apns.test.ts` (the signed token's header and claims against a generated
  P-256 key; the request's headers and body against a fake `fetch`; each
  Apple answer's mapping; the remint-once rule; a 410 deletes the row; three
  failures delete the row), `sweeperWakeHandler.test.ts` (the three routes
  against fakes: a wrong tick secret is 403, the kill switch, a missing
  version header is 426, the delete path), `deleteAccountHandler.test.ts`
  gains the table; `sql` tests under Docker.

### 2b. Phone (14 h)

- `LK/Alarms/SweeperWakePlan.swift`: `moments(from: [PlannedAlarm], now:)
  -> [Date]` (fire − 15 min and fire − 3 min, truncated to the minute,
  deduplicated, sorted, past dropped, cut at 48 h and at 24 nearest first)
  and `planHash(_:)` (first 16 hex of SHA-256 over the sorted ISO moments
  joined by `|`). Tests: two alarms in one minute make one pair; the 48 h
  cut; the 24 cut; past dropped; the output holds nothing but dates; the
  hash is stable and changes with one moment.
- `FeatureFlags.sweeperWake` (true; see "What Marco and Olisa own").
- `LUI/SweeperWakeClient.swift` over `BackendClient.post("sweeper-wake", …)`
  with the `put` and `delete` bodies; `AppState+SweeperWake.swift`:
  `noteDeviceToken(_ hex: String)` (memory plus `sweeperWakeTokenV1`),
  `sweeperWakePass(force:now:)` with the gates (backend configured, Penn
  install past onboarding, `FeatureFlags.sweeperWake`, reminders on,
  `loudAlertEnabled`, a token known, foreground only, not fixture data), at
  most every 10 minutes unless the plan hash or token changed, sending
  `moments: []` when nothing is armed, remembering `sweeperWakeEverSentV1`;
  `deleteSweeperWake()` on reminders off, the Sweeper switch off, every
  class excluded (as an empty `put`), Canvas disconnect and the flag off
  while `sweeperWakeEverSentV1` is set. The pass runs from
  `settleAfterFetch` after the replan. `SweeperWakeRules.shouldSend` is the
  pure gate with a fixed clock, tested.
- `App/LHFApp.swift`: an `@UIApplicationDelegateAdaptor` (iOS only) with
  `didRegisterForRemoteNotificationsWithDeviceToken` (bytes → lowercase hex →
  `noteDeviceToken` through `LiveAppStateRegistry`), `didFailToRegister…`
  (count only), and `didReceiveRemoteNotification(_:fetchCompletionHandler:)`
  (the completion-handler form, never the async form: CLAUDE.md → Traps,
  the notification-tap crash). `registerForRemoteNotifications()` at every
  foreground that passes the gates (no permission prompt).
- `LUI/BackgroundRefresh.swift`: `run()` becomes `runWake(.refresh)`;
  `runWake(.push)` does only: `beginWake` (the `.background` context, so
  `backgroundMayUseCredentials` and the never-latch guard apply, never a Duo
  push), the session check (dead or clock-expired → count, `.noData`), the
  planner window read, `applyPlannerWindow`, the canceller, `replan` with
  `rescheduleWithoutPrompting`, the `push` log line and counts, then the
  completion handler exactly once inside a 25-second timeout. No feed sync,
  no grades fetch, no course material, no Ed, no turned-in drain, no
  renewal with the saved password. The Gradescope leg of the design's §4.2
  step 7 is included only as a call into the course-table scrape
  `GradescopeClient` already has, for at most three courses with a
  Gradescope-only armed item in the window; `syncGradescope` is not changed.
- `project.yml` and `App/Info.plist`: `remote-notification` beside `fetch`
  in `UIBackgroundModes`, pinned by a test in the `VoiceDictationTests`
  shape (`SweeperWakePlistTests`); `App/LHFApp.entitlements` gains
  `aps-environment` = `development` (Xcode rewrites it at archive).
- `docs/PRIVACY.md`: the design's §5 three edits, in the same commit as the
  registration code. `docs/appstore/REVIEW_NOTES.md`: two sentences.
- Tests: `SweeperWakePlanTests`, `SweeperWakeRulesTests` (gates, the
  10-minute / changed rule, every delete path, fixture data never sends),
  `SweeperWakeClientTests` (the two bodies against a `URLProtocol` stub;
  nothing but token, environment, moments and plan on the wire),
  `PushWakeTests` (each verdict's effect on a fake scheduler; no session →
  nothing; the handler is called once on timeout; a source scan that the
  push wake calls none of the forbidden passes and that the token reaches
  no log line), `SweeperWakePlistTests`, `LaunchRefreshStructureTests`
  additions for `runWake`.

### 2c. Docs and gate (4 h)

CLAUDE.md (What the app does → Background: the push wake; Profile →
reminders: what is uploaded; the backend list: fifteen functions; Commands:
the `push` tag; Known gaps: everything that needs the APNs key and a phone;
Test baseline), ROADMAP.md (the server-wake entry from Next to Done
recently, with what is unverified), PROTOCOL.md and PRIVACY.md as above,
then the gate: `swift test --no-parallel` alone, the unsigned iOS build,
`deno task test`, `deno task check`, `sql-check.sh`.

**Acceptance for phase 2.** Every suite above green; the Swift count
accounted for; the Deno count accounted for against 902; the function
type-checks; the migration applies twice in Docker and the RLS test
passes; `deleteUserData` deletes the row; a grep of the backend shows no
log line that prints a token, a user id beside a token, or a moment; the
phone's wire carries exactly four keys.

## What is unverified until Olisa's APNs key and a phone

Stated plainly, so nobody reads the gate as proof of delivery:

- That Apple accepts the provider token and the push (needs the `.p8`,
  Key ID and Team ID in the Supabase secrets, Olisa's step; the probe
  `backend/scripts/sweeper-wake-e2e.mjs` of the design's §8 is written
  with the backend and run only at Marco's deploy go).
- That the Edge runtime's `fetch` negotiates HTTP/2 to Apple (the probe's
  first question; the Vercel-front fallback is not built until it says no).
- That `pg_cron` and `pg_net` are enabled on the project and the two Vault
  secrets exist (Marco or Olisa, by hand, never in a migration).
- That the device build signs with `aps-environment` (Push Notifications
  must be enabled on the App ID `com.lhf.lowhangingfruit`; Xcode's
  automatic signing can add it when the account's role allows, otherwise
  Olisa does it in the portal). If the signed build is refused for it, the
  entitlement line is the one to remove until the capability exists;
  the app then counts `didFailToRegister` and runs as Release 1.
- That a push wakes the phone, how often, and that the 30-second budget
  holds (the `push` lines in `debugWakeLogV1`, read off the plist).
- The rate-limit headers Penn's Canvas returns to the planner poll
  (`X-Rate-Limit-Remaining`, `X-Request-Cost`), to be written into CLAUDE.md
  from the first real response.
- Every device check of the two briefs (the 2026-11-03 case end to end).

## What Marco and Olisa own

- Marco: the App Store privacy label, one change: Identifiers → Device ID,
  "App Functionality", "Linked to the user", "not used for tracking". The
  deploy go for the migration and `sweeper-wake` (and `delete-account`,
  which shares `deleteUserData`). Whether `FeatureFlags.sweeperWake` ships
  `true` (the default here) or is flipped at archive time if the key is
  not in place.
- Olisa: the two APNs keys (Production and Sandbox), Push Notifications on
  the App ID, the `.p8` files into the Supabase secrets named above; yes or
  changes to the `docs/PRIVACY.md` paragraph.

## Hours

| Phase | Hours |
|---|---|
| 0 plan | 1 |
| 1a rules and tests | 4 |
| 1b cancel at observation | 4 |
| 1c last-hour poll, throttle lift | 5 |
| 1d docs and gate | 3 |
| 2a backend | 12 |
| 2b phone | 14 |
| 2c docs and gate | 4 |
| total | 47 |
