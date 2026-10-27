# Hardening plan: crashes, sign-outs, lost work, silent failures (2026-10-25)

**What this is.** On 2026-10-25 the whole tree at `origin/v8` `e3a57b3`
(the 3.2.1 (15) line plus that day's tree commits) was audited for one
question: where can Smooth crash, sign a student out, lose something the
student did, or fail without saying so. Ten read-only auditors each took
one area:

- Canvas session renewal.
- Interactive sign-in, plus the Gradescope and Ed sessions.
- A crash sweep of the Kit.
- A crash sweep of the UI, app and widget.
- Ledger integrity.
- Sync and networking.
- Notifications, alarms and the widget.
- The Supabase backend.
- Security, privacy and App Review.
- Hangs, memory, and screens that trap the student.

An eleventh agent ran every gate. Every claim was traced to a `path:line`
in that checkout. Paths below are relative to
`LowHangingFruitKit/Sources/LowHangingFruitUI/` (UI),
`LowHangingFruitKit/Sources/LowHangingFruitKit/` (Kit) or `backend/supabase/`
unless written in full.

Items marked ✔ were re-read in the code by the reviewing session. Items
without it are the auditor's reading, with the auditor's confidence. Nothing
was changed, installed on a phone, or deployed.

**The headline.** The code is in better shape than "never fail" fears:

- The audit found one crash, described under "The sixteen to fix first".
- The Swift 6 isolation work holds everywhere it was checked: the delegates,
  the background handler, voice dictation, WebKit.
- None of the old traps has come back: background-refresh isolation,
  `NLEmbedding` blocking, the unsized `Color.clear`.

What the audit did find matters more to this app's promise than crashes.
There are paths that:

- lock a student out of their own dashboard;
- sign them out of Gradescope without a word;
- delete their completions on purpose;
- ring alarms for work already handed in.

There is also a backend that anyone with the app can spend money through or
write into. Those are the plan.

**What "never fail" can honestly mean.** No app can promise that Penn's
identity provider never changes, or that Duo never asks again: it asks
about once a month, by design. What this plan can make true, each with a
test and a device check:

1. **No crash from anything a school, a server or a student can type.**
   No trapping constructor (`Dictionary(uniqueKeysWithValues:)`, a reversed
   range, `Int(Double)`) runs on outside data, and the parsers are fuzzed.
2. **A sign-in prompt only when a person is needed.** None of these ever
   reads as "signed out": being offline, a slow identity provider, a killed
   WebView, a refused Keychain read, or the app being left mid-attempt.
3. **Nothing the student did is deleted**, whether by sync, disconnect,
   reconnect, a reinstall, a bad decode, or a race.
4. **Every failure is visible somewhere**, at least as a timestamp an owner
   can read, and alarms are always planned from fresh state.

## Where it stands: the gates, 2026-10-25, on Marco's Mac

**`swift test --no-parallel`: 2906 of 2907 Swift Testing tests pass, across
262 suites, plus all 4 XCTest cases.** The one failure is
`AskCitationLinkTests.requestBytesUnchanged`. Its golden request was re-typed
by hand in `aeaf982` and reads `America/New_York`, while `JSONEncoder` writes
`America\/New_York`. It fails alone too. Fix the golden, not the encoder.

**iOS Release, unsigned, app plus widget: builds.** It has 11 concurrency
warnings, none on a proven crash path:

- `GradeReportView.swift:348` calls a main-actor `static func` on a View from
  nonisolated code. This is the pattern recorded in Traps.
- `RedesignTokens.swift:645-651` (haptics).
- `LoginUserAgent.swift:25-32`.

**`deno task check` / `deno task test`: red on Deno 2.9.8.** There are five
`TS2322 Timeout` errors:

- `_shared/outcomes.ts:161`
- `_shared/quota.ts:219` and `:327`
- `ask/index.ts:221` and `:881`

CLAUDE.md records the first three. The two in `ask/index.ts` are new. With
`--no-check`, all 468 tests pass.

The Swift count is up from 2885/260 on 2026-10-23. The Mac was in Low Power
Mode with swap nearly full, and the iOS build took 44 minutes.

## The sixteen to fix first (every one ✔)

1. **Reconnecting can lock the student out of their own dashboard.** Four
   auditors found this independently.
   - Where: `AppState.swift:3733-3736` saves `hasCompletedOnboarding = false`
     to disk. `OnboardingView.swift:344-352` gives the Canvas step only a back
     chevron to the school picker.
   - What happens: the student taps "reconnect canvas" with no signal,
     without their Duo phone, or quits mid-login. Every relaunch is then the
     first-run walk. The only other way out is preview mode, and leaving
     preview wipes grade history (`AppState.swift:3748`,
     `GradeWatcherStore.swift:442-450`).
   - Sign-off: Marco (sign-in UI).
2. **One crash, on every launch, from two Canvas assignment groups whose
   names reduce to the same id.**
   - Where: `Kit/Grades/GradeCategoryMapBuilder.swift:77` builds category ids
     as `"map:" + slug(name)`. `Kit/Grades/GradeEngine.swift:181-196` and
     `Kit/Grades/GradeRegrouper.swift:151` key `Dictionary(uniqueKeysWithValues:)`
     on those ids, and a duplicate key traps.
   - Trigger: "Homework" and "homework", or "Quiz (EC)" and "Quiz - EC".
   - Reach: every successful Canvas grade fetch gets there
     (`GradeWatcherStore.swift:330` → `:1745` → `:544`). That fetch runs in
     Release even though Grade Watcher is hidden. Reinstalling doesn't help.
   - Sign-off: none needed.
3. **The analytics-cookie sign-in bug is still live.**
   - Where: `SessionCookieStore.swift:121-123` keeps any cookie whose own
     expiry is ahead, and `isExpired` (`:163-165`) is "saved, but `load`
     returns nothing".
   - The harvests still save analytics cookies:
     `CanvasSessionRenewer.swift:748` keeps every domain containing "canvas",
     and `OnboardingView.swift:1029` keeps everything on `canvas.upenn.edu`.
   - What happens: `_ga` (13 months) keeps `load` non-empty, so renew-on-open
     never fires and requests go out with analytics cookies and no session.
     This is ROADMAP's "piece 1", open since 2026-10-08.
   - Sign-off: Marco and Olisa.
4. **Gradescope signs itself out after any 24-hour gap, silently and for
   good.**
   - Where: `SessionCookieStore.swift:194` gives Gradescope the 24-hour clock,
     and nothing ever renews Gradescope. On an empty set,
     `AutoSyncCoordinator.swift:31-32` turns `isGradescopeConnected` off.
     `needsGradescopeConnection` has no reader, so nothing on screen changes.
   - What happens: Gradescope items go stale, and reminders and alarms ring
     for work already handed in. That is ROADMAP's PHYS 0151 symptom.
   - Sign-off: Marco and Olisa.
5. **Keychain writes delete first and never check the add.**
   - Where: `SessionCookieStore.swift:283-293`, and the same in
     `ICSFeedURLStore`, `EdSessionTokenStore` and `BackendIdentityStore`.
     Reads return `[]` for any error (`:270-280`).
   - What happens: one refused write loses the session or the calendar-feed
     URL. One refused read looks like "no cookies", which raises the banner or
     mints a new backend account.
   - `PennKeyCredentialStore.save` already does it right.
   - Sign-off: Olisa (review).
6. **Disconnecting Canvas, and switching school, deletes every completion,
   the Done history and the grade history.**
   - Where: `AppState.swift:3929-3942` calls `assignmentStore.purge(source:)`,
     which deletes finished rows too (`Kit/Persistence/AssignmentStore.swift:317-320`),
     and then `gradeWatcher.clearAll()`.
   - The confirmation (`SettingsPage.swift:72`) doesn't say so. Disconnect is
     also the only repair a stuck student can reach.
   - Sign-off: Marco (product).
7. **Deleting and reinstalling erases the ledger, but keeps the password.**
   - The ledger lives in the App Group container, which iOS removes with the
     app. That is platform knowledge, to confirm on a device.
   - The Keychain survives deletion. The code says so itself at
     `AppState.swift:4057-4062`.
   - `docs/PRIVACY.md:276-277` promises that deletion removes the
     Keychain-stored sessions, which is false.
   - Sign-off: Marco (policy).
8. **A background wake never re-plans reminders or alarms.**
   - Where: `BackgroundRefresh.swift:170-215` syncs and can post "Turned in ✓",
     but never calls `reschedule`. Its only callers are
     `ContentView.swift:452,731` and `LHFScenes.swift:106`.
   - What happens: work handed in while the app is closed still rings, and a
     deadline moved earlier rings late.
   - Sign-off: none needed. Mind that a background wake must not prompt for
     permission.
9. **Declining notifications also switches off the AlarmKit alarm.**
   - Where: `NotificationScheduler.swift:343` returns before alarms are
     considered.
   - AlarmKit is a different permission, and declining notifications is the
     commonest onboarding answer.
   - Sign-off: none needed.
10. **A failed Penn connect leaves a spinner that never clears.**
    - Where: `OnboardingView.swift:886` and `:1114-1129`. The no-op is
      deliberate, copied from `39b2fff`, but `reachedSignedInDestination`
      stays true and the pane never shows `state.error`.
    - Sign-off: Marco and Olisa.
11. **No WebView recovers when iOS kills its web process, and login errors
    are never shown.**
    - There is no `webViewWebContentProcessDidTerminate` anywhere in the app.
      `LoginNavigationObserver`'s `loadError` and `detectedKnownErrorPage` are
      published but no view reads them.
    - What happens: leaving for Duo Mobile is the usual trigger. The student
      gets a blank pane, or a hidden renewal waits out its 30 seconds and
      records the wrong verdict.
    - Sign-off: Olisa.
12. **Aging deletes an item by the feed's date while the student's own
    edited date is still ahead.**
    - Where: `Kit/Persistence/AssignmentStore.swift:529-534` reads only
      `row.dueAt`. `AppState+DueDateEdits.swift:156-169` then prunes the edit.
    - What happens: a granted extension that Canvas stops listing vanishes.
    - Sign-off: Olisa (reconcile).
13. **`ask-canary` lets any app user pick the model and the token cap on
    LHF's OpenRouter key.**
    - Where: `functions/ask-canary/index.ts` and `_shared/probe.ts:61-97`. An
      anonymous JWT passes.
    - Sign-off: Olisa (deploy).
14. **The usage functions are revoked from `public` only.**
    - Where: `migrations/20260907000000_init.sql:180,212` and both
      `ask_outcomes` migrations.
    - If Supabase's default grants to `anon` and `authenticated` still stand
      (one read-only query settles it, under "Backend" below), anyone can
      inflate the global monthly counter and switch ask off for every student
      until the 1st.
    - Sign-off: Olisa.
15. **`PasteFeedLinkSheet` has no caller.** The documented fallback for a
    failed connect does not exist, though CLAUDE.md → What the app does says
    it does.
    - Sign-off: Marco.
16. **The dashboard rebuild pairs Canvas with Gradescope over the whole
    ledger history, and partly twice.**
    - Where: `AppState.swift:7328-7340` says the heuristic "isn't run a second
      time inside `merge`". It is, for every unpaired item
      (`Kit/Models/AssignmentDeduplicator.swift:440`).
    - Each pair runs five regexes per title (`:815-823`), and a refresh
      rebuilds 5–15 times on the main actor.
    - It grows every semester, which makes it the likeliest future freeze.
    - Sign-off: none needed.

The backend auditor rated three more as P0. These were not re-read by the
reviewing session:

- **BE-02.** The ask quota is checked before the stream and charged only
  after a clean finish, so parallel requests and early disconnects go
  uncounted.
- **BE-04.** Anyone can enroll in any course id, then overwrite, retire, or
  mark fresh that course's pooled material for every classmate.
- **BE-05.** There are no write caps.

## Who signs off on what

Marco's standing rules:

- Behaviour proven on a real phone is kept unless the evidence says it's
  broken.
- The sign-in, sync and Ed code in `v8` is Olisa's, and changes only on
  Marco's say, with Olisa reviewing.

Items 3, 4, 5, 6 and 10 above each carry device evidence or a code proof.
That is the evidence the rule asks for, so they are ready to put to both
owners.

| Who decides | Items |
|---|---|
| No sign-off needed | A1, A10, B4, B7, B9, B10, B14, B15, C1, C2, C4–C6, C9, D1–D3, D5, D7, D8, P3, P5 except the fill script, the gates |
| Marco, product or copy | A2, B1, B2, C3, C8, C10, "Making failures visible" |
| Marco and Olisa: sign-in, sync, Ed, announcements, the extension | A3–A9, B3, B5, B6, B8, B11–B13, C7, D4, D6, BE-G, P2, P4, P5's fill script, DAT-14 |
| Olisa's deploys | every backend item |

## The plan

The plan is in four app releases plus backend and privacy tracks. Within a
release, the first item comes first. Every item names its finding IDs; the
appendix has them all.

**Suggested order for the next few days:** A1 and the gates (cheap, removes
the crash); backend step 0, BE-A and BE-B (cheap, big); P1 (text only).
Then put A2–A9 to Marco and Olisa as one 3.2.2 sign-in round, built and
proven on both phones with `docs/SIGNOUT_VERIFICATION.md`.

### Release A: never locked out, never signed out (3.2.2)

**A1. Remove the duplicate-key crash.** Findings: KCR-01, UCR-15, KCR-16,
UCR-11.
- Make category ids unique where they are made: in
  `GradeCategoryMapBuilder.mirroringCanvas` and in the syllabus scheme path
  (`Kit/Syllabus/SyllabusModels.swift:125`), suffix the Canvas group id when
  two slugs collide.
- Replace every `Dictionary(uniqueKeysWithValues:)` keyed on ids from Canvas,
  Gradescope or a syllabus with `uniquingKeysWith:`. That covers the Kit grade
  code, `GradeWatcherStore.swift:789,1646-1647`,
  `AssistantContextAssembly.swift:189` and `AssignmentDeduplicator.swift:447-448`.
- Same pass:
  - Clamp before `Int(...)` in `Kit/Grades/GradeExplanation.swift:269,280`.
  - Capture `Date.now` once in `LHFWidget/BerserkAlarmActivity.swift:104-106`.
  - Mark `GradeReportView.truncatedName` `nonisolated`.
- Test: a course with "Homework" and "homework" groups, through
  `GradeWatcherStore.refresh` and `breakdown`.

**A2. Make reconnect a cover over the dashboard.** Findings: SES-001,
LOG-1, UCR-1, PRF-04, PRF-05, SEC-06.
- For `.canvas` and `.gradescope`, present the login pane over the dashboard
  with a close button. Never write `hasCompletedOnboarding = false` for those
  two destinations. `.full` keeps its current behaviour.
- Hide the "preview with sample data" footer once a real Canvas is connected.
- Make leaving preview clear only the fixtures, never `historyStore`.
- Wrong fixes:
  - A skip on the first-run Canvas step, which must stay required.
  - Removing the first-run preview link, which is App Review's only way in.
- Test: `restartOnboarding(for: .canvas)` leaves the saved flag true.
- Device: tap the banner in airplane mode, force-quit, reopen. The dashboard
  should be there.

**A3. Decide "expired" by whether a fresh session cookie is left.** Findings:
SES-002, and ROADMAP piece 1.
- In `SessionCookieStore.load(service: .canvas)`: if a session-named cookie was
  ever saved and none is fresh under the 24-hour rule, return `[]`. That makes
  `isExpired` true, and renew-on-open runs exactly as `39b2fff` proved on two
  phones.
- Stop saving analytics cookies at both harvests too. But the read-time rule
  is what heals phones that are already polluted.
- An uncommitted attempt sits in the main checkout's working tree
  (`fix/canvas-signin-bulletproof`, with `SessionCookieLiveSessionTests.swift`
  untracked). It has the right shape. Port it as a wrapper around v8's
  `isStale(capturedAt:now:service:)`, leave the renewer untouched, and add
  tests through `merge` and `save`.
- Device: on Marco's phone, run `-LHFSessionDiagnostics` (is the phone still
  polluted?), then `-LHFAgeCanvasSession`. Expect
  `canvasSessionExpired false -> true` in `debugRenewalLogV1` and a renewal
  during that launch.

