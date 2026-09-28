# Smooth roadmap

The plan: what blocks the next release, what's next, and what was tried and
set aside. `CLAUDE.md` is the engineering reference (what the app does, how
the code works, the traps it has hit). **Every session reads both at the
start and updates both before it ends** (`CLAUDE.md` → "Start here" has the
table of what goes where). When an item lands, move it to **Done recently**
with its date and commit, rather than deleting it.

Last updated 2026-09-25, on `V7`.

Live on the App Store: **1.2.1**. Uploaded but never released: **3.0.0
(builds 7–9)** from `v5`. The next release is 3.0.0 or later, built from
`V7`.

---

## Now: before the next release

These block shipping, or would make shipping risky.

- **Watch a background re-login on a real phone.** Stay-signed-in renewed
  silently in the foreground on two phones (2026-09-27). Whether a renewal
  during a background wake finishes before iOS pauses the hidden WebView is
  unobserved. Read `debugRenewalLogV1` off a DEBUG build after a day or two
  away (`CLAUDE.md` → Commands). If background attempts end in `needs-duo`,
  the parked fix is a foreground-only guard (Tried and parked).
- **Test with real Canvas and Gradescope data.** Every grade, submission and
  syllabus path has only been proven against fixtures. This is the
  highest-value check outstanding.
- **Sign in at a non-Penn school on a device.** Brown, Columbia, Cornell,
  Dartmouth, Harvard, Princeton, Yale and custom addresses exist since
  2026-09-23 and have only been exercised by tests.
- **Warn when the ledger isn't saving.** If the App Group container is
  missing, assignments live in memory and vanish on relaunch, and since the
  Settings "storage" section went nothing on screen says so (`CLAUDE.md` →
  Known gaps).
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

- **Edit and delete recurring tasks.** Once saved, a recurring task can't be
  changed or removed from anywhere in the app. Found 2026-09-24, when a task
  saved with no class could only be repaired in code
  (`RecurringTask.adoptingCourse`).
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
- **Ed Discussion as a source.** The groundwork is in `docs/ED_DISCUSSION.md`
  (the recon probe; its DEBUG button left Settings on 2026-09-24, but the
  `AppState` seam remains).
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
- **Foreground-only silent re-login.** Let `CanvasSessionRenewer` run only
  while the app is on screen, deferring a background wake's attempt to the
  next open. Considered 2026-09-27 as a guard against the hidden WebView
  stalling on Duo in the background; declined in favour of Olisa's exact,
  phone-proven logic. First thing to try if `debugRenewalLogV1` ever shows
  background attempts ending in `needs-duo`.
- **Keeping Canvas cookies until the server rejects them.** `fac110d`
  (2026-09-24) dropped the 24-hour rule; it signed Marco out two days
  later and was reverted (`CLAUDE.md` → the 24-hour trap).

## Done recently

- **2026-09-27.** Stay signed in works like Olisa's phone again: the
  24-hour cookie rule and Penn's cookie handling restored byte for byte
  from `39b2fff`, so the app re-logs in on open after a day away (PennKey
  auto-fill, Duo's remembered device, back to Canvas). Proven on Marco's
  phone with a real PennKey (renewed in 8 s, hands-free). DEBUG builds
  gain `-LHFAgeCanvasSession` and the `debugRenewalLogV1` attempt log.
  3.0.0 build 10.

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
