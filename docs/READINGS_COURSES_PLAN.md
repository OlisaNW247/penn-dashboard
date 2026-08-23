# Readings-only courses — detection, explanation, opt-in

> ## SHIPPED & DEVICE-VALIDATED — 2026-08-23 (v3.5)
>
> Everything below was built, plus what the device taught us along the way:
> - Modules probe runs on Canvas's JSON API (HTML scrape is fallback only);
>   `include[]=content_details` is mandatory or every item arrives undated.
> - Dates for Pages/Files come from the PLANNER API (student to-do dates —
>   the thing Canvas's dashboard renders). Two-pass join: content-id first,
>   exact-normalized-title fallback (Pages carry NO content_id, only a
>   page_url slug). Ambiguous titles stay undated by design.
> - Decisions import IMMEDIATELY (nudge answer / Settings toggle), not on
>   next launch; module rows persist via upsert in their own source
>   partition (.canvasModules).
> - Enrolled courses without a parseable DEPT+number code (diagnostics
>   sites, class-year orgs, archives) are filtered everywhere; known false
>   positive: "TAP 2028" (parses like a code) — manual toggle.
> - Validated on device: 55-item readings course detected silent(55),
>   opt-in imported all 55, planner dated 20/55 (all the professor has
>   dated), dated readings on the timeline, rest in Later. Junk courses
>   gone from Grade Watcher/picker/Settings. 449 tests green.
>
> Open before any merge toward v3: Marco's review (login pane, observer
> exceptions, dashboard/Settings changes are his layer).

_v2, 2026-08-23, for v3.5. Supersedes the Settings-toggle-first plan; the
user experience is now a proactive, explained, one-time ask per course._

## Goal

When LHF detects an enrolled course it is not representing (readings with
nothing to submit, or no calendar presence at all), it shows a one-time
page that names the course, explains exactly what was found, and asks the
user whether to include those items. Detection is continuous (every
sync/scan); the ask is once per course unless the course's shape
materially changes. Settings remains the place to change the answer later.

## Feasibility — confirmed against existing code

Three data sources already exist in the Kit; together they are enough to
detect and explain this accurately:

| Source | Auth needed | What it gives us | Exists today |
|---|---|---|---|
| ICS feed (`CanvasICSClient`) | No (bearer URL) | Every dated calendar item, already classified `.assignment`/`.quiz`/`.discussion`/`.event`, with course code | Yes — `.event` items are parsed then discarded by the `isAssignment` filter |
| Course enumeration (`CanvasDiscoveryClient`) | Cookie session | All enrolled courses via `/courses` + `/dashboard` (it already fetches both), incl. courses with zero calendar presence | Yes — used by requirement scanning |
| Per-course probe (`CanvasDiscoveryClient` + `CanvasGradesClient` patterns) | Cookie session | Syllabus page (already fetched), assignment-group JSON (already decoded for grades), and — new fetch — the course Modules page listing readings | Partially — modules fetch is the one new network surface |

Session caveat: cookie sessions expire. The engine runs authenticated
probes only while `canvasSessionExpired == false` (LHF already tracks
this for Grade Watcher) and falls back to feed-only detection otherwise.
Feed-only still catches the "readings on the calendar" shape; only the
"invisible course" shape needs the session.

## Course profiles the engine can distinguish

Computed per course, every sync:

- **NORMAL** — feed has submittable work for the course. No nudge.
- **READINGS_ON_CALENDAR** — feed has `.event` items but no assignments
  for the course. Explanation can be concrete: "N dated readings through
  DATE, nothing to submit."
- **SILENT** — enrolled (per authenticated course list) but zero feed
  items. Probe (session required): assignment groups empty or
  non-submittable (`submission_types: none/on_paper`) + Modules page
  readings count → "no calendar items; N readings found in Modules."