**A4. Keep Gradescope connected.** Findings: SYN-01, LOG-2, SES-008, SYN-04,
SYN-05.
- `maxAge(for: .gradescope)` becomes `nil`, as Ed's already is. Gradescope's
  server decides when its session is dead, and nothing on the phone can renew
  it anyway.
- Never call `setGradescopeConnected(false)` on an empty cookie set or a single
  failure.
- Raise a saved `gradescopeNeedsReauth` only after a page shaped like a login
  form, meaning a password input rather than the keyword match in
  `Kit/Gradescope/GradescopeClient.swift:461-466`. Require it on two runs at
  least an hour apart. A bare 403 doesn't count.
- Keep the rows and the cookies, and show one reconnect line like Canvas's.
- Surface `wasSuspectedPartial`. Refuse a per-course "had rows, now none", and
  don't prune in the same call that flags.
- Wrong fix: raising 24 hours to seven days. That is still a clock that can
  only sign the student out.
- Device question first: age a Gradescope cookie by 25 hours, kill the app,
  reopen. Does the server session survive?

**A5. Make Keychain writes safe, and give reads three answers.** Findings:
SES-010, LOG-11, UCR-7, SEC-15, part of SYN-06.
- Write one helper for all seven stores:
  1. `SecItemUpdate` first.
  2. `SecItemAdd` only on `errSecItemNotFound`.
  3. Check and count every status.
