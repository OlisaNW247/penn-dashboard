# Smooth intro and app polish handoff

Last updated: September 13, 2026  
Branch: `codex/smooth-header-layout`  
Base at the start of this work: `origin/v5` (`80f24f2`)  
Latest implementation commit before this document: `f825837`

## Final user experience

### First-launch story

The first app launch now tells one continuous animated story:

1. A relaxed standing figure appears on a quiet screen.
2. Eighteen assignments, grades, reminders, messages, and schedule items appear
   irregularly around the screen. Their arrival begins slowly and accelerates,
   while the figure becomes progressively more stressed.
3. The visual noise resolves into Smooth's centered squiggly line. The figure
   reclines on it with their head resting on the line.
4. `There's more to life than school.` appears first.
5. `Make it all Smooth.` appears beneath the figure, with `Smooth` italicized
   and animated separately.
6. The Get Started button appears only after the story has finished.

The Skip button still bypasses the story. Reduced Motion users receive the same
content without depending on the full motion sequence.

Implementation: `LowHangingFruitKit/Sources/LowHangingFruitUI/IntroView.swift`

### Restored product explanation

Get Started now leads into three explanatory pages that had existed in an
earlier version but were removed when the animated intro was first introduced:

1. Why Smooth exists: avoiding lost points on easy-to-miss work.
2. How Smooth helps: organizing the low-hanging fruit into a clear workflow.
3. What the app provides: Dashboard, Reminders, Ask, and Grade Watcher.

The last page proceeds to the existing connection sequence: Canvas,
Gradescope, reminders, and the rest of onboarding. The explanatory pages can
be advanced by swiping or by using the Continue buttons.

Implementation: `LowHangingFruitKit/Sources/LowHangingFruitUI/MissionIntroView.swift`

### Temporary full-onboarding review mode

Debug builds support `-LHFFullOnboardingReview`. For that process only, it:

- reopens the intro and complete onboarding flow;
- presents Canvas and Gradescope as disconnected;
- starts the login panes with their normal clean WebView sessions; and
- leaves the developer's persisted integrations, preferences, and app data
  untouched, so an ordinary relaunch restores the real state.

This is a review seam, not a user-facing reset feature. It must remain inside
the existing `#if DEBUG` block.

Implementation: `LowHangingFruitKit/Sources/LowHangingFruitUI/AppState.swift`

### Dashboard and settings polish

- The dashboard keeps `Smooth` and the weekday on one fitted line.
- The three-wave underline is 90 points wide and offset by 2 points, so it sits
  beneath the rendered `Smooth` wordmark without extending into the weekday.
- The Settings screen no longer contains Ask or Grade Watcher sections.
- Grade Watcher remains directly accessible from the dashboard's chart button.
- The seasonal `new semester?` rollover prompt is no longer rendered in
  Profile. Existing archived-semester restore controls are preserved.

Implementations:

- `LowHangingFruitKit/Sources/LowHangingFruitUI/ContentView.swift`
- `LowHangingFruitKit/Sources/LowHangingFruitUI/SettingsPage.swift`
- `LowHangingFruitKit/Sources/LowHangingFruitUI/ProfileSemesterSection.swift`

## Commit history for this design pass

- `a02880c` — Turn first launch chaos into a Smooth intro
- `65479a8` — Add life beyond school intro message
- `04005d0` — Give Smooth intro three distinct beats
- `a02bebf` — Make Smooth intro build into a fluid story
- `ed5ed11` — Stage the Smooth intro finale
- `fba042c` — Restore the complete first-run review flow
- `f825837` — Simplify settings and tighten dashboard underline

Intermediate dashboard-header experiments were explicitly reverted in
`dc733c2`; the final header remains on one line.

## Verification completed

- Debug simulator build succeeded for the Locust Preview simulator.
- Signed Debug device build succeeded for the connected iPhone 17 Pro.
- The full first-run story, three mission pages, and clean connection sequence
  were reviewed on the physical iPhone using `-LHFFullOnboardingReview`.
- The final normal app build was installed and launched on that iPhone without
  the review flag, restoring its persisted app state.
- Simulator visual checks covered the final intro pose, all three mission
  pages, the simplified Settings screen, and the tightened dashboard wordmark.
- `git diff --check` passed before the implementation commits.

## Notes for future work

- The mission page still mentions Ask and Grade Watcher as app capabilities;
  the request was to remove their Settings shortcuts, not the features.
- Removing the semester prompt only changes presentation. No archive or restore
  data was deleted, and existing archived semesters can still be restored.
- Device installation is local to the reviewed iPhone; the durable source of
  truth is the GitHub branch named above.
