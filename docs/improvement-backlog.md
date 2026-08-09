# LHF Improvement Backlog

_Audit date: 2026-08-09 · branch `v3-assignment-durability`_

Scope note: the assignment-persistence overhaul (durable ledger, reconciliation,
Canvas/Gradescope dedup of moved dates, submission-state durability, feed-simulation
harness) is covered separately in `docs/assignment-persistence-plan.md` and is
**deliberately excluded** here. Everything below is the *other* work — reliability,
UX, performance, App Store, security, architecture, and tests — that the persistence
plan does not touch.

Impact = user/business harm if unfixed. Effort = S (hours) / M (a day or two) / L (multi-day).

---

## Top 10 by impact

| # | Item | Category | Impact | Effort | File(s) |
|---|------|----------|--------|--------|---------|
| 1 | "Go enjoy Life / all caught up" shows before first sync completes and when a sync fails — looks like data loss | UX / Reliability | High | M | `ContentView.swift:273,293` |
| 2 | Dashboard never surfaces `state.error`; a failed Canvas fetch is completely silent on the main screen | Reliability / UX | High | S | `ContentView.swift` (no renderer), `AppState.swift:315` |
| 3 | Disconnect Canvas/Gradescope leaves the live session in `WKWebsiteDataStore.default()` — user isn't actually signed out | Security / Privacy | High | S | `AppState.swift:275,288`; `SessionCookieStore.swift` |
| 4 | Date-only ICS events normalized to end-of-day **UTC**, not local — wrong due time + wrong reminders for all-day items | Correctness | High | S | `ICSParser.swift:124-133` |
| 5 | No Dynamic Type support: every font uses a fixed point size, so accessibility text sizes don't scale | Accessibility / App Store | High | M | `RedesignTokens.swift:106-126`, all views |
| 6 | Gradescope scrape issues a **serial** extra HTTP GET per unsubmitted assignment — slow, and a rate-limit risk on the user's account | Performance | Med | M | `GradescopeClient.swift:71-94` |
| 7 | `DashboardViewModel` rebuilds the whole item list on *every* AppState republish (incl. `isLoading` toggles) | Performance | Med | S | `DashboardViewModel.swift:69-72` |
| 8 | Preview/demo mode is sticky across launches with no on-screen way out | UX | Med | S | `AppState.swift:128,141`; `OnboardingView.swift:103` |
| 9 | `.timeSensitive` interruption level set but the entitlement isn't in the app — "break through Focus" silently does nothing | Reliability | Med | S | `NotificationScheduler.swift:179`; `App/LHFApp.entitlements` |
| 10 | Dark-mode: `.blendMode(.multiply)` on the empty-state art muddies/erases it on dark backgrounds | UI polish | Med | S | `ContentView.swift:299` |

---

## Reliability & correctness