- Reads return found, not found, or unavailable (with the `OSStatus`).
  Unavailable never means signed out, never triggers a write-back, and never
  mints a new backend identity.
- `PennKeyCredentialStore.save` is the model.

**A6. Show the banner only when a person is needed, and judge outcomes
fairly.** Findings: SES-003, SES-004, SES-009, LOG-4, LOG-5, SES-015. This is
ROADMAP piece 2, the one Marco asked to see as a plan first.
- An attempt counts only if the app stayed `.active` throughout and its
  WebView was not killed. Anything else is `.timedOut`, which never latches.
- Implement `webViewWebContentProcessDidTerminate` in the renewer, the login
  pane and the Ed launcher.
- "Password rejected" only on Penn's own error state after our submission.
  The form simply reappearing doesn't count: that also happens after a Duo
  deny, a flow expiry, or a rebuild.
- `autoLoginAwaitingDuo` expires after 24 hours and is cleared by `.renewed`.
  Today `StayLoggedInTests:366` pins that `.renewed` does not clear it.
- The banner shows only when:
  - the password was rejected, or
  - Duo is needed in the foreground, or
  - there is no saved password and two landings came at least an hour apart,
    or
  - there are no cookies at all.

  A clock-expired session that can still be renewed silently shows nothing.
- The login pane shows its `loadError` and known-error card, with "try again".
- Wrong fix: dropping the Duo latch. A retry would then push Duo to the
  student's phone every hour.

**A7. Never delete cookies because of a 401.** Findings: SES-006, SES-007.
- `GradeWatcherView.swift:352-364` deletes the Canvas cookie item when no
  course succeeded and one answered 401. A concluded or restricted course can
  do that on a live session (Traps: "Canvas answers 401 for 'not allowed'").
- Replace the delete with a liveness probe on `GET /api/v1/users/self`:
  - 200 with JSON: the session is alive.
  - 401, or a redirect to login: dead.
  - Anything else: unknown.
- Use the same probe before the renewer's `merge`, so a Canvas error page
  can't pass for `.renewed`.

**A8. A failed Penn connect shows its error and a retry.** Findings: LOG-3,
UCR-2, LOG-8.
- Keep `39b2fff`'s rule that the auto-login counter is not reset. But clear
  `reachedSignedInDestination`, show `state.error`, and offer "try again".
- Either wire `PasteFeedLinkSheet` in as the fallback, or delete it and the
  CLAUDE.md line about it.
- At other schools, cap the reset-and-retry at two, so a bouncing single
  sign-on can't loop.
- Add a "save pennkey" row while Penn is connected with no saved credential.
  Today the vault is reachable only after a rejection.

**A9. One renewal per process, and disconnect always wins.** Findings:
SES-005, UCR-3, UCR-8, UCR-9, LOG-10, SES-012.
- Keep a session generation, bumped by disconnect, school switch and an
  interactive login. Every write that comes after an `await` checks it first:
  cookie merge, flags, grade snapshots, the course-material upload, ledger
  inserts.
- Disconnect calls `abort()` and cancels the stored tasks.
- Around the renewer's late `didFinish`, re-check that the attempt is still
  in flight and that `activeWebView === webView`.
- The Ed launch is skipped while the login pane or a renewal is active,
  because it writes Keychain cookies into the shared login store.

**A10. One backend sign-in at a time.** Findings: SYN-06, UCR-5.
`BackendSession` keeps one in-flight `Task<String, Error>`, and every caller
awaits it. Today concurrent first callers can create two anonymous accounts,
and the first is orphaned.

### Release B: nothing the student did is lost

**B1. Disconnect keeps what the student did.** Findings: DAT-01, LOG-6,
UCR-10, LOG-9.
- Purge only unfinished feed rows. Keep finished and completion-only rows,
  stamped with the account they came from.
- Reconnecting as a different account (a different `users/self` id) archives
  that account's rows instead of mixing them.
- Keep grade history unless the account changes.
- Say what is deleted in one line of the confirmation. The disconnect
  confirmation is one of the texts Marco's minimal-copy rule keeps.

**B2. Decide what a reinstall does, then say it.** Findings: SEC-01, LOG-7,
DAT-05.

Recommendation: on a fresh install, meaning the App Group marker is missing
while Keychain items exist:

- Sweep the credentials: the PennKey password, cookies, the feed URL and the
  Ed token. A reinstall then really is a clean sign-in.
- Restore the student's own record from a small Keychain copy, written with
  each ledger save: completion ids and dates, manual and recurring tasks,
  and edited dates.
- Keep the anonymous backend identity, which holds nothing personal, so no
  account is orphaned.

`docs/PRIVACY.md` then says exactly that. The alternative is to sweep
everything and say a reinstall erases your history. Either way, today's
sentence has to go.

**B3. Aging respects edited dates.** Finding: DAT-02. Pass the edited ids
into `pruneAgedOut` and `isAgedOut`.

**B4. Un-ticking clears the whole twin set.** Finding: DAT-03.
`carryCompletion` (`AppState.swift:7136-7146`) re-completes a card on the
next rebuild while a hidden twin still holds the old completion. Fix
`markActive` (`:7730-7746`) and the device-sync equivalent, and record
carried pairs so a carry fires only once.

**B5. Save first, then forget.** Finding: DAT-07. Make the store's mutators
return success. Then record processed announcement and Ed ids, or remove
the legacy manual-task blob, only after a confirmed save
(`AppState.swift:5682-5685`, `:1127-1133`;
`AppState+EdAnnouncementTasks.swift:469-472`).

**B6. A read error is not an empty ledger.** Findings: KCR-02, DAT-10.
- `allRows()` (`Kit/Persistence/AssignmentStore.swift:477`) throws instead of
  returning `[]`.
- `reconcile`, `completionRecord` and the signup-backlog decision abort on a
  read error.
- Storage health counts read failures.

**B7. Merging duplicate rows keeps every completion.** Findings: KCR-03,
DAT-13. `absorb` ORs `userCompleted`, ANDs `isCompletionOnly`, copies display
fields from the real row, and breaks ties on a stable key.

