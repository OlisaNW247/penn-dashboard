# Smooth dark mode handoff

Last updated: September 14, 2026  
Branch: `codex/fire-dark-mode`  
Base: `origin/codex/smooth-header-layout` (`d8467af`)

## Direction

Dark mode is now “Smooth after sunset”: a blue-black paper field, slightly
raised navy cards, warm cream type, and cool blue-grey rules. The existing
tomato, marigold, lemon, teal, cobalt, and grape ramp is unchanged, so urgency
and section identity mean the same thing in both appearances.

Core dark values:

- Paper: `#0B1020`
- Raised card: `#151B2D`
- Surface: `#171D31`
- Rule: `#303A59`
- Ink: `#F8F1E5`
- Muted: `#AEB8CF`

The palette lives in
`LowHangingFruitKit/Sources/LowHangingFruitUI/RedesignTokens.swift`. Both the
new `smooth*` tokens and the older `v2*` aliases resolve through the same
semantic dark values, so Dashboard, Done, Settings, Profile, Ask, Grade
Watcher, grade reports, pushed pages, and sheets stay coherent.

Intro and onboarding were intentionally not redesigned. They inherit the
adaptive tokens where already used, but this pass makes no layout or visual
promise for those first-run screens.

## Empty-state artwork

The bundled `chill.jpg` is black ink on white paper. Its former multiply blend
disappeared on a dark background. `ContentView.swift` now uses invert + screen
in dark mode and preserves multiply in light mode, including the animated Todo
empty state.

## Verification

- iOS Simulator Debug build succeeded on `Locust Preview`.
- macOS Debug build succeeded.
- The full Swift package suite passed: 1,250 tests in 123 suites, plus 4 XCTest
  tests, with no failures.
- `git diff --check` passed.
- Simulator visual QA covered Dashboard, Done, Settings, Profile, Ask, Grade
  Watcher, and the grade report.
- Contrast checks for the core pairs range from 6.30:1 to 16.86:1.