- **[High] Date-only events use end-of-day UTC.** `ICSParser.parseDate` adds `86_399`
  seconds to midnight **UTC** for `VALUE=DATE` items (`ICSParser.swift:126-133`).
  For an Eastern-time student that resolves to ~18:59/19:59 local, not end of day.
  A homework Canvas lists as "due Friday" (all-day) then shows a Friday-evening time,
  the "1 day before" reminder fires at the wrong hour, and `dueText`/urgency banding
  compute off the wrong instant. Normalize to end-of-day in the user's local zone
  (or the feed's `TZID`). _Why it matters: silently wrong deadlines are the worst
  possible bug for a deadline app._

- **[High] Sync errors are invisible on the dashboard.** `AppState.sync()` sets
  `error = "Sync failed: …"` (`AppState.swift:315`) but `ContentView` has no view that
  reads `state.error` — only `SettingsPage.swift:131` renders it. A user on a flaky
  connection sees stale data (or the empty state) with zero indication the refresh
  failed. Add an inline banner/toast on the dashboard. _Note: distinct from the
  persistence plan's zero-item partial-fetch guard — that's about not *marking things
  gone*; this is about *telling the user a refresh failed at all*._

- **[Med] `splitCourse` requires the summary to end in `]`.** `CanvasICSClient.splitCourse`
  (`CanvasICSClient.swift:99-109`) uses `lastIndex(of: "[")` + `hasSuffix("]")`. Any
  trailing whitespace after the bracket, or a title that legitimately contains
  brackets, drops the item to `(unknown course)`, which then can't be selected,
  graded, or deduped. Trim before the suffix check and match a `[...]` at end more
  robustly. _Why it matters: a mis-split hides a real class from the whole app._

- **[Med] Gradescope login/expiry detection is string-heuristic.** `isLoginPage`
  (`GradescopeClient.swift:327-332`) keys on the literal words "log in"/"gradescope"/
  "email". A Gradescope copy change flips this either way — a false positive throws
  `notLoggedIn` on a valid session (spurious reconnect prompt); a false negative
  scrapes a login page as course data. Prefer an HTTP-status/redirect signal.
  _Why it matters: brittle against a third party you don't control._

- **[Low] Notifications only reschedule while the app is foreground.** `reschedule`
  runs from `ContentView.refresh()` / the 5-min loop / scene-activation
  (`ContentView.swift:242-247`, `126-160`). If the app isn't opened for longer than
  the 14-day `horizonDays` window, no new reminders get scheduled. A `BGAppRefreshTask`
  would close this. _Why it matters: heavy-user reminders can lapse over a long break._

## UX / UI polish

- **[High] Premature "all caught up" empty state.** `ContentView.allDoneState`
  ("Go enjoy Life / you're all caught up", `:293`) renders whenever `sections` is
  empty — which is *also* true on cold launch before the first sync lands, and after
  a failed sync. `isLoading` is never shown anywhere in `ContentView`. A real student
  with pending work can open the app and be told they're done. Show a loading state
  on first sync and an error/empty distinction. _Why it matters: reads as data loss →
  1-star reviews._

- **[Med] Preview mode is a roach motel.** `isPreviewMode` is persisted
  (`AppState.swift:128,141`) so a reviewer stays in the demo across relaunches — good
  for review, bad for a curious real student who taps "Preview with sample data"
  (`OnboardingView.swift:103`) and is then stuck in fixtures with no dashboard-level
  "exit demo" affordance (only Connect-Canvas via `restartOnboarding` clears it).
  Add a visible "Exit preview" control. _Why it matters: a confused first-run user
  can't get to their real data._

- **[Med] Dark-mode blend artifact.** The empty-state art uses
  `.blendMode(.multiply)` at 35% opacity (`ContentView.swift:299`). Multiply against
  the dark `v2Bg` (`0x1C1A17`) crushes the image to near-invisible mud. Gate the blend
  to light mode or use a proper dark asset. _Why it matters: the reskin's marquee
  screen looks broken in dark mode, which is unverified on device (HANDOFF)._

- **[Low] Reconnect vs. session-expiry copy is spread thin.** Grade Watcher surfaces a
  precise "no saved Canvas session" message (`GradeWatcherStore.swift:122`) but the
  dashboard's own submission auto-filing depends on that same session and says nothing
  when it's absent — an item silently sits active until a grade refresh that will never
  come. A one-line "Reconnect Canvas to track submissions" nudge on the dashboard would
  close the loop.

### Accessibility

- **[High] No Dynamic Type.** All fonts are fixed-size: `.custom(name, size:)` and
  `.system(size:)` in `RedesignTokens.swift:106-126`, used as `.lhfSerif(46)`,
  `.lhfSans(11)`, etc. None use `relativeTo:` / `@ScaledMetric` / `dynamicTypeSize`
  (confirmed: zero occurrences in the UI). Users on larger accessibility text sizes get
  no scaling anywhere. Adopt `Font.custom(_, size:, relativeTo:)` and scaled metrics.
  _Why it matters: Apple flags missing Dynamic Type in review, and it's a real barrier._

- **[Med] Sparse VoiceOver labels.** `AssignmentCardView.swift` has only 2 accessibility
  calls for a tap-to-complete + swipe-to-edit card; completion state and urgency tier
  aren't announced. The `SegmentedToggle`, section headers, and the grade "% decided"
  bars lack labels/values. Audit for `accessibilityLabel`/`accessibilityValue`/
  `accessibilityAddTraits(.isButton)`.

- **[Low] Contrast of muted tokens.** Several `v2Section*`/`v2Done*` greys
  (`RedesignTokens.swift:59-66`) are low-contrast on their surfaces; run them through a
  WCAG check for the dark palette especially.

## Performance

- **[Med] Serial per-assignment Gradescope refetch.** `refineCompletionStatus`
  (`GradescopeClient.swift:71-94`) loops assignments and `await`s a full HTML GET for
  each unsubmitted one with a URL — on top of the account page + one GET per course.
  A 5-course load can be dozens of sequential round-trips, which is slow and risks
  rate-limiting the student's own Gradescope account (the 15-min throttle only spaces
  whole syncs, not requests within one). Bound concurrency / cap the refinement /
  rely on the row's own status. _Why it matters: the heaviest network path in the app,
  fully serial._

