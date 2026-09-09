# Locust onboarding handoff

Updated 2026-09-08 on branch `onboarding-walk`. The branch was based on
`827ff09` (`Put the step dots at the bottom, and hold Connect until sign-in`).
The current branch tip contains the complete onboarding redesign described
below. For the earlier implementation history and login-layout traps, see
`docs/ONBOARDING_WALK_HANDOFF.md`.

## Current product direction

The user-facing product name is **Locust**. Display names, visible app copy,
widget copy, menu-bar copy, diagnostics headings, support subjects, and update
copy use Locust. Internal compatibility-sensitive identifiers remain unchanged:
bundle IDs, target/module names, app-group names, defaults keys, and migration
symbols still use their existing LHF/LowHangingFruit names.

The onboarding should be concise and visual. Sample-data preview controls are
not shown during onboarding. The setup walk is for configuring the real app.

## Three-page intro

`LowHangingFruitKit/Sources/LowHangingFruitUI/IntroView.swift`

1. **“We kept losing points on the easy stuff.”** Nine assignment chips are
   scattered around the screen. There is no body copy.
2. **“Go get the low hanging fruit.”** The same nine SwiftUI views animate into
   explicit `CLASS → Assignment` rows. There is no body copy.
3. **“How Locust keeps you ahead.”** Four slim cards are visible together on a
   single phone screen:
   - Dashboard: miniature Canvas + Gradescope assignment rows.
   - Reminders: miniature Locust notification.
   - Ask: the real assistant tree/persimmon styling with the prompt “what is the
     attendance policy for this class?”
   - Grades: miniature Grade Watcher percentage, weekly change, and decided bar.

The last page has no repeated preview headings or explanatory subtext. Its only
exit is **Get started**. Page dots remain at the bottom.

The first two pages deliberately share one persistent `ChipLayer`; do not move
the chips into a `TabView`. Their identity across pages is what makes the morph
animate rather than jump-cut. The third page hides that layer and centers its
four-card overview vertically.

## Setup walk

`LowHangingFruitKit/Sources/LowHangingFruitUI/OnboardingView.swift`

The linear flow remains:

```text
name → Canvas → Gradescope → classes → reminders → course setup/dashboard
```

The name page now shows the supplied Locust branch/persimmon logo from
`LowHangingFruitUI/Resources/locust-logo-transparent.png`. The old sample-data
card is gone. Login tips, error cards, reset wording, and action hints were
shortened; the “Report a problem” action was removed from login error cards.

Canvas remains the only required connection. Its Connect button stays hidden
until the login observer sees the Penn SSO flow return to Canvas, with the
existing 75-second fail-open safety net. Do not regress the signed-in gating or
the bottom safe-area placement of the onboarding dots.

## Reopening the intro

For a normal install, delete Locust from the phone and install it again.

For a DEBUG build, launch with:

```text
-LHFOnboardingHarness
```

That overrides the in-memory intro/onboarding flags for the launch without
deleting the developer's real saved data. To jump directly to the final intro
page, also pass:

```text
-LHFIntroPage 2
```

The harness lives in `AppState.swift` and is compiled only in DEBUG builds.

## Verification at handoff

- `swift test`: **774 tests in 78 suites passed**.
- iOS simulator build: succeeded with `xcodebuild` for an iPhone 17 Pro.
- Intro pages 1 and 2 were visually checked during the redesign.
- The complete four-card page 3 was rendered and visually checked at iPhone 17
  Pro size; all four cards and Get started fit without scrolling.
- `git diff --check`: clean.

The physical iPhone appeared in `devicectl` as `unavailable`, so this exact
revision was not installed on hardware. The next chat should install the branch
on the phone once it is unlocked/connected and check page 3 at the owner's
preferred text size. The authenticated Canvas/Gradescope portions still require
real PennKey credentials for a complete end-to-end hardware walk.

## Likely next iteration points

- Decide whether the page-three title should stay “How Locust keeps you ahead.”
  after seeing it on the physical phone.
- Check the four slim cards at larger Dynamic Type sizes; the screen is wrapped
  in a vertical `ScrollView`, so content remains reachable, but the preferred
  no-scroll composition is calibrated to the default size.
- If the logo is adopted as the production app icon, update the asset catalog
  separately. This pass adds the logo to onboarding and changes display names;
  it does not perform an app-icon migration.
- Keep internal identifiers unchanged unless a separate migration is planned.