**B8. One bad element can't cost a whole store.** Findings: KCR-06, KCR-08,
KCR-09, DAT-11.
- Use a lossy per-element decode for:
  - the course-knowledge documents (and move an undecodable file aside rather
    than overwriting it);
  - Ed threads and courses (`Kit/Ed/EdWire.swift:111,226-244`);
  - modules (`Kit/Canvas/CanvasModulesClient.swift:267`);
  - `CoursePreferences` maps;
  - recurring tasks and the manual blob;
  - grade overrides.
- A dropped page or element counts as a course error, so the course reads as
  partial and its stored documents aren't retired.

**B9. Grade history reports its own health.** Findings: DAT-08, KCR-14. A
versioned container, and its failures feed `StorageHealth`.

**B10. Taps survive a kill.** Findings: UCR-14, NOT-09, DAT-18.
- The swipe saves before the 0.38-second animation, not after
  (`AssignmentCardView.swift:399,423`).
- "Turned in" taps from the lock screen are written to `UserDefaults.lhf`
  until the dashboard consumes them (`NotificationResponseRouter.swift:24-40`).

**B11. iCloud preferences never delete another device's settings.** Finding:
DAT-09. `CloudPrefsMirror` never pushes a removal this device didn't
author, and merges on first enable.

**B12. Wrong pairings can be undone.** Finding: DAT-06. Keep the date-gap veto
when honouring stored pairings, and add a way to unlink.

**B13. One ledger store per process.** Findings: DAT-04, UCR-6, SYN-11. A
background wake in a warm process reuses the live `AppState` and its store,
instead of opening a second `ModelContainer` on the same file.

**B14. Rehearse the first schema change before it is needed.** Findings:
DAT-16, UCR-12, NOT-13.
- A frozen copy of the V1 model.
- A copy of the store file taken before migrating.
- A test against an on-disk V1 fixture.
- The widget opens the store with the same migration plan.

**B15. Dates that don't depend on settings.** Findings: DAT-12, KCR-10.
Derive a recurring occurrence's id from its local calendar date. Use the
Gregorian calendar for terms, rollover and syllabus dates.

### Release C: no missed alarm, no false alarm

**C1. The background wake re-plans.** Finding: NOT-01.
- After the wake's sync, cancel the alarms and buzzes of items that are now
  done (`BerserkAlarmPlan.finishedAlarmIDs` plus the pending ids). Re-plan
  without any authorization prompt.
- Wrong fix: calling `reschedule` unchanged. `resolveLoudDelivery` can call
  `requestAuthorization()` from the background.

**C2. AlarmKit authorization on its own terms.** Finding: NOT-02.
`NotificationScheduler.swift:343` must not cancel alarms because notifications
were declined.

**C3. Announcement finds don't ring.** Finding: NOT-03. Exclude
`isFromAnnouncement` from the loud alert and keep plain reminders for finds.
A find is a guess from prose, and ringing through Silent for a guess is the
wrong default. This is Marco's call.

**C4. Urgent reminders get slots first.** Finding: NOT-04. Reserve what fires
in the next ~48 hours, then round-robin the rest by class. In alarm mode,
free the 30 slots kept for buzzes.

**C5. Add before remove, and count failures.** Findings: UCR-4, NOT-10,
NOT-07.
- Diff against `pendingNotificationRequests()` instead of
  `removeAllPending()` then re-adding.
- Count failed adds.
- Isolate one alarm's failure in `BerserkAlarmEngine.reconcile` so it can't
  downgrade the rest.

**C6. Reminders that survive travel.** Finding: NOT-06. Set
`DateComponents.timeZone` on calendar triggers, or use interval triggers as
the loud alert already does.

**C7. Re-plan before the network.** Findings: NOT-12, SYN-08.
- At launch and on foreground, reload and reschedule from the ledger first,
  then again after the fetch.
- Give each sync stage a deadline, and use a session with a 15–20 second
  request timeout.
- Commit processed announcement ids per post.

**C8. An alarm that keeps sounding.** Finding: NOT-05. The default
`berserk-alarm.caf` is 12.9 seconds and plays once (CLAUDE.md:2715). Use a
file that covers the system ring, or add a second alarm a minute later.
Check on a device first.

**C9. Disconnect re-plans at once.** Today alarms survive a disconnect until
the student goes back to the dashboard (`AppState.swift:3862-3935`, CLAUDE.md:2743).

**C10. One quiet line when reminders can't arrive.** Finding: NOT-08. The
cases are notifications denied, Time Sensitive off, or reminders skipped in
onboarding. A label, not a sentence; the copy is Marco's call.

### Release D: no freezes

Measure first: add `os_signpost` around the `AppState.init` stages and the
`rebuildDashboardItems` phases, and run the Instruments App Launch template
on a six-class account.

**D1. Pair once, normalise once.** Finding: PRF-01. Normalise each title once
per rebuild, bucket by course, run the pairing once, and give `merge` an
overload that takes the finished pairs.

**D2. Cache the per-item predicates.** Finding: PRF-02.
- Compile regexes once, as statics.
- Memoise `isCourseSelected` per course per rebuild.
- Use one `Calendar` per pass.

**D3. Publish only on change.** Finding: PRF-03. Guard every `@Published`
assignment with `if new != old`, and keep diagnostics out of `@Published`.

**D4. Launch draws first.** Findings: PRF-07, PRF-08.
- Load `course-knowledge.json` after the first frame.
- Save it off the main actor.
- Drop the documents of courses the student is no longer enrolled in.

**D5. Every WebKit wait has a deadline.** Findings: PRF-09, LOG-15. Covers
`getAllCookies` at launch and the data-store purge before login.

**D6. One sync at a time.** Findings: SYN-09, PRF-13. A single-flight task
for each of `sync()`, `syncAnnouncements` and `refreshCourseIntel`, and one
refresh loop on the Mac, not two.

**D7. Lazy lists and snapshots.** Findings: PRF-10, PRF-11, PRF-12.
- `LazyVStack`, and a capped "earlier this semester".
- Snapshot the ask and megaphone inputs when they are presented.
- One announcement context per rebuild.

**D8. Bound text work.** Finding: KCR-13. Cap the ask question at about
2,000 characters before it is classified, and bound the Ed tag scan.

### Backend (every deploy is Olisa's go)

**Step 0: read-only checks, first.**

```sql
select proname, proacl from pg_proc where pronamespace = 'public'::regnamespace;
```

Then answer:
- Is `ask-canary` deployed?
- What credit limit and alerts does the OpenRouter key have?
- What is the anonymous sign-in rate limit, and is CAPTCHA on?
- What is the disk size, and is there an alert before read-only mode?

**BE-A. Close `ask-canary`.** Finding: BE-01.
- Undeploy it, or gate it on a secret header or an allow-listed user id.
- Clamp the model, `maxTokens` and provider server-side.
- In `parseAskRequestBody`, cap `contextDocument`, `excerpts` and history.

**BE-B. Revoke the usage functions properly.** Finding: BE-03.
- `revoke execute … from public, anon, authenticated`.
- Add matching default privileges.
- Make `test/rls.test.sql` reproduce Supabase's default ACLs, so it can catch
  this.

**BE-C. Reserve the quota atomically.** Finding: BE-02.
- Reserve before the model call (`update … where requests < limit returning`).
- Settle tokens in a `finally`.
- Abort upstream when the client goes away.
- Do the same in the `extract-*` functions.

**BE-D. Protect the pool.** Findings: BE-04, BE-07, SEC-04.
- Recompute `contentHash` on the server.
- Pin course and document URLs to `https://canvas.upenn.edu/courses/{id}` or
  an allow-list.
- Make freshness and retirement per user, or require more than one account.
- Rate-limit writes per account.
- On the phone, pin pooled URLs before showing or opening them.

**BE-E. Caps.** Finding: BE-05.
- Document count and bytes per course.
- Upload bytes per user per day.
- List-length caps.
- `device_sync_blobs` rows per owner.
- A retention job for `ask_outcomes` and for documents that are gone.