- **[Med] Over-eager dashboard rebuilds.** `DashboardViewModel.bind` subscribes to
  `state.objectWillChange` and calls `reload(preservingEdits:)` on every published
  mutation (`DashboardViewModel.swift:69-72`). A single `sync()` toggles `isLoading`
  twice and sets `lastSync`/`error`, so the full item list + section derivation rebuilds
  several times per sync, and `ContentView`'s `.animation(value: vm.items)` (`:68`)
  animates on spurious republishes. Debounce or observe only the item arrays.

- **[Low] DateFormatter churn.** New `DateFormatter()` per call in
  `DashboardViewModel.string` (`:276`), `ContentView.dateText` (`:319`),
  `NotificationScheduler.format` (`:211`), and `ICSParser.parseDate`. Some sit in
  list-render paths. Cache static formatters. `GradescopeHTMLParser` also compiles every
  regex fresh via `try? NSRegularExpression` inside `matches` — fine for the scrape,
  worth memoizing if it ever moves on-path.

- **[Low] Widget cadence.** 30-min timeline + `reloadAllTimelines()` on every dashboard
  rebuild (`NextDueWidget.swift:40`, `AppState.swift:713`). Countdowns render live via
  `Text(_:style:)`, so this is fine — but the reload-on-every-rebuild can burn WidgetKit
  budget during an active session; coalesce.

## App Store readiness & compliance

- **[High, business] Gradescope Guideline 5.2.2 is the top submission risk.** Documented
  in `docs/appstore/REVIEW_NOTES.md` and `CHECKLIST.md` (the prepared justification vs.
  gating Gradescope out). Not a code bug, but the single most likely rejection cause —
  decide before submitting.

- **[Med] Review notes overclaim "erase the stored session."** `REVIEW_NOTES.md:76`
  states Disconnect "erase[s] the stored session for that service," but the code only
  clears the Keychain copy, not the WebView store (see Security item #3). Either fix the
  code or soften the claim before a reviewer tests it.

- **[Low] Privacy manifest looks compliant.** `App/PrivacyInfo.xcprivacy` declares no
  tracking/collection, UserDefaults reason `CA92.1`, and FileTimestamp `C617.1` for the
  App Group write. Keychain (`SecItem`) isn't a required-reason API, so nothing missing
  there. Just keep the widget manifest (`LHFWidget/PrivacyInfo.xcprivacy`) in lockstep.

- **[Low] Still-manual review assets.** Dark-mode + widget screenshots and the demo
  re-record are open in `CHECKLIST.md`; the capture script can't produce them.

- **[Low] Stale user-agent string.** `"Mozilla/5.0 LowHangingFruit/0.1"`
  (`GradescopeClient.swift:100`) advertises version 0.1 while shipping 1.0.0. Cosmetic,
  but it's sent to a third party.

## Security & privacy

- **[High] Disconnect doesn't clear the WebView data store.** `disconnectCanvas` /
  `disconnectGradescope` (`AppState.swift:275-293`) call `SessionCookieStore.remove(...)`
  only. Nothing ever calls `WKWebsiteDataStore.default().removeData(...)`, and login runs
  in the **default** (on-disk) data store (`OnboardingView.swift:371,429`). So after
  "Disconnect," the Penn SSO / Gradescope session still lives in the WebView store:
  `AutoSyncCoordinator.canvasCookies()` reads `getAllCookies()` from it and would merge
  those live cookies right back (`AutoSyncCoordinator.swift:77-85`), and reconnect is a
  silent auto-login. On a shared device this is a real sign-out failure. Fix: clear the
  relevant records from `WKWebsiteDataStore.default()` on disconnect (or use a
  non-persistent/dedicated store for login). _Why it matters: data-trust, and it
  contradicts the App Review claim above._

- **[Med] Broad cookie capture and domain matching.** Save filters
  `canvas.upenn.edu`/`gradescope` (`OnboardingView.swift:376,430`); disconnect removes by
  substring `"canvas"`/`"upenn"`/`"gradescope"` (`AppState.swift:276-289`). Fine today,
  but the substring approach is fragile if a future domain overlaps. `SessionCookieStore`
  stores name/value/domain/path/secure only — good minimization — and uses
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`SessionCookieStore.swift:78`),
  which is correct. No cookie values are logged anywhere (verified: no `print`/`NSLog`/
  `os_log` of session data). _Net: storage posture is good; the disconnect gap above is
  the real issue._

