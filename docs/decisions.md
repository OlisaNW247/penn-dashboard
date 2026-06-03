# Decisions

Running log of decisions worth remembering. **Newest on top.** Each entry:
date, the decision, and what was rejected and why.

---

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