**BE-F. Restrict `discover-websites`.** Finding: BE-06.
- https and an allow-list only.
- Block private address ranges.
- Stream-read with a byte cap and a deadline.
- Re-check redirect targets.

**BE-G. Course-material sync, both sides (Olisa's sync).** Findings: SYN-02,
SYN-03, KCR-06, SYN-07, SYN-10.
- The phone keeps `.website` and `.file` documents, and the server never lets
  a phone retire crawl rows.
- Swallowed failures on the syllabus, page and module reads count as course
  errors.
- Uploads are split by bytes, and halved and retried on a 413.
- `lastSyncedAt` is stamped only when at least one source succeeded.

**BE-H. Robustness.**
- Validate per element into `rejected`, and answer 400 rather than 500
  (BE-10).
- Set `profile_stale` in the same step as the upsert (BE-09).
- Give the `device_links` lookup a deadline, or carry the link in
  `app_metadata` (BE-11).
- Charge `extract-profile` per course, with deadlines (BE-12).
- Make `delete-account` idempotent, and sweep abandoned anonymous users on a
  TTL (BE-14).
- Make the monthly quota query sargable (BE-15).
- Stop logging upstream error bodies (BE-16).
- Pin the `npm:` versions and ship a lockfile (BE-17).

**Gate.** Type the timers as `ReturnType<typeof setTimeout>`, so `deno task
check` is green on current Deno.

### Privacy and App Review

**P1. `docs/PRIVACY.md` and `docs/site/privacy.html`, in one commit.**
Findings: SEC-01, SEC-05, SEC-07, SEC-08, SEC-09. Correct:
- what a reinstall does (B2);
- the ask summary's completion state (either drop the status column or say
  so);
- iCloud sync;
- the per-request `ask_outcomes` rows, and the privacy label and manifest
  that should declare them;
- the extension and pairing.

Also remove the reference to the "Delete my class data" button, which no
longer exists. The public page is the one the store links to, so this is the
item most likely to matter at review.

**P2. Pairing shows a confirmation code.** Findings: SEC-02, BE-13.
- Show a short code derived from `K` and the pairing code on both screens.
- A pairing that arrives by link must be confirmed.
- Correct `docs/CHROME_EXTENSION.md:165-167`: the QR does contain the key.
- Bind the envelope to owner, device and version as associated data.

**P3. Links in ask answers.** Finding: SEC-03. Strip them, or install an
`OpenURLAction` that allows only the Canvas host and `edstem.org`.

**P4. The extension drops anonymous Ed posts.** Finding: SEC-10. Add a
parity test against `EdThreadFilter`.

**P5. Credentials only ever go to the right host.** Findings: SEC-12,
LOG-12, SEC-13, KCR-15, KCR-04, SYN-14, SEC-14.
- The fill script checks `location.protocol` and the host inside the script,
  and `isLoginForm` requires https.
- A redirect delegate strips `Cookie` and `Authorization` on a cross-host hop.
- Gradescope and discovery host-pin their cookie-bearing requests.
- `CanvasSyllabusClient.swift:183` sets `httpShouldHandleCookies = false`,
  like every other Canvas client.
- The Ed launch URL is pinned to the Canvas host.

**P6. Smaller items.**
- Log Release lines `.private` (SEC-17).
- Queue a failed server deletion and retry it (SEC-18).

### Making failures visible without adding text

Marco's rule is a label and a control, no prose, and DEBUG builds don't hide
text from him. So:

- **Release keeps the record, with no UI.** It writes
  `lastSilentRenewalSummaryV1`, plus a last-success time for each stage: feed,
  Gradescope, announcements, course material, Ed, and the reminder and alarm
  plans.
- **One quiet line, only when something has been stale for over a day.** For
  example "gradescope · reconnect", in the banner's slot.
- **Optional: an owner-only export.** For example, a long-press on the
  version number copies a redacted diagnostics block. A store build could
  then be diagnosed without installing a debug build over it. This is
  Marco's call.

### Tests and gates

- Fix the `AskCitationLinkTests` golden.
- Make Deno green on current Deno.
- Pin each A and B item with a test. Most of the findings have none today:
  nothing pins SES-001, SES-003, SES-006, KCR-01 or DAT-01.
- Add a small fuzz suite to `swift test` for everything that takes outside
  data:
  - ICS;
  - Ed wire;
  - modules;
  - grade groups with random duplicate names;
  - very long announcement text;
  - the version manifest.

  Each case must never trap and must finish within a time budget.
- Keep `--no-parallel` as the gate until the parallel Keychain hang is
  fixed.

### Questions only a phone can answer

In this order. Check first whether a Codex session has installed its own
build on Marco's phone.

1. Is Marco's saved cookie set still polluted (`-LHFSessionDiagnostics`)?
   After A3, does `-LHFAgeCanvasSession` renew on open?
2. Reconnect in airplane mode, force-quit, reopen (A2).
3. Leave for Duo Mobile mid-renewal, then return (A6).
4. Gradescope cookie aged by 25 hours: does the server session survive (A4)?
5. Background wake with an item due in about 20 minutes, submitted on the
   web first. Does the alarm still ring (C1)? Use
   `_simulateLaunchForTaskWithIdentifier:` on a debug build.
6. Leave each alarm sound ringing for 60 seconds (C8).
7. Deny notifications but allow alarms, and the reverse (C2).
8. Change time zone with a reminder pending (C6).
9. Delete and reinstall. Is the App Group container gone? Is the PennKey item
   still there (B2)?
10. Count pending notifications with six classes and every lead time
    (C4: should be at most 60).
11. Instruments App Launch and Time Profiler on a six-class account (D).

### CLAUDE.md lines the audit found stale

Corrected in the same commit as this file:

- background refresh "crashes on every wake", replaced by the missing
  re-plan;
- "a non-persistent ledger is invisible", replaced by what storage health
  does and doesn't cover;
- the Test baseline.

Also added: two Known gaps entries (the crash, and the reconnect lock-out)
and a pointer in ROADMAP → Now.

Left for the commit that touches each area:

- "this tier never deletes" (Architecture). `purge`, `pruneAgedOut` and the
  duplicate sweep all delete.
- The calendar-link paste (What the app does). It has no caller.
- "A failed Canvas announcement read is retried on every sync" (Known gaps).
  There is now a 3-attempt cap and a one-hour backoff
  (`AppState.swift:723-726,5651-5658`).
- The health lines "shown in Profile → accounts in plain words" (Stay signed
  in). They are DEBUG-only (`SettingsPage.swift:546-637`).
- The capture "dropped on a failed or cancelled navigation". Cancelled
  navigations deliberately keep it (`LoginNavigationObserver.swift:704`).
- Causes 2 and 3 of "Stay signed in is fragile in 3.0.0 (11)". Both are fixed
  in code. Cause 1 is A3.

## Appendix: every finding, by area

Severity uses the auditors' scale.
- **P0**: a crash, an unneeded sign-out, lost student data, a leaked
  credential, or (backend) an unbounded cost.
- **P1**: wrong or stale data, a silent failure, a likely race.
- **P2**: hardening.

"=" means the same issue as a numbered item above, or as another finding.

### Canvas session renewal (SES)

