# Penn Dashboard — Project Brief

## What It Is

Penn Dashboard is a native app for UPenn students that aggregates academic deadlines from Canvas, Gradescope, and manually-entered recurring tasks into a single prioritized view. The core idea is "low hanging fruit" — surface what needs attention right now, sorted by urgency, with minimal friction.

## Target Platforms

- **iOS** (primary) — iPhone, designed for iPhone 17 Pro as reference device
- **macOS** (secondary) — native Mac app from the same Swift package

## Collaborators

| Person | Role |
|--------|------|
| **Marco** | UI design and front-end (SwiftUI views, design system, animations, layout) |
| **Olisa** | Data layer (Canvas ICS scraper, Gradescope scraper, Canvas Discovery scanner, AppState) |

Marco owns everything in `Sources/PennDashboardApp/` that is view-related.
Olisa owns `Sources/PennDashboardKit/` (scrapers, models, clients) and `AppState.swift`.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 6 |
| UI framework | SwiftUI (iOS 17+, macOS 14+) |
| Package manager | Swift Package Manager (tools-version 6.0) |
| Data / networking | Foundation, WebKit (cookie-based scrapers) |
| Build | `swift build` (macOS), `xcodebuild` (iOS Simulator) |

## Key Files

```
PennDashboardKit/
  Package.swift                          — package definition, platform targets
  Sources/
    PennDashboardKit/                    — Olisa's domain (do not edit without her)
      Models/Assignment.swift            — canonical Assignment model
      Canvas/CanvasICSClient.swift       — Canvas calendar feed parser
      Gradescope/GradescopeClient.swift  — Gradescope cookie scraper
      CanvasDiscovery/                   — Canvas syllabus/announcement scanner
    PennDashboardApp/                    — Marco's domain (UI)
      PennDashboardApp.swift             — @main entry point
      AppState.swift                     — shared state (Olisa owns, Marco reads)
      ContentView.swift                  — platform-adaptive root view
      DashboardView.swift                — main screen (header, toggle, card list)
      AssignmentCardView.swift           — individual assignment card
      SegmentedToggleView.swift          — custom pill toggle
      DesignSystem.swift                 — colors, fonts, Urgency, formatDue
      SettingsSheet.swift                — iOS settings/connection sheet
      SampleData.swift                   — DEBUG-only sample assignments
      EditDueSheet.swift                 — per-assignment due-date override
      RecurringTask.swift                — recurring task model + schedule logic
```

## Current State

- Canvas ICS feed, Gradescope, and Canvas Scan all connected and working on macOS
- iOS UI reworked and running on iPhone 17 Pro Simulator (branch `marco/ios-ui-rework`)
- Sample data injected in DEBUG mode so the UI is previewable without real credentials
- Due-date overrides are session-local (not persisted) — persistence is a future task

## Working Agreements

1. **No direct commits to `main`.** All work goes through a branch + PR.
2. **Small, focused PRs.** One concern per branch.
3. **Marco owns UI files.** Changes to any file in `PennDashboardApp/` other than `AppState.swift` go through Marco.
4. **Olisa owns the data layer.** `PennDashboardKit/` and `AppState.swift` are Olisa's. Marco reads but does not modify them.
5. **Both platforms must build.** Every PR must pass `swift build` (macOS) and `xcodebuild -destination 'generic/platform=iOS'` (iOS) before merge.