- **UNKNOWN-SILENT** — SILENT but no live session to probe. Nudge still
  possible but with honest copy ("this course isn't publishing anything
  LHF can see; reconnect Canvas login to let LHF look closer").

## The ask, and its lifecycle

- New persisted decision store (UserDefaults.lhf — never `.standard`):
  `courseContentDecisions: [courseKey: {choice: in/out, profileFingerprint,
  decidedAt}]`.
- After each sync/scan, courses with an actionable profile
  (READINGS_ON_CALENDAR, SILENT-with-findings) and no matching decision
  enter a nudge queue; the dashboard presents ONE sheet per app-open at
  most (no nag storms).
- The sheet: course name/code, the profile-specific explanation with real
  counts and date ranges, and two choices — "Add these to my list" /
  "Not for this course" — plus a line noting it can be changed in
  Settings later.
- Re-ask only when the profile fingerprint changes class (e.g. a SILENT
  course starts emitting calendar items, or a new term's course appears).
  New courses each semester naturally retrigger.

## Implementation phases

### Phase 1 — Kit: profile engine (Olisa)
1. Ingest all calendar items (`fetchCalendarItems`), keep `kind` through
   `StoredAssignment`/ledger; display-time filtering, so opt-in/out is
   instant and non-destructive.
2. Parse the enrolled-course list out of the `/courses` HTML
   `CanvasDiscoveryClient` already downloads (id, code, name, term).
3. Per-course probe: reuse the grades client's assignment-group JSON for
   submittability; add ONE new fetch (course Modules page) with a parser
   for item titles + dates-if-present. HTML parsing fragility is an
   accepted, established pattern in this codebase.
4. `CourseProfileEngine`: pure function (feed items, enrolled courses,
   probe results) → per-course profile + fingerprint. Fully fixture-
   testable, synthetic data only.

### Phase 2 — AppState: decisions + queue (Olisa, boundary with Marco)
5. Decision store, nudge queue, trigger points after sync and after
   requirement/Grade Watcher scans; session-expired degradation.
6. Item inclusion filter consults decisions (assignments always in;
   `.event`/module-reading items only for opted-in courses; default out).

### Phase 3 — UI (Marco's layer — sync with him BEFORE this phase)
7. Nudge sheet (one per app-open), profile-specific copy, two actions.
8. Settings "Courses & content" section as the management surface —
   every detected course, current choice, flip anytime.
9. Dashboard cards for readings: kind marker, "mark done" (ledger already
   supports manual completion), no submission affordances. Undated module
   readings: design decision — either a "No date" group or dates via the
   existing `SyllabusMatcher`; decide with Marco at phase start.
10. Widget: verify it renders the same filtered set (it reads the shared
    store; confirm no independent kind filtering).

### Hard requirement — Grade Watcher independence

The list-visibility decision and Grade Watcher coverage are SEPARATE
axes, by explicit product decision (2026-08-23):

- A course stays available to Grade Watcher **regardless** of whether
  the user opted its readings/events into the list, and regardless of
  profile (a READINGS_ON_CALENDAR or SILENT course can still carry
  Canvas grades — on-paper work is graded without submissions).
- Wiring: Grade Watcher already refreshes from
  `selectedCanvasCourseIDs()` (class picker / `canvasCourseIDsByCode`),
  not from dashboard items. Keep it that way: the new content-decision
  filter must apply ONLY to dashboard/widget item building, never to
  course discovery or the picker's course map.
- New behavior: courses discovered via the enrolled-course list (Phase
  1.2) — including ones with zero feed items — flow INTO
  `canvasCourseIDsByCode`, so a readings-only course becomes watchable
  at all (today it can't be, since it's never discovered).
- Check `docs/grades.md` Decision 4 (course hiding vs Grade Watcher)
  when implementing, and extend it to cover the new decision axis so the
  two hiding concepts don't get conflated.

### Phase 4 — Tests + device validation
11. Fixtures (synthetic only — project rule): feeds that are
    events-only, mixed, and empty per course; probe fixtures for
    non-submittable assignment groups and module readings; engine
    profile/fingerprint tests; decision-store default-out tests.
12. On-device with the real readings course: nudge appears once with
    accurate counts, opt-in shows readings correctly dated, opt-out
    stays quiet, decision survives relaunch and resync, and a normal
    course never nudges.
13. Grade Watcher independence: with the readings course opted OUT of
    the list, it still appears in the class picker and Grade Watcher
    refreshes it; opting in/out flips list visibility only, never the
    watcher's course set.

## Constraints and risks

- Cross-cutting model change (ledger rows carry kind; new persisted
  stores) → owner sync first; ledger migrations cannot run under
  `swift test` (no App Group entitlement) — device pass over a populated
  install required.
- Modules-page HTML is the fragile new surface; scope its parser
  defensively (fail → UNKNOWN-SILENT copy, never a crash or a wrong
  claim).
- All of this stays on-device (privacy pitch intact); no new data leaves
  the phone.
- `swift test` = macOS slice; iOS-only UI behind `#if os(iOS)`.

## Validation still worth 2 minutes

Canvas web → Calendar → enable the readings course: tells us whether the
user's own course is READINGS_ON_CALENDAR or SILENT — which decides which
probe path its device test exercises first. Not a plan blocker; the plan
covers both.