| ID | Sev | Finding | Where |
|---|---|---|---|
| SES-001 | P0 | = #1 reconnect lock-out | `AppState.swift:3733-3736` |
| SES-002 | P0 | = #3 analytics-cookie trap | `SessionCookieStore.swift:117-133,163-165` |
| SES-003 | P0 | Banner follows cookie age, not need; shows after an offline attempt | `AppState.swift:2972-2973`, `ContentView.swift:117` |
| SES-004 | P1 | Outcome judged by where the WebView sits at 30 s; no lifecycle; Duo latch never expires | `CanvasSessionRenewer.swift:533-541,679-683`, `AppState.swift:3237` |
| SES-005 | P1 | Disconnect doesn't cancel renewal or grade fetch; stale writes land after | `AppState.swift:3862-4005,2229,3811` |
| SES-006 | P1 | Grade Watcher deletes Canvas cookies on a store-level 401 | `GradeWatcherView.swift:352-364` |
| SES-007 | P1 | `.renewed` not authenticated; HTTP status ignored | `CanvasSessionRenewer.swift:716-760` |
| SES-008 | P1 | = #4 Gradescope 24 h | `SessionCookieStore.swift:192-197` |
| SES-009 | P1 | "Rejected" on the form merely reappearing | `LoginNavigationObserver.swift:863-875` |
| SES-010 | P1 | = #5 Keychain delete-then-add | `SessionCookieStore.swift:283-293` |
| SES-011 | P2 | Live WebView cookies override fresher Keychain ones | `AutoSyncCoordinator.swift:123-135` |
| SES-012 | P2 | Mutual exclusion per instance only | `BackgroundRefresh.swift:171`, `EdSessionLauncher.swift:104-149` |
| SES-013 | P2 | Release builds give no diagnosis | `SettingsPage.swift:546-637` |
| SES-014 | P2 | Mac menu-bar loop never retries renewal | `LHFScenes.swift:98-110` |
| SES-015 | P2 | Two slow-IdP timeouts count as dead; a clock rewind blocks retries | `CanvasSessionRenewer.swift:533-541`, `AppState.swift:2623` |
| SES-016 | P2 | Lockout bounds have gaps (slow rejection reads as landing) | `CanvasSessionRenewer.swift:533` |
| SES-017 | P2 | Keychain reads inside view bodies | `ContentView.swift:608`, `SettingsPage.swift:573` |

### Interactive sign-in, Gradescope and Ed sessions (LOG)

| ID | Sev | Finding | Where |
|---|---|---|---|
| LOG-1 | P0 | = #1 | `OnboardingView.swift:350` |
| LOG-2 | P0 | = #4, plus any 403 or a keyword false positive disconnects | `GradescopeClient.swift:32,461-466` |
| LOG-3 | P1 | = #10; other schools loop; `PasteFeedLinkSheet` dead | `OnboardingView.swift:886,1114` |
| LOG-4 | P1 | Any second sighting of the form latches "rejected" | `LoginNavigationObserver.swift:863,874` |
| LOG-5 | P1 | = #11 | `LoginNavigationObserver.swift:98-110` |
| LOG-6 | P1 | = #6; the server delete isn't retried, and school switch skips it | `SettingsPage.swift:420-427`, `AppState.swift:3799-3801` |
| LOG-7 | P1 | = #7 | `docs/PRIVACY.md:276-277` |
| LOG-8 | P1 | No way to (re)save the PennKey except after a rejection | `SettingsPage.swift:685` |
| LOG-9 | P1 | Reconnecting as another account mixes data; purge hints miss non-Duo IdPs | `AppState.swift:4190`, `Kit/Models/CanvasInstallation.swift:27-33` |
| LOG-10 | P1 | Ed sign-out invisible in Release; launcher writes into the shared login store | `EdSessionLauncher.swift:147-149` |
| LOG-11 | P2 | = #5 | `ICSFeedURLStore.swift:36-40`, `EdSessionTokenStore.swift:56-60` |
| LOG-12 | P2 | Fill script doesn't re-check its page; `submit` listener lacks `isTrusted` | `Kit/Canvas/PennKeyLoginForm.swift:56-63`, `PennKeyLoginCapture.swift:99` |
| LOG-13 | P2 | App-link guard fails open silently | `LoginNavigationObserver.swift:640-644,682` |
| LOG-14 | P2 | Custom addresses: `http://` error, cookies saved before verification | `OnboardingView.swift:310,1034` |
| LOG-15 | P2 | Pre-login purge has no timeout | `WebsiteDataReset.swift:36-47` |

### Crash sweep, Kit (KCR)

| ID | Sev | Finding | Where |
|---|---|---|---|
| KCR-01 | P0 | = #2 duplicate-key trap | `Kit/Grades/GradeEngine.swift:181-196` |
| KCR-02 | P1 | `allRows` turns a fetch error into an empty ledger | `Kit/Persistence/AssignmentStore.swift:477` |
| KCR-03 | P1 | `absorb` drops `userCompleted` and keeps the bookkeeping row | `Kit/Persistence/StoredAssignment.swift:429-463` |
| KCR-04 | P1 | Syllabus client lets URLSession manage cookies | `Kit/Syllabus/CanvasSyllabusClient.swift:183` |
| KCR-05 | P1 | One Ed 403 drops the Ed session | `Kit/Ed/EdClient.swift:185` |
| KCR-06 | P1 | One bad module item drops a page; course still "synced" | `Kit/Canvas/CanvasModulesClient.swift:267` |
| KCR-07 | P1 | Chunker rewrites punctuation ("92.5%" → "92. 5%", emails) | `Kit/Knowledge/PassageChunker.swift:70-88`, `Kit/Assistant/ClassQuestionAnswerer.swift:573` |
| KCR-08 | P1 | Knowledge file all-or-nothing, then overwritten | `Kit/Knowledge/CourseKnowledgeStore.swift:28-33` |
| KCR-09 | P1 | Ed wire decoding strict per page | `Kit/Ed/EdWire.swift:111,226-244` |
| KCR-10 | P2 | Non-Gregorian device calendar breaks terms and dates | `Kit/Models/Term.swift:47-49` |
| KCR-11 | P2 | ICS: bad byte gives `[]`; missing UID churns rows | `Kit/Canvas/ICSParser.swift:15,111` |
| KCR-12 | P2 | U+0000 can reach pooled documents | `Kit/Knowledge/HTMLText.swift:96` |
| KCR-13 | P2 | Unbounded regex and scan on pasted text | `Kit/Assistant/QuestionIntent.swift:199`, `Kit/Ed/EdDocumentText.swift:57` |
| KCR-14 | P2 | Non-ledger stores fail silently | `Kit/Persistence/GradeHistoryStore.swift:80-97` |
| KCR-15 | P2 | Cookie-bearing requests not host-pinned | `Kit/Gradescope/GradescopeClient.swift:194-225` |
| KCR-16 | P2 | `Int(rounded)` traps on huge or infinite doubles | `Kit/Grades/GradeExplanation.swift:269,280` |
| KCR-17 | P2 | Ledger reads rescan the table; some rows never age | `Kit/Persistence/AssignmentStore.swift:435-459` |

### Crash sweep, UI, app, widget (UCR)

No proven crash. The Swift 6 isolation is sound wherever it was checked.

| ID | Sev | Finding | Where |
|---|---|---|---|
| UCR-1 | P1 | = #1 | `ContentView.swift:530` |
| UCR-2 | P1 | = #10 | `OnboardingView.swift:886` |
| UCR-3 | P1 | = SES-005 (no epoch, nothing cancelled) | `AppState+CourseKnowledge.swift:313,432` |
| UCR-4 | P1 | Reminders rebuilt non-atomically; add failures swallowed | `BerserkAlarmDelivery.swift:136-149` |
| UCR-5 | P1 | = SYN-06 | `BackendSession.swift:72-95` |
| UCR-6 | P1 | Background wake builds a second `AppState` and container | `BackgroundRefresh.swift:160-178` |
| UCR-7 | P2 | = #5 | `SessionCookieStore.swift:283-293` |
| UCR-8 | P2 | Late renewer callback can still submit the password | `CanvasSessionRenewer.swift:1019-1024` |
| UCR-9 | P2 | Ed launch ignores the login-pane guard | `EdSessionLauncher.swift:104-149` |
| UCR-10 | P2 | = #6 | `AppState.swift:3929` |
| UCR-11 | P2 | Widget countdown reads `Date.now` twice | `LHFWidget/BerserkAlarmActivity.swift:104-106` |
| UCR-12 | P2 | Widget opens the store without the versioned schema | `Kit/Widget/LedgerWidgetReader.swift:62-72` |
| UCR-13 | P2 | `BerserkAlarmMetadata` brittle across versions | `Kit/Alarms/BerserkAlarmMetadata.swift` |
| UCR-14 | P2 | Swipe completes 0.38 s after the gesture | `AssignmentCardView.swift:399,423` |
| UCR-15 | P2 | `uniqueKeysWithValues` in the UI module | `GradeWatcherStore.swift:789,1646`, `AssistantContextAssembly.swift:189` |

