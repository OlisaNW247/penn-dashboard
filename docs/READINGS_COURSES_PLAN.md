# Readings-only courses — implementation plan

_Written 2026-08-23, for v3.5. Problem: a Canvas course whose work is
non-submittable readings never shows up in LHF — not the items, not even
the course._

## Root cause (confirmed in code, 2026-08-23)

The data already flows most of the way:

- `ICSParser` parses **every** VEVENT in the feed — no filtering there.
- `CanvasICSClient.classify()` already labels calendar-event items as
  `.event` (UID contains "calendar"/"event", or URL contains
  `/calendar_events/`).
- The sync path (`AppState.sync`, AppState.swift ~708) calls
  `fetchAssignments()`, which is `filter(\.isAssignment)` — and
  `Assignment.isAssignment` is `kind == .assignment`, full stop
  (Assignment.swift:60).

So readings that appear on the Canvas calendar are fetched, parsed,
classified `.event`, and then discarded. Courses are discovered from the
surviving items, so a readings-only course vanishes entirely.

## Phase 0 — diagnosis fork (user, 2 min, no code)

Open **canvas.upenn.edu → Calendar** in a browser and enable the readings
course in the sidebar course list.

- **Readings appear on Canvas's own calendar** → they are in the ICS feed
  → Phases 1–4 below apply as written.
- **They don't appear** → the readings live only in Modules/Syllabus pages,
  the feed has nothing, and the ingestion side of this plan reroutes
  through the existing `Syllabus/` pipeline (`CanvasSyllabusClient`,
  `SyllabusParser`, `SyllabusReconciler`) instead of the ICS path. The
  preference model and UI (Phases 2–3) stay the same either way.

## Phase 1 — data layer (LowHangingFruitKit — Olisa)

1. **Ingest `.event` items in sync.** Switch the sync fetch from
   `fetchAssignments()` to `fetchCalendarItems()` and carry `kind`
   through `StoredAssignment`/the ledger. Nothing may change for
   existing users yet — a downstream inclusion filter (Phase 2) defaults
   to assignments-only.
2. **Course discovery from all items.** Build the detected-course set
   (incl. `canvasCourseIDsByCode` handling) from all calendar items, so a
   readings-only course exists in Settings even while its items are
   filtered out.
3. **Semantics for `.event` items:** no submission concept — never
   `submitted`, excluded from Grade Watcher and submission scanning;
   manual "mark done" works exactly like manual assignments (completion
   ledger is already source-agnostic).

## Phase 2 — preference model (Kit + AppState boundary)

4. **Per-course content policy**, persisted via `UserDefaults.lhf`
   (NEVER `.standard` — project rule): something like
   `courseEventInclusion: [courseCode: Bool]`, default **false** for
   every course. Existing users see zero change until they opt a course
   in. The dashboard/widget item builders apply this filter, not the
   fetch layer — the ledger keeps everything so toggling is instant and
   non-destructive, no resync needed.

## Phase 3 — UI (LowHangingFruitUI — Marco's layer, sync with him FIRST)

5. **Settings → new "Courses & content" section:** list every detected
   course; per course, a toggle "Show calendar events & readings"
   (assignments always on). Readings-only courses appear here with a hint
   ("this course only has readings — turn this on to see them").
6. **Dashboard rendering** of `.event` items: same card, a small visual
   kind marker; "mark done" enabled; no submission affordances.
7. **Widget:** respects the same filtered item set (it reads the shared
   store — verify nothing in `LHFWidget` re-filters by kind).

## Phase 4 — tests + device validation

8. Fixture ICS with synthetic calendar-event VEVENTs (SYNTHETIC values
   only — project rule: never commit real Canvas data/UIDs/URLs) covering:
   classification, course discovery from events-only feeds, the inclusion
   filter's default-off behavior, and toggle-on behavior.
9. Device pass on the real readings course: course appears in Settings,
   toggle on → readings appear dated correctly, toggle off → gone without
   resync; existing courses unchanged throughout.

## Constraints

- Cross-cutting model change (`StoredAssignment`, ledger rows gain kind
  semantics) → **sync between owners before implementing** (project
  rule), and ledger migrations are untestable in `swift test` (no App
  Group entitlement) — the migration, if any, needs a device pass over a
  populated install.
- `swift test` compiles the macOS slice — any iOS-only UI stays behind
  `#if os(iOS)`.
