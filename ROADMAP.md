# Smooth roadmap

Written 2026-09-25, on `V7`. What's shipping, what's next, and what was tried
and set aside. `CLAUDE.md` is the engineering reference (how the code works
and the traps it has hit); this file is the plan. When an item lands, move it
to **Done recently** with its commit, rather than deleting it.

Live on the App Store: **1.2.1**. Uploaded but unreleased: **3.0.0 (build 9)**
from `v5`. The next release is 3.0.0 or later, built from `V7`.

---

## Now: before the next release

These block shipping, or would make shipping risky.

- **Try stay-signed-in against a real PennKey.** It has never run on a
  device. The code compiles and its pure parts are tested; nothing proves
  Penn's login form accepts the fill, or that Duo's 30-day remember holds.
- **Test with real Canvas and Gradescope data.** Every grade, submission and
  syllabus path has only been proven against fixtures (`CLAUDE.md` → Known
  gaps). This is the highest-value check outstanding.
- **Open a real pre-existing ledger after upgrading.** The `LedgerSchemaV1`
  migration has never opened an on-disk store from an older build. If it
  fails, the app silently falls back to an empty ledger.
- **Fix the `SessionCookieStoreTests` "calendar-link-only install" flake.**
  It used to fail about one run in ten and has failed most full runs since
  the session-persistence commits (`fac110d`..`99609c0`). It passes alone.
  Something in that work made a cross-suite race much more likely.
- **Pin down the full-run test hang.** A parallel `swift test` still
  sometimes freezes on the main thread inside `SecItemCopyMatching` (sampled
  2026-09-23 and 2026-09-25). `swift test --no-parallel` is the workaround.
  `fac110d` removed one trigger, the gated access-token read; there is at
  least one more.
- **Walk the onboarding per-course setup on a device** with a real Canvas
  session. It's covered by tests but has never been walked.
- **Release mechanics.** Keep preview mode (App Review's only way in; see
  Known gaps). Bump the `update-manifest` floor only once the build is
  actually downloadable.

## Next: features

Roughly in priority order.

- **Edit and delete recurring tasks.** Once saved, a recurring task can't be
  changed or removed from anywhere in the app. Found 2026-09-24, when a task
  saved with no class could only be repaired in code
  (`RecurringTask.adoptingCourse`).
- **Lock-screen widget: "N left this week"**, next to the existing ring.
- **Streaks and per-class counts on prev.** For example, "3 weeks in a row
  with everything done" and "PHYS: 3" under "4 down this week".
- **Weekly-task templates.** Pick "discussion post" or "problem set" and the
  sheet fills the title; the class comes from the class picker.
- **Grade "what if".** Drag an upcoming score in Grade Watcher and watch the
  final grade move. The category map and predictor already exist.
- **Siri / Shortcuts: "what's due tomorrow?"**, answered by the on-device
  responder so it works offline.
- **Ed Discussion as a source.** The groundwork is in `docs/ED_DISCUSSION.md`
  (the recon probe; its DEBUG row left Settings on 2026-09-24, but the
  `AppState` seam remains).
- **Canvas access tokens**, the day Penn issues an OAuth developer key or
  lifts the student-token restriction. The plumbing is built and gated off
  (`FeatureFlags.canvasAccessTokens`).

## Later: quality and tech debt

- **`AppState` is ~6,000 lines.** Split along the seams it already has
  (sync, dashboard buckets, sessions, recurring/manual work).
- **Source-grepping tests.** `VisualStructureTests` asserts on the text of
  `SettingsPage.swift`. `CLAUDE.md` already records why a test that greps
  the repo's own source proves little. Replace these with behavioural tests
  or delete them.
- **Refresh `docs/improvement-backlog.md`.** It dates from 2026-08-09, and
  much of it has been done or superseded since (Dynamic Type work, the empty
  state, error surfacing, disconnect clearing the WebView store). Prune it
  or fold what's left in here.
- **Bring `CLAUDE.md` up to date.** Its test baseline (1371/136) and branch
  table predate `V7`, and its architecture section still describes a
  stay-signed-in toggle that is gone.
- **iPad layout.** The app is iPhone-only (`TARGETED_DEVICE_FAMILY` 1). The
  Mac build exists; `v2.75` holds unmerged sidebar/landscape work.

## Tried and parked

Kept so nobody rebuilds them blind.

- **Dice "pick one for me".** A button that picked a random next assignment,
  one per class, due within two weeks. It worked, but it cost a button's
  worth of room on a full control row. Lives on the **`v8-dice-toggle`**
  branch (`PickAssignmentSheet`, `DashboardViewModel.pickCandidates`, with
  tests).
- **Per-assignment steps.** A "break into steps" checklist inside an opened
  card, with a thin progress bar on the collapsed card. Removed 2026-09-24.
  It's in commit `7b2578a` if revisited. If it comes back, steps must live
  in the ledger (`StoredAssignment`), not `UserDefaults`, because they are
  the student's own work.
- **"all assignments" as a row under todo.** Folded todo and all into one
  page. Once the todo · all · prev switch was one tap, the row was
  redundant.

## Done recently

- **2026-09-24/25 (`V7`).**
  - Settings: removed course-materials status, "report a problem",
    troubleshooting, the Grade Watcher row and "1 week before" reminders.
  - Disconnecting Canvas now also deletes server data (per
    `docs/PRIVACY.md`).
  - Stay signed in: no toggle; offered after each manual Canvas sign-in.
  - PennKey sheet: lock icon and a one-line disclaimer.
  - Done (prev): leads with "N down this week"; earlier work opens in place.
  - Unread-only announcement badge, with NEW tags on rows.
  - Full-width todo · all · prev switch and a class filter.
  - Class picker on the add sheets; classless recurring tasks are filed
    under the class their title names.
  - Wave-and-shine animation when you tap the Smooth wordmark.
