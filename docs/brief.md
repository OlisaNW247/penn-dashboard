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
- `ContentView.swift` — root view, sectioned list, top-level navigation
- `AppState.swift` — observable app state, assignment store, filters
- `PennDashboardApp.swift` — `@main` app entry, scene setup
- `AutoSyncCoordinator.swift` — background refresh loop tying scrapers to state
- `Canvas/CanvasICSClient.swift` + `Canvas/ICSParser.swift` — Canvas calendar feed
- `CanvasDiscovery/CanvasRequirementScanner.swift` — discovers Canvas feed URLs
- `Gradescope/GradescopeClient.swift` — Gradescope session + scrape
- `Models/Assignment.swift` — shared assignment model
- `RecurringTask.swift` + `RecurringTaskSheet.swift` — user-added recurring items

## Current state
Mac build is functional end-to-end: login sheets for Canvas/Gradescope work,
assignments populate, auto-sync runs. iPhone UI rework is in progress on
`marco/ios-ui-rework`. Design system (see [design.md](design.md)) is being
applied across both targets.

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
