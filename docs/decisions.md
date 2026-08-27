# Decisions

Running log of decisions worth remembering. **Newest on top.** Each entry:
date, the decision, and what was rejected and why.

---

## 2026-08-27 — No-submission assignments: visible caveat + per-class reminder toggle
Canvas's grades API already tells the app which assignments require no online
submission (`GradeItem.requiresNoSubmission` — every `submission_types` entry
is `none`, `on_paper`, or `not_graded`), and the app already used that to
auto-file past-due no-submission items as done and to suppress "Turned in ✓"
notices for them. Two things were missing: nothing on the dashboard *told*
the student a given assignment was one of these (the auto-completion just
happened silently), and there was no way to keep a class's reminders while
turning off the ones for its attend-only/on-paper work specifically.

Added both. The dashboard card now shows a small "nothing to submit" tag —
visible on the collapsed card, not only once expanded, because the whole
point is to answer "do I need to turn something in?" at a glance — plus one
plain-language sentence once the card is opened. Profile → notifications
gets a new per-class toggle, `CoursePreferences.noSubmissionRemindersEnabled`,
that gates lead-time reminders and the daily digest count for that class's
no-submission items without touching the caveat (which is purely
informational and always shows) or any other class's setting.

**Default ON.** Both features are additive and behavior-preserving: the
toggle defaults to `true`, so a no-submission item schedules exactly as it
did before this change until a student explicitly opts out. The caveat is
informational only and cannot silence anything by itself — it is the toggle,
not the tag, that a student who wants quiet has to find and flip. This
matches the toggle's siblings (`recurringEnabled`, `notificationsEnabled`
lead-offset overrides): everything in this per-course settings file starts
at "do what the app already did."

**Where the id cache lives, and why not the ledger.** Whether an assignment
requires no submission is derived from Grade Watcher's grade snapshots, which
are in-memory only and refreshed live — there was previously no reason to
persist anything about them. The caveat needs to render correctly on the
very first frame of a cold launch though, before any refresh has run, so the
set of currently-known no-submission Canvas assignment ids is cached under
`"noSubmissionCanvasAssignmentIDsV1"` in `UserDefaults.lhf` (never
`.standard`), self-healing on every refresh (an id enters when observed
no-submission, leaves when observed submittable, and is left untouched for
any course the refresh didn't cover — the same "merge, don't replace" rule
`submittedCanvasAssignmentIDs` already uses). This is a re-derivable cache of
what the last refresh saw, not a fact about the student's own work, so it
belongs in tier 2 (App Group `UserDefaults`) rather than the SwiftData
ledger — putting it there would have meant a schema change on a migration
path (`LedgerSchemaV1`) that, per the Known Gaps section, has never opened a
real pre-existing on-disk store, for a value that costs nothing to
re-observe on the next sync. It is also deliberately NOT mirrored to iCloud
(`CloudPrefsMirror.mirroredKeys` does not list it): two devices disagreeing
about it for a while while their own Grade Watcher refreshes catch up is
harmless, and mirroring it would tie the cache's correctness to sync timing
for no benefit.

