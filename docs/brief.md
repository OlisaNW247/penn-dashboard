# Penn Dashboard — Project Brief

## What it is
Penn Dashboard is a personal academic dashboard for Penn students. It pulls
assignments, deadlines, and course events from Canvas and Gradescope into a
single chronological view so a student can see what's actually due next
without juggling tabs. The product name in the UI is **LHF — Low Hanging
Fruit**: the list is sorted so the next actionable thing is always on top.

## Target platforms
- iOS (iPhone)
- macOS

Both targets share the same SwiftUI codebase. macOS was built first; the
iPhone layout is being adapted from it.

## Collaborators
- **Marco** — UI / SwiftUI views, layout, interaction, design system.
- **Olisa** — Data layer: Canvas + Gradescope scrapers, ICS parsing,
  requirement discovery, sync coordination, models.

## Tech stack
- Swift 5.9+
- SwiftUI for all views (iOS + macOS)
- Swift Package Manager (SPM) — no Xcode project file checked in; the
  package manifest is the source of truth
- No third-party UI dependencies

## Key files
App target (`Sources/LowHangingFruitApp/`, Marco's UI):
- `LowHangingFruitApp.swift` — `@main` app entry; routes onboarding ↔ dashboard
- `ContentView.swift` — redesigned root: header + greeting + ring + toggle + list
- `DashboardViewModel.swift` — presentation layer over `AppState`; sectioning,
  weekly ring math, completion/edit state (reads the model, never mutates it)
- `AssignmentCardView.swift` — spine card; tap-to-complete, calendar edit button
- `ProgressRingView.swift` · `SegmentedToggle.swift` · `TimelineSectionView.swift`
  · `DoneView.swift` — dashboard components
- `RedesignTokens.swift` — v2 palette, fonts (with system fallback), urgency model
- `OnboardingView.swift` — first-run name + Canvas/Gradescope connect (cross-platform WebView)
- `SettingsSheet.swift` — accounts / recurring / suggestions, off the main header
- `SessionCookieStore.swift` — persists login cookies so the session survives launches
- `AppState.swift` — observable app state, assignment store, filters, user name
- `AutoSyncCoordinator.swift` — launch-time refresh; replays persisted cookies
- `SampleData.swift` — DEBUG fixtures for SwiftUI previews only

Data layer (`Sources/LowHangingFruitKit/`, Olisa's):
- `Canvas/CanvasICSClient.swift` + `Canvas/ICSParser.swift` — Canvas calendar feed
- `CanvasDiscovery/CanvasRequirementScanner.swift` — discovers Canvas feed URLs
- `Gradescope/GradescopeClient.swift` — Gradescope session + scrape (handles both
  submitted and **unsubmitted** assignment rows)
- `Models/Assignment.swift` — shared assignment model

## Current state
v2 redesign has shipped to `main`. Working end-to-end on macOS and builds for
iOS (run on iPhone via a hand-bundled `.app`; no committed Xcode app target yet).
- Onboarding captures your name + connects Canvas/Gradescope; the session now
  **persists across launches** (cookies are saved and replayed).
- Gradescope scraping handles **unsubmitted** assignments (previously a whole
  course like CIS 2400 could vanish because none of its rows had submission links).
- Dashboard: weekly ring, This week / All / Done, per-card due-date adjust
  ("manually adjusted"), and a manual **Sync** button.
See [design.md](design.md) for the full design system and [decisions.md](decisions.md).

## Working agreements
- Small PRs off `main`. No direct commits to `main`.
- One concern per PR; prefer many small merges over one big one.
- **Marco owns UI files** (views, sheets, design tokens, layout). Olisa
  should not refactor view code without asking.
- **Olisa owns the data layer** (scrapers, parsers, models, sync). Marco
  should not change scraper internals without asking.
- Cross-cutting changes (e.g. adding a field to `Assignment`) get a quick
  sync first so both sides land together.
- Decisions worth remembering go in [decisions.md](decisions.md), newest on top.
