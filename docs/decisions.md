# Decisions

Running log of decisions worth remembering. **Newest on top.** Each entry:
date, the decision, and what was rejected and why.

---

## 2026-08-29 — Gradescope items carry a term, and an undated leftover can't outlive its archive
A user on the shipped build reported an assignment from a class that had
already ended ("CIS 3200 · Homework 4 · 27 days late"). Two gaps, both specific
to Gradescope-sourced work.

**Gradescope threw its term away.** The account page groups courses under term
headings ("Fall 2025"), and `currentTermCourses` parsed them — to choose which
courses to fetch, and then dropped the label. So every Gradescope assignment
arrived with `term == nil`, where a Canvas item gets its term for free from the
`YYYYTT` suffix `CourseCode.parse` reads. Term is the field the whole semester
archive turns on, so Gradescope work was structurally unarchivable by term.
`CourseLink` now carries the heading's term and `GradescopeHTMLParser.assignments`
stamps it onto each row. `GradescopeTerm.pennTerm` maps the label onto the app's
`Term`; a quarter school's "Winter" files under Penn's spring, whose window it
sits inside. Courses from an ungrouped account page still carry no term — there
is no evidence to read, and inventing one is worse than admitting it.

**An item with no term AND no due date walked past the archive.**
`withinTermCap`'s doc promised "undated and overdue items pass unless their term
has been archived", but the undated branch returned `true` before any archive
check — with no term and no due date there was nothing to match a term against.
Canvas items are rarely in that state; a Gradescope assignment posted without a
deadline always was. `archivedAssignmentIDs` covers rows that were on the ledger
when the student confirmed, so what leaked was anything re-ingested afterwards or
never persisted. The branch now consults the per-course archive stamp, which the
rollover writes for every class it files and deliberately skips for a class still
running this term (the retaken-CIS-1200 case).

Rejected an automatic past-term cutoff, again: `Term(date:)` maps August to fall,
so a summer course's live August work would vanish on the 1st. The past bound
stays the student's confirmed archive — this only extends that same confirmation
to items whose own fields couldn't express it. Rejected inferring a Gradescope
term from the due date instead of the heading: the heading is evidence, the due
date is a guess, and the guess is what the ledger's `firstSeen` fallback already
does one tier down.

