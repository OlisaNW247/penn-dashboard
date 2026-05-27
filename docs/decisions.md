# Decisions

Running log of decisions worth remembering. **Newest on top.** Each entry:
date, the decision, and what was rejected and why.

---

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
