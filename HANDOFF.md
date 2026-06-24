# Low Hanging Fruit Handoff

> **Canvas-only (1.0).** Earlier handoff notes described a Canvas + Gradescope
> product. As of the 1.0 App Store release the app is **Canvas-only** — Gradescope
> has been removed from onboarding, sync, settings, and the codebase. The
> canonical, up-to-date overview is [docs/brief.md](docs/brief.md).

## Current Product State

Low Hanging Fruit is a SwiftUI app (iPhone + macOS) built on a shared
`LowHangingFruitKit` package, with a real archive-ready Xcode app target in `App/`.

The app currently supports:

- Canvas calendar feed via ICS (feed URL captured automatically after login).
- Canvas event classification into assignments, quizzes, discussions, calendar events, and other items.
- Canvas syllabus/announcement scan through embedded WebView login.
- Manual one-off and recurring assignments for requirements that are not official Canvas assignments.
- Suggested recurring tasks from Canvas syllabus/announcement text, reviewed before being added.
- This week / All / Done views with local completion state.
- Due date/time display plus live countdown or overdue time.
- Local due-date reminders + an optional daily digest.

## Important Constraints

- Penn IT denied API access permanently, so Canvas assignments come from the user’s Canvas calendar ICS feed.
- Canvas ICS does not include submission state.
- Canvas calendar-feed and syllabus/announcement discovery are WebView session-cookie based.
- Generated build artifacts (`build/`, `LowHangingFruitKit/dist*/`, `.iosbuild/`) are intentionally ignored by Git.

## Project Layout

```text
App/                       # Xcode app target (@main, Info.plist, PrivacyInfo, icon)
  LHFApp.swift
project.yml                # xcodegen source of truth → LowHangingFruit.xcodeproj
LowHangingFruitKit/
  Package.swift
  Sources/
    LowHangingFruitUI/     # all SwiftUI (RootView, ContentView, AppState, …)
    LowHangingFruitKit/    # data layer
      Models/Assignment.swift
      Canvas/{CanvasICSClient,ICSParser}.swift
      CanvasDiscovery/{CanvasDiscoveryClient,CanvasRequirementScanner}.swift
  Tests/
    LowHangingFruitKitTests/
```

## Run And Test

Run the unit tests (data layer + notifications):

```sh
cd LowHangingFruitKit && swift test
```

Run the app: open `LowHangingFruit.xcodeproj` in Xcode and run the
`LowHangingFruit` scheme (iPhone simulator or Mac). To regenerate the project
after editing `project.yml`:

```sh
xcodegen generate
```

For App Store packaging steps see [docs/appstore/CHECKLIST.md](docs/appstore/CHECKLIST.md).

## Collaboration Rules

- Keep `main` stable.
- Work on short-lived branches.
- Open pull requests for review.
- Do not commit `LowHangingFruitKit/dist/` or `.build/`.
- Keep scraper changes covered with small HTML fixture tests.
- For UI work, avoid changing parsing logic in the same PR unless necessary.

## Suggested Ownership Split

- UI/UX owner: app layout, visual polish, onboarding, empty states, design implementation.
- Data/scraper owner: Canvas ICS, Gradescope scraping, Canvas syllabus/announcement scanning, tests.

## Good First UI Tasks

- Replace the current setup strip with the designed connection/onboarding UI.
- Improve row layout for small windows.
- Add a settings screen for connected services.
- Add a recurring-task management screen to edit/delete rules.
- Improve suggestion review UI for Canvas-found recurring tasks.

## Good First Data Tasks

- Add debug-safe capture for failed Gradescope date/status parsing.
- Improve Canvas course discovery if `/courses` or `/dashboard` markup changes.
- Add more Gradescope HTML fixtures from real pages with private details removed.
- Add retry/backoff for background auto-sync.