## Feature opportunities (secondary — fix what exists first)

- **Assignment search/filter.** The dashboard is a single scroll with no search; with a
  full term of items across "All," find-by-name would help. No search UI exists today.
- **Grade-change notifications.** `GradeWatcherStore.history` already records one
  observation per course per day (`:492`) and `weekDelta` computes the change (`:479`) —
  a "your CIS 2400 grade moved" local notification is mostly wiring.
- **Calendar export / add-to-Apple-Calendar.** The app already parses ICS; round-tripping
  selected items into EventKit or an exported `.ics` is a natural fit.
- **iPad support.** `TARGETED_DEVICE_FAMILY` is `"1"` (iPhone only) on both targets
  (`project.yml:58,93`) despite the codebase being universal SwiftUI (+ macOS). Adding
  iPad is cheap reach, pending a layout pass.
- **Transparency / data export.** With everything on-device and a privacy story to tell,
  a "what LHF has stored" + wipe screen would reinforce the no-backend pitch.

## Code architecture & tech debt

- **[Med] `AppState` is a ~900-line god object** (`AppState.swift`). It owns UserDefaults
  persistence, network orchestration (instantiates `CanvasICSClient`/`GradescopeClient`/
  `CanvasDiscoveryClient`/`CanvasGradesClient` inline as concrete types), dedup,
  dashboard bucketing, widget publishing, course selection, name overrides, and the
  cookie-derived submission set. The persistence plan extracts a store, but the network
  orchestration and bucketing remain untestable without protocol seams (no injectable
  client interfaces). Introduce client protocols so `sync`/`syncGradescope`/
  `refreshGradeWatcher` can be unit-tested with fakes.

- **[Med] Duplicated urgency banding, by hand.** `WidgetUrgency` (`WidgetSnapshot.swift:77`)
  duplicates `DueState`'s thresholds and colors (`RedesignTokens.swift:149`) because the
  widget target can't import the UI module — the file even says "keep in sync BY HAND."
  Move the shared banding into `LowHangingFruitKit` (which both import) so it can't drift.

- **[Low] Dead code.** `ProgressRingView` is no longer used by the dashboard (HANDOFF
  follow-up) — delete or rehome. `byDueDate` is duplicated in `AppState.swift:892` and
  `GradescopeClient.swift:120`.

## Test coverage gaps (beyond the planned feed-simulation harness)

- **Timezone / DST in scheduling and dates.** No test pins `ICSParser` date-only handling
  (item #4) or `NotificationScheduler` fire times across a DST boundary. `NotificationSchedulerTests`
  covers filtering, past-offset skipping, emoji/interruption level, and the 60-cap — but
  not zone correctness.
- **`SessionCookieStore` round-trip and the disconnect flows.** No test that
  save→load→remove behaves, and nothing guards the "disconnect actually signs out"
  invariant (item #3) — exactly the kind of regression that reaches users silently.
- **`AutoSyncCoordinator` cookie-merge.** The live-wins-over-persisted merge
  (`:65-66,83-84`) is untested.
- **`DashboardViewModel` reload/preserve-edits.** The republish→reload behavior and
  edit-preservation on id match (`:86-129`) have no unit test; `DoneDuplicationTests`
  covers only the Done-dedup case.
- **Error-surfacing.** No test asserts a failed sync produces a user-visible signal
  (because currently it doesn't — item #2).
