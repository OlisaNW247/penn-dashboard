# Decisions

Running log of decisions worth remembering. **Newest on top.** Each entry:
date, the decision, and what was rejected and why.

---

## 2026-08-29 — Scope the dashboard to the current academic term
A user on 1.0 saw "CIS 3200 Homework 4 — 27 days late" from a class that had
already ended. Two holes, both now closed by one gate. (1) The assessments list
had no date floor at all — only the 5-month `isTooOld` cutoff — and Canvas
classifies plenty of homework as a quiz, so any quiz-shaped item from a finished
course rode into "this week" as overdue. (2) A 5-month rolling window is shorter
than a semester gap and says nothing about undated items, which never expired.

Scope is now decided by the academic calendar (`AcademicTerm`, in the data
layer), not by how long ago something was due: an item must be due on or after
the current term's start. There is no upper bound — next term's work is worth
looking ahead to. Undated Canvas items ride on their course, which counts as
live only while it still has current-term work; user-created items are never
dropped for lacking a date. Assessments also picked up the same "nothing lingers
more than a week past due" floor coursework already had.

The gate runs once, in `AppState.buckets`, before anything is bucketed, so a
list added later can't reintroduce the leak — that asymmetry is what caused this
bug. Term boundaries (Jan 1 / May 20 / Aug 15) sit earlier than Penn's first day
of classes so syllabus-week work still counts as current.
Rejected reading a term from the Canvas feed: the ICS carries no term field and
Penn's course names in it ("CIS 3200") carry no term code. Rejected simply
shortening the 5-month cutoff — any rolling window still can't tell June's
leftovers from September's work at the start of a term.

## 2026-08-28 — Ship an "Explore with sample data" demo mode
Canvas login goes through Penn SSO, so nobody without a PennKey — App Review
included — could get past onboarding. Onboarding now offers "Explore with sample
data", which opens the real dashboard on the bundled `SampleData` fixtures (those
moved out of `#if DEBUG` and now ship). The demo is in-memory only: `AppState`
flips `hasCompletedOnboarding` without persisting it, `DashboardViewModel` keeps
`usingSampleData` so completions and edits never reach the store, `reload` is
inert (a background sync used to wipe the fixtures), sync/auto-refresh are
skipped, and no notification is ever scheduled from fake deadlines. A dashboard
banner marks the demo and exits it. The `-LHFDemoData` screenshot seam now enters
the same mode, with the banner suppressed so store assets stay clean.
Rejected shipping reviewer-notes + video alone: Apple often asks for an in-app
demo path anyway, and it's a rejection round we can just not take. Rejected a
persisted demo flag — a demo that survives a relaunch is a way to accidentally
live in fake data.

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