**Scope.** The toggle governs true Canvas assignments only — items with a
real `canvasAssignmentID` (quizzes, discussions, events, and readings-course
imports all yield `nil` there by design and are unaffected). Readings and
check-ins already have their own switch (`recurringEnabled`, "readings and
check-ins" in Profile); this is deliberately a third, independent control
rather than a rename of either existing one, because a no-submission
assignment is neither a recurring occurrence nor a mute of the whole class.

## 2026-08-27 — Remove the readings consent nudge; auto-import unless excluded
Removed the one-ask "include this class's readings?" popup (`CourseNudgeSheet`,
`AppState.pendingCourseNudge`/`resolveCourseNudge`/`dismissCourseNudge`/
`queueNudgeIfNeeded`) that used to gate a silent course's Modules-imported
readings. A course's readings now import automatically the moment
`refreshCourseIntel`'s probe finds them; the only thing that still blocks an
import is an explicit `.exclude`, set via Settings' "Courses & content"
toggle (`AppState.setCourseContentIncluded`), via the new
`AppState.shouldAutoImportReadings(for:)` gate. The toggle itself is
unchanged and remains the opt-out.

Rejected: keeping the one-ask consent gate. It already had a narrow scope —
the 2026-08-26 change below in this log made calendar `.event` items
include-by-default and left the popup asking only about silent courses whose
Modules pages had readings, since fetching those requires a network call.
Owner's call: the data is the student's own record of their own classes —
the "ask" bought no real consent (a student who added LHF at all has already
decided they want their Canvas work surfaced), and a real device pass showed
the popup reads as one more thing standing between installing the app and
seeing your classes. Same reasoning that flipped calendar events to
include-by-default now extends to Modules readings too.

## 2026-06-03 — Local due-date notifications
Added `NotificationScheduler` (app layer, `UNUserNotificationCenter`, cross-platform,
no entitlement) for local reminders. Defaults: 24h + 1h before each assignment, plus an
optional daily digest; all configurable in Settings. Reschedules idempotently (full
cancel + re-add, stable ids `due:<assignment.id>:<offset>`) whenever data changes — read
from the override-aware `vm.items`, not `AppState`, so manual due-date edits are honored.
Caps at 60 pending (iOS limit 64); permission requested on enable, not at launch.

## 2026-06-03 — Onboarding name + dashboard greeting, manual due-date adjust, Sync button
Onboarding now captures the user's first name; the dashboard opens with
"Hello, &lt;name&gt;". Each assignment card got a calendar button to manually
adjust its due date, which then shows "manually adjusted" under the date.
Added a header Sync button for on-demand refresh (auto-sync still runs on launch).

## 2026-06-03 — Persist login session across launches
`WKWebView` drops session cookies (Gradescope `_gradescope_session`, Penn SSO)
when the app quits, silently logging the user out every launch. We now persist
the captured cookies (`SessionCookieStore`) and replay + re-inject them on
launch via `AutoSyncCoordinator`, so the session and data survive relaunches.
Rejected relying on `WKWebsiteDataStore` alone — it doesn't keep session cookies.

## 2026-06-03 — Gradescope parser handles unsubmitted assignments
Unsubmitted assignments render as "submit" buttons (`data-assignment-id` /
`data-assignment-title`, no `href`), so the old parser — which required a
submission link per row — dropped every unsubmitted assignment, making whole
courses (e.g. CIS 2400) disappear. The parser now also reads submit-button rows,
targets the real due-date `<time>` element, and parses the `yyyy-MM-dd HH:mm:ss Z`
datetime format.

## 2026-06-03 — v2 UI redesign (greige + spine cards + progress ring)
Replaced the dashboard presentation layer: warm-greige background, white cards
with an urgency-colored left spine, a weekly progress ring, a This week / All /
Done segmented toggle, and an archived Done view. A `DashboardViewModel` derives
all sections/ring math from the existing `AppState` without changing the model
or scrapers. Superseded the earlier eggshell/full-bleed concept in design.md.

## 2026-05-26 — Branched `marco/ios-ui-rework`
Branched `marco/ios-ui-rework` off `main` to adapt the Mac-first UI for
iPhone. The Mac layout assumes a wide window and hover affordances; iPhone
needs touch-sized targets, a single-column list, and a sheet-based edit
flow rather than an inspector.

## 2026-05-22 — Four-state color system based on due date urgency
Adopted a four-state palette — Ruby Red (past due), Amber Earth (urgent),
Cornflower Ocean (upcoming), Seagrass (future) — driven entirely by the
due date. Replaced the earlier three-state system (overdue / due soon /
later), which collapsed "today" and "this week" into one bucket and made
the most actionable items hard to spot.

## 2026-05-22 — Converge on Swift / SwiftUI
Decided to build Penn Dashboard as a single Swift / SwiftUI codebase
targeting iOS and macOS, distributed via Swift Package Manager.

Rejected: React Native + a shared backend. SwiftUI runs on both iOS and
macOS natively without a JS bridge, and Olisa's Canvas + Gradescope
scrapers were already written in Swift. Going RN would have meant either
rewriting the scrapers in TypeScript or standing up a backend service to
host them — extra moving parts for no user-visible benefit.