### Ledger integrity (DAT)

| ID | Sev | Finding | Where |
|---|---|---|---|
| DAT-01 | P0 | = #6 | `Kit/Persistence/AssignmentStore.swift:317-320` |
| DAT-02 | P1 | = #12 | `Kit/Persistence/AssignmentStore.swift:529-534` |
| DAT-03 | P1 | Un-ticking undone by a hidden twin's completion | `AppState.swift:7136-7146,7730-7746` |
| DAT-04 | P1 | = UCR-6 | `BackgroundRefresh.swift:171` |
| DAT-05 | P1 | = #7, the ledger half | App Group container |
| DAT-06 | P1 | A wrong Canvas↔Gradescope pairing is permanent | `Kit/Models/AssignmentDeduplicator.swift:43,81,366-375` |
| DAT-07 | P1 | Other copy destroyed before the save is confirmed | `AppState.swift:5682-5685,1127-1133` |
| DAT-08 | P1 | Grade history silently falls back to memory | `Kit/Persistence/GradeHistoryStore.swift:94-96` |
| DAT-09 | P1 | First iCloud enable deletes the other device's preferences | `CloudPrefsMirror.swift:116-196` |
| DAT-10 | P2 | = KCR-02 | `Kit/Persistence/AssignmentStore.swift:476-478` |
| DAT-11 | P2 | JSON blob stores reset on one decode failure | `Kit/Persistence/CoursePreferences.swift:731-736`, `AppState.swift:8234-8251` |
| DAT-12 | P2 | Time-zone change orphans recurring completions | `RecurringTask.swift:172-173` |
| DAT-13 | P2 | = KCR-03, plus a tie can delete both copies under CloudKit | `Kit/Persistence/AssignmentStore.swift:447-452` |
| DAT-14 | P2 | Device sync is last-writer-wins on device clocks (Olisa's) | `Kit/Sync/SyncSnapshotMerge.swift:44-62` |
| DAT-15 | P2 | Memory fallback never retried; ticks lost at quit | `Kit/Persistence/AssignmentStore.swift:166-207` |
| DAT-16 | P2 | First schema change unrehearsed | `Kit/Persistence/LedgerSchema.swift:15-37` |
| DAT-17 | P2 | = KCR-11 | `Kit/Canvas/ICSParser.swift:15,111` |
| DAT-18 | P2 | = NOT-09 | `NotificationResponseRouter.swift:37-40` |
| DAT-19 | P2 | `SharedDefaults.resolve()` decides once per process | `Kit/Persistence/SharedDefaults.swift:80-86` |

### Sync, networking, background (SYN)

| ID | Sev | Finding | Where |
|---|---|---|---|
| SYN-01 | P0 | = #4 | `AutoSyncCoordinator.swift:30-33` |
| SYN-02 | P1 | The phone retires the server's crawled website documents | `Kit/Knowledge/CourseKnowledgeCollector.swift:299-305`, `functions/_shared/db.ts:300-321` |
| SYN-03 | P1 | Failed course reads counted complete, then retired for classmates | `Kit/Syllabus/CanvasSyllabusClient.swift:64-81` |
| SYN-04 | P1 | A Gradescope redesign looks like "no change"; prune in the same call | `Kit/Gradescope/GradescopeClient.swift:83-90`, `AppState.swift:4293-4315` |
| SYN-05 | P1 | Any 401/403 or keyword match disconnects Gradescope | `Kit/Gradescope/GradescopeClient.swift:27-36` |
| SYN-06 | P1 | `BackendSession` reentrant, so duplicate anonymous accounts | `BackendSession.swift:102-126` |
| SYN-07 | P1 | Uploads batched by count; a 413 wedges every hour | `Kit/Sync/SyncPlanner.swift:121-148` |
| SYN-08 | P1 | A slow stage delays the reminder re-plan; no deadlines | `ContentView.swift:669-732` |
| SYN-09 | P2 | No single-flight guard on `sync()` and friends | `AppState.swift:4125-4132` |
| SYN-10 | P2 | A failed collector run stamps `lastSyncedAt` | `Kit/Models/CourseDocument.swift:304` |
| SYN-11 | P2 | = UCR-6 | `BackgroundRefresh.swift:171` |
| SYN-12 | P2 | = KCR-05, plus an empty Ed reply replaces a class's set | `EdDiscussionCoordinator.swift:384-387` |
| SYN-13 | P2 | Update gate: a typed field rejects the policy; "v3.2.0" is inert; no fallback URL | `Kit/Update/UpdatePolicy.swift:67-79` |
| SYN-14 | P2 | = KCR-04 | `Kit/Syllabus/CanvasSyllabusClient.swift:183` |
| SYN-15 | P2 | Most sync failures never reach the student | `ContentView.swift:1013` |
| SYN-16 | P2 | = KCR-11 | `Kit/Canvas/ICSParser.swift` |
| SYN-17 | P2 | Gradescope status from a whole-page keyword scan | `Kit/Gradescope/GradescopeClient.swift:807-841` |

### Notifications, alarms, widget (NOT)

| ID | Sev | Finding | Where |
|---|---|---|---|
| NOT-01 | P0 | = #8 | `BackgroundRefresh.swift:186` |
| NOT-02 | P1 | = #9 | `NotificationScheduler.swift:343` |
| NOT-03 | P1 | Announcement finds get the Berserk alarm | `NotificationScheduler.swift:815-816` |
| NOT-04 | P1 | Reminder slots shared by class, not urgency; 30 idle in alarm mode | `NotificationScheduler.swift:710,752,1013-1047` |
| NOT-05 | P1 | Default alarm sound is 12.9 s and plays once | `SweeperSound.swift:17` |
| NOT-06 | P1 | Calendar triggers carry no time zone | `NotificationScheduler.swift:746-747` |
| NOT-07 | P1 | Scheduling failures silent; one throw aborts the alarm pass | `NotificationScheduler.swift:1081` |
| NOT-08 | P1 | The student is rarely told reminders won't arrive | `SettingsPage.swift:291` |
| NOT-09 | P2 | "Turned in" tap held only in memory | `NotificationResponseRouter.swift:24,32` |
| NOT-10 | P2 | = UCR-4 | `BerserkAlarmDelivery.swift:138-149` |
| NOT-11 | P2 | Reschedule cancellation; the authorization prompt has no timeout | `RescheduleSerializer.swift:41-49` |
| NOT-12 | P2 | Re-plan after a cold launch waits on the network | `ContentView.swift:685-697` |
| NOT-13 | P2 | Widget: missing snapshot reads "all clear"; `ForEach(id: \.self)` | `Kit/Widget/WidgetSnapshot.swift:186`, `LHFWidget/NextDueWidgetViews.swift:156` |
| NOT-14 | P2 | = UCR-11 | `LHFWidget/BerserkAlarmActivity.swift:105` |
| NOT-15 | P2 | No catch-up alert for work first seen under 10 minutes out | `NotificationScheduler.swift:824` |

### Backend (BE)

| ID | Sev | Finding | Where |
|---|---|---|---|
| BE-01 | P0 | = #13, plus `ask` takes unbounded context | `functions/ask-canary/index.ts`, `functions/ask/index.ts:57-80` |
| BE-02 | P0 | Quota checked before, charged after a clean finish | `functions/ask/index.ts:275-279,733-750` |
| BE-03 | P0 | = #14 | `migrations/20260907000000_init.sql:180,212` |
| BE-04 | P0 | Any account can claim a course and overwrite or retire its pool | `functions/sync/index.ts:212-214,325-365` |
| BE-05 | P0 | No write caps | `functions/sync/index.ts:68-74` |
| BE-06 | P1 | `discover-websites` fetches attacker URLs, no body cap | `functions/_shared/websites.ts:285-317` |
| BE-07 | P1 | Non-Penn exclusion enforced only by the app | `migrations/20260907000000_init.sql:22-23` |
| BE-08 | P1 | = SEC-08 | `AssistantContextDocument.swift:313-319` |
| BE-09 | P1 | Upload non-atomic; `profile_stale` can be lost | `functions/sync/index.ts:339-375` |
| BE-10 | P1 | One bad element fails a whole request with 500 | `functions/sync/index.ts:180-184` |
| BE-11 | P1 | Every function depends on an unbounded `device_links` lookup | `functions/_shared/auth.ts:84-97` |
| BE-12 | P1 | `extract-profile`: 20 model calls per quota unit, can exceed the time limit | `functions/extract-profile/index.ts` |
| BE-13 | P2 | Pairing: no confirmation, no AAD, links never expire | `chrome-extension/src/core/pairing.js` |
| BE-14 | P2 | `delete-account` not retry-safe; abandoned identities never purged | `functions/delete-account/index.ts:51-75` |
| BE-15 | P2 | Monthly quota query non-sargable; one shared pool | `migrations/20260907000000_init.sql:208` |
| BE-16 | P2 | Upstream error bodies logged and stored | `functions/_shared/openrouter.ts:468-475` |
| BE-17 | P2 | Floating `npm:` versions; docs drift | `functions/ask/index.ts:23` |
| BE-18 | P2 | Long `.in()` lists, buffered bodies, no stream idle timeout | `functions/_shared/db.ts:333-342` |

### Security, privacy, App Review, extension (SEC)

| ID | Sev | Finding | Where |
|---|---|---|---|
| SEC-01 | P0 | = #7, the policy half | `docs/PRIVACY.md:276-277` |
| SEC-02 | P1 | Pairing has no mutual verification; the QR carries the key | `PairLaptopSheet.swift`, `PairingLink.swift` |
| SEC-03 | P1 | Model-written links in ask open any scheme | `AssistantView.swift:439-447` |
| SEC-04 | P1 | Pooled document URLs trusted verbatim | `Kit/Models/BackendWire.swift:170` |
| SEC-05 | P1 | The public privacy page is stale | `docs/site/privacy.html` |
| SEC-06 | P1 | = PRF-05 | `OnboardingView.swift:371` |
| SEC-07 | P1 | Policy and label vs per-request `ask_outcomes` rows | `migrations/20260922090000_ask_outcomes.sql:27-45` |
| SEC-08 | P1 | Ask summary carries completion state (known) | `AssistantContextDocument.swift:316-321` |
| SEC-09 | P1 | Policy omits iCloud sync | `SettingsPage.swift:331-345` |
| SEC-10 | P1 | Extension doesn't drop anonymous Ed posts | `chrome-extension/src/core/ed.js:205-214` |
| SEC-11 | P1 | PennKey capture rests on a passive notice | `OnboardingView.swift:905` |
| SEC-12 | P2 | Fill script checks nothing about its own page | `LoginNavigationObserver.swift:~850`, `CanvasSessionRenewer.swift:874` |
| SEC-13 | P2 | No cross-host redirect handling | Kit clients |
| SEC-14 | P2 | Ed launch URL not pinned | `Kit/Ed/EdDiscussionProbe.swift:78-92` |
| SEC-15 | P2 | = #5 | `BackendIdentityStore.swift:43-52` |
| SEC-16 | P2 | Extension: `K` and session unencrypted at rest; unchecked senders | `chrome-extension/src/background.js:104-137` |
| SEC-17 | P2 | Release logs course codes and hosts as `.public` | `AppState.swift:6335-6344` |
| SEC-18 | P2 | A failed server deletion leaves the laptop link | `SettingsPage.swift:239-244` |

### Hangs, memory, screens that trap (PRF)

| ID | Sev | Finding | Where |
|---|---|---|---|
| PRF-01 | P0 | = #16 | `AppState.swift:7328-7340` |
| PRF-02 | P1 | Per-item regex predicates uncached | `AppState.swift:6472-6477,7092-7100` |
| PRF-03 | P1 | Every `@Published` write reloads the whole dashboard | `DashboardViewModel.swift:183-186` |
| PRF-04 | P0 | = #1 | `RootView.swift:105` |
| PRF-05 | P1 | Preview door on the reconnect screen; leaving preview wipes grade history | `AppState.swift:3739-3750` |
| PRF-06 | P1 | Many full-table fetches per rebuild | `Kit/Persistence/AssignmentStore.swift:435-478` |
| PRF-07 | P1 | `AppState.init` is a long synchronous chain before the first frame | `AppState.swift:913-1305` |
| PRF-08 | P1 | Knowledge file grows unbounded, rewritten whole on the main actor | `AppState+CourseKnowledge.swift:380,520` |
| PRF-09 | P1 | Unbounded WebKit continuation at the head of the launch pass | `ContentView.swift:266`, `AppState.swift:2888` |
| PRF-10 | P1 | Card lists are eager `VStack`s | `TimelineSectionView.swift:27-30`, `DoneView.swift:44-46` |
| PRF-11 | P1 | Heavy closures behind body-reachable modifiers | `ContentView.swift:172-179,337-348` |
| PRF-12 | P1 | Badge refresh and announcement dedup run repeatedly | `AppState+AnnouncementLog.swift:231-243` |
| PRF-13 | P2 | = SYN-09, plus a second loop on the Mac | `LHFScenes.swift:77-88` |
| PRF-14 | P2 | The update wall has no exit; its button vanishes without a URL | `UpdateRequiredView.swift:79` |
| PRF-15 | P2 | `SyncChangeLog` grows forever (Olisa's) | `Kit/Sync/SyncChangeLog.swift` |
| PRF-16 | P2 | Ed headers re-parsed several times per publish | `AppState+EdAnnouncementTasks.swift:122-137` |
| PRF-17 | P2 | `processedAnnouncementIDs` never pruned; PNG decoded in `body` | `AppState.swift:5353-5357`, `RedesignTokens.swift:393-405` |

### Checked and found sound (don't re-audit)

- **Background refresh.** The handler is `@Sendable` and `nonisolated`.
  `setTaskCompleted` is called exactly once behind a lock, and expiration
  tears the renewal down (`BackgroundRefresh.swift:74-143`).
- **Isolation.** All of these are isolation-correct:
  - the notification delegate (`NotificationResponseRouter.swift:70-153`);
  - voice dictation's tap (`VoiceDictationController.swift:227-265`);
  - the WebKit delegates and `SettleWaiter`;
  - the three `MainActor.assumeIsolated` sinks.
- **Credential capture and fill.**
  - `PennKeyLoginCapture`: an isolated content world, main frame only, host,
    origin and action checks, memory only for at most 10 minutes, saved only
    after a verified connect.
  - The fill script JSON-encodes the password, so escaping is correct.
- **Keychain classes.** Every item is `AfterFirstUnlockThisDeviceOnly`, and
  none is synchronizable.
- **Feed guard.** `reconcile` refuses an empty or HTML-200 feed once rows
  exist. Gradescope throws on a page failure rather than returning a partial
  list.
- **Update gate.** It fails open on every fetch failure, has a 10-second
  timeout and a 30-day ceiling, and limits `appStoreURL` to Apple hosts.
- **Backend, partly.**
  - Every function derives the user from the JWT.
  - RLS is on all 12 tables, and nothing builds SQL by concatenation.
  - The model has no tools.
  - The pairing code is 128-bit and consumed atomically.
  - No service-role or OpenRouter secret is in tracked files.
- **The Kit's trap patterns.** Every force-unwrap is on a constant or is
  guarded, every subscript and range is guarded, and every regex literal
  compiles once.
- **Extension permissions.** Only `storage` and `alarms`; CSP `script-src
  'self'`; AES-256-GCM with a fresh random nonce per seal.