## 2026-08-27 — One "items with nothing to submit" toggle, and it hides, not just silences
Two per-class notification switches shipped this same week — `recurringEnabled`
("readings and check-ins") and `noSubmissionRemindersEnabled` ("assignments
with nothing to submit") — and both turned out wrong once a real device pass
used them. The owner flipped the no-submission toggle off expecting those
items to disappear from the dashboard; it only silenced their reminders,
leaving the card sitting there looking like the toggle had done nothing. The
readings toggle never touched `.event`-kind items at all — Canvas calendar
readings and lectures like "CIS 2400 Lecture" — because the scheduler's old
recurring-gate only ever matched `RecurringTask` occurrences
(`kind: .assignment`), which a `.event` row never is. Two switches, both half
of one idea a student actually has ("stuff with nothing to turn in"), each
solving a different half wrong.

**Merged into one field**, `CoursePreferences.nothingToSubmitEnabled`
(default on), one Profile → notifications toggle ("items with nothing to
submit"), one behavior:

- **Off HIDES, it doesn't just silence.** `.event` items (readings, lectures,
  calendar events) and Canvas assignments cached as requiring no submission
  are dropped from `AppState.assignments`/`laterAssignments` outright —
  `rebuildDashboardItems` is the one place this is enforced — rather than
  merely skipped by the notification scheduler. Why hide rather than mute
  louder: a toggle a student flips expecting an effect and sees none reads as
  broken, and "broken" is a worse failure than "aggressive." The `assessments`
  bucket is untouched by construction — it's split off from `incomplete`
  *before* this filter runs, so an exam date is never hidden by a
  notifications toggle no matter its submission type.
- **`RecurringTask` occurrences are the one exception, and stay visible.** A
  weekly reading or check-in the student built themselves through Settings →
  Tasks is not something a notifications toggle should make disappear —
  that reads as data loss, not as "reminders got quieter." Off silences an
  occurrence's reminders and its digest count (the one job left for
  `NotificationScheduler`'s own gate on this field) but never removes it from
  the list. Deleting the recurring task itself is how a student removes it.
- **The decode fold.** Both retired fields shipped to the owner's own device
  only, this week — not a real migration, so no version gate, no
  `LegacyStateMigration` entry, just a fold inside `CoursePreferences
  .init(from:)`: prefer the new key when present, otherwise AND the two old
  ones (each defaulting `true` if absent). A `false` in *either* old switch
  carries forward as the merged toggle being off, which is the only reading
  consistent with what both switches meant. The old CodingKeys stay listed,
  decode-only, so that fold keeps working; nothing writes them again after
  the first save.

**Known gap, not silently accepted.** The iOS home/lock-screen WidgetKit
extension (`LedgerWidgetReader`, a separate process) does not read
`CoursePreferences` at all — it only consults the three legacy
hidden/deleted/rename keys `CoursePreferencesStore` still projects for it.
A class with the toggle off will still show its readings and no-submission
assignments in the iOS widget. This is a real gap, flagged as a follow-up:
teaching the widget process about `nothingToSubmitEnabled` needs its own
pass (either projecting a fourth legacy-style key, or letting
`LedgerWidgetReader` read the `coursePreferences` blob directly), not
something to fold into this change silently. The **Mac menu-bar panel**
(`MenuBarPanel` in `LHFScenes.swift`) does NOT have this gap — verified by
reading its `upcoming` computed property, which reads `state.assignments`/
`state.laterAssignments` directly (not through `DashboardViewModel`), so it
inherits the hiding automatically the moment `AppState.rebuildDashboardItems`
applies it.

## 2026-08-27 — Nothing-to-submit items never show as late
The owner's device pass found a no-submission item sitting in OVERDUE
("Class 2: Litigation... nothing to submit — 1h late") — a state the app's
own product rule already said should be impossible, just not one either
existing mechanism actually enforced at the moment it mattered. Two root
causes, two fixes, same day:

- **`AppState.isExpiredEvent` compared calendar days, not due times.** A
  `.event` (reading, lecture, exam date) dropped off the dashboard only once
  `startOfDay(due) < startOfDay(now)` — so a 10:45am class stayed in OVERDUE,
  reading "late," until midnight. Changed to a hard `due < now` boundary:
  gone the moment it starts or was due, no day rounding. This does not
  regress all-day calendar entries: Canvas's ICS feed already resolves a
  date-only `DTSTART` to end-of-day LOCAL time (`CanvasICSClient`, see the
  ICS test "date-only DTSTART becomes end-of-day LOCAL time"), so an
  undated-time reading's `dueAt` is already effectively end-of-day and still
  lasts until then. Mirrored the identical change into
  `LedgerWidgetReader`'s own copy of the same predicate, so the Mac
  menu-bar/widget can't advertise a class that already started either.
- **Canvas no-submission assignments only auto-filed to Done on a live grade
  refresh.** `autoSubmittedNoSubmissionIDs` (applied in
  `updateSubmissionState`) requires a fresh Grade Watcher snapshot, so
  between refreshes a past-due no-submission assignment sat in OVERDUE with
  nothing to correct it. Added `AppState.isAutoFiledNoSubmission(_:now:)`,
  a cache-backed twin that reads the persisted
  `noSubmissionCanvasAssignmentIDs` set (added the same day for the caveat)
  and answers immediately, offline: true when the assignment's Canvas id is
  cached AND its due time has passed. Wired into `isCompleted`, so a
  past-due no-submission assignment lands in Done the instant its due time
  passes, from any launch, with or without a live session.

**Rejected: keeping day-granularity.** It was the entire bug — a morning
class read "late" all afternoon, which is precisely the state the owner's
own product rule ("an 'attend the session' assignment can't be late") was
written to prevent.

**Rejected: hiding no-submission assignments instead of filing them to
Done.** Done is the student's record of what happened; a no-submission
assignment that simply vanished from the dashboard once its due time passed
would look like data loss, not like the app correctly recognizing nothing
was expected. Filing to Done — exactly where the snapshot-driven auto-file
already puts these — keeps that record intact and consistent regardless of
which mechanism (offline cache or live refresh) got there first.

## 2026-08-27 — Remove the readings book icon; the no-submission caveat is now the single marker
Follow-up to the entry directly below. The owner's device pass found that the
new "nothing to submit" caveat and the pre-existing small book icon on
readings/event items (`AssignmentCardView`, and the same convention in the
Mac menu-bar's `LHFScenes.row(for:)`) were two separate visual vocabularies
stating the same fact — a reading or calendar event never takes a
submission, by definition, exactly like a Canvas assignment the caveat
already covers. The book icon is deleted everywhere
(`systemName: "book"` — zero remaining hits repo-wide); the card's "nothing
to submit" tag and expanded sentence now cover readings/events too, via a
new `DashItem.showsNothingToSubmit` display predicate
(`requiresNoSubmission || assignment.kind == .event`). The Mac menu-bar row
lost its icon but did not gain the caveat text — a judgment call, not an
owner ask: it stays a compact, glanceable list rather than growing per-row
prose, and the dashboard card is where the full statement lives.

The stored field `DashItem.requiresNoSubmission` itself is **unchanged in
meaning** — it still means "Canvas reported this specific assignment needs
no online submission," which is what
`CoursePreferences.noSubmissionRemindersEnabled` (the per-class "assignments
with nothing to submit" reminder toggle) gates on. Readings' reminders are
already governed by the separate "readings and check-ins" toggle; widening
`requiresNoSubmission` itself (rather than adding a new display-only
predicate) would have made a reading answer to both toggles at once, which
is not what was asked for. Only the display widened.

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
