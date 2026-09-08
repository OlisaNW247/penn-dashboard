# Onboarding walk handoff — the intro rewrite, the five-step walk, and what nobody has seen yet

_Written 2026-09-08 at the end of a build session. Branch **`onboarding-walk`**,
cut from `assistant-ui` at `0dc5b84`. Read section 4 before you touch the login
panes._

## 1. Where things stand

Three files changed, nothing committed before this branch:

| File | What |
|---|---|
| `LowHangingFruitUI/IntroView.swift` | Full rewrite. Three intro screens, new copy, a morphing chip illustration. |
| `LowHangingFruitUI/OnboardingView.swift` | The connect checklist became a linear five-step walk. |
| `LowHangingFruitUI/RootView.swift` | One additive line: `.environmentObject(scheduler)` on the `OnboardingView` call site. |

`swift build` clean and **769 tests / 78 suites green** on the owner's Mac, which
is the `assistant-ui` baseline after the update gate landed. Do not accept a
lower count as success; the older 736/76 figure in some notes predates
`0dc5b84`.

The iOS app builds for the simulator and was walked by hand there. What that
walk did and did not cover is section 3, and it is the most important part of
this document.

## 2. What changed, and why it looks the way it does

### The intro (`IntroView.swift`)

Three screens: why we built it, what it is, how it works. The copy is the
owner's, verbatim, in a deliberate voice — two Penn juniors talking to another
student, first person plural, no em dashes, no aspirational closing lines. **Do
not "tighten" it.** If it needs to change, that is a content decision, not a
cleanup.

Two things in it were decided during the session rather than handed down:

- **The fourth "how it works" bullet** is Grade Watcher ("Your real grade in
  every class, and what each assignment is actually worth"). Screen one opens on
  "the grade still comes back lower than it should be", and without a grades
  line the list never closes the loop it opened.
- **The privacy line was rewritten.** The spec said "nothing leaves your phone",
  two lines under a bullet advertising the assistant, which sends class data to
  Anthropic. It now reads "No account to make, and there's no Locust server" —
  which is the claim CLAUDE.md says is still true. Do not revert this to the
  stronger phrasing.

One structural thing worth knowing: **there is no `TabView`.** The chip
illustration morphs across all three screens through `matchedGeometryEffect`,
which cannot survive a paged `TabView` (each page is a separate view hierarchy
and the paging transition destroys the namespace). Paging is a `DragGesture`
over a persistent chip layer. A side effect is that the file has no platform
conditionals at all, which matters because `swift test` compiles the macOS
slice.

### The walk (`OnboardingView.swift`)

The old `.steps` hub — one scrolling checklist that launched full-screen panes
and dropped you back on itself — is gone. `Phase` is now a straight line:

```
.name → .canvasLogin → .gradescopeLogin → .classPicker → .reminders → .courseSetup
```

Canvas is the only required step. Gradescope, classes and reminders are each
skippable. The end-of-walk branch (`finishOnboarding()`) is the old "Go to
dashboard" button's two-line if/else, preserved verbatim so the destination
never diverges from `shouldOfferCourseSetup`'s gating.

Three behaviours were added rather than ported:

- **Step 5, reminders, is new.** It asks for notification permission in context
  and sets the default lead time and digest hour. It writes the same
  `NotificationScheduler` state that Settings → Reminders and Profile →
  Notifications read, deliberately, so the two can never disagree. Permission
  denial never blocks the walk.
- **Pasting a Canvas calendar link now advances the walk.** In the hub it was a
  no-op, which was safe because the checklist stayed on screen with a checkmark.
  In a linear flow that would strand the student on a step with no forward
  control.
- **Back-navigating into an already-connected step** shows a "connected,
  continue" screen instead of re-mounting the login pane, which would re-purge
  cookies and reload Penn SSO for nothing.

`RootView.swift`'s one added line is not cosmetic: `NotificationScheduler` loads
from `UserDefaults.lhf` once at construction and never re-reads, so a
locally-owned instance would go stale at the onboarding → dashboard handoff and
Profile would show pre-onboarding values.

## 3. What was verified, and what was not

**Walked on an iPhone 17 Pro simulator and confirmed correct:**

- Intro screens 1, 2 and 3.
- Step 1 (name).
- Step 2 (Canvas), including the real PennKey page rendering full-height behind
  the step chrome.

**Never rendered by anyone:**

- Step 3 (Gradescope)
- Step 4 (class picker)
- Step 5 (reminders)

These need a live Canvas session to reach, and preview mode skips onboarding
entirely, so there is no way around a real PennKey login. This is the same gap
CLAUDE.md already records for the per-course walk.

**Treat this as the top risk on the branch.** The bug in section 4 lived in
chrome that steps 3 and 4 also use, and it was invisible until someone looked at
a screenshot. Steps 3, 4 and 5 have had exactly as much visual verification as
step 2 had before it turned out to be broken: none.

The first job of the next session is to log in with a real PennKey on the
simulator and screenshot steps 3, 4 and 5.

## 4. The trap this session paid for

**An unsized `Color.clear` placeholder expands to fill, and `minHeight` is a
floor, not a ceiling.**

`skipButton` returns `Color.clear` for steps with no skip action. `topBar`
wrapped it in `.frame(minWidth: 44, minHeight: 32)`. `Color.clear` has no
intrinsic size, so it took every point of height on offer, inflated the top bar
HStack, centred the back chevron a third of the way down the screen and pushed
everything below it down with it.

The symptom pointed somewhere else entirely: the Canvas WebView appeared
squeezed into a thin band with a screenful of empty background above it, so it
read as "the login pane isn't filling". Three separate fixes went looking for
missing height inside the panes — a `.frame(maxHeight: .infinity)` on the pane,
a `safeAreaInset` restructure of the chrome, a fill on `OnboardingView.body` —
and none of them touched the cause. The height was never missing. An invisible
view was eating it.

The fix is one line in `skipButton`: size the placeholder at the source,
`Color.clear.frame(width: 44, height: 32)`.

Two things to carry forward:

1. **`backButton` was never affected** because it uses fixed `width:height:`.
   The asymmetry is the tell. If one side of a bar behaves and the other does
   not, compare their frames before theorising about their parents.
2. **Instrument earlier.** Temporary `.border(Color.red)` on three views found
   this in one build cycle after three cycles of reasoning had not. When a
   layout bug survives two fixes, stop reasoning and draw the frames.

There is a matching entry in CLAUDE.md's trap list.

## 5. Open decisions — these are the owner's, and they block a clean pass

1. **The app calls itself two different names on consecutive screens.** Intro
   screen 2 says "Locust is a class assistant…"; step 1 says "welcome to low
   hanging fruit". The rename was deliberately scoped to intro copy only, since
   a real rename touches the bundle id, targets, entitlements and the App Store
   listing. Decide the name, then make all eight screens agree.
2. **Casing is inconsistent across the seam.** The intro is sentence case
   ("Continue", "Skip"); the walk is lowercase ("continue", "your name"), which
   matches Settings. Both are defensible. Having both is not.
3. **Instrument Serif is not in the project.** `RedesignTokens.swift` says so
   outright — no font files are bundled, so `fontIsAvailable` is always false
   and every headline renders system New York. Drop the `.ttf` files in
   `LowHangingFruitUI/Resources/` and register them via `UIAppFonts` in
   `project.yml` under `info.properties` — never in Info.plist directly, per the
   xcodegen trap.

## 6. Smaller things left on the floor

- `SettingsPage.swift:137` still reads "everything stays on your phone." That is
  the last stale privacy overclaim in the app; `docs/PRIVACY.md` and the intro
  were both fixed, this one was not.
- `CanvasSignInTipsCard` contains "That's normal — the screen isn't stuck." An
  em dash, which the onboarding voice spec rules out. Pre-existing copy.
- Intro screen 1's scatter now has three chips clamped to the same y, which
  reads slightly as a shelf rather than as chaos. Cosmetic, unfixed.
- The intro's chip/text boundary is a `PreferenceKey` (`TextTopKey`), not a
  tuned constant, and that is load-bearing: two passes tried tuning fractions
  and both drove chips through the headline. The file comment explains why.
  Do not replace it with a constant.

## 7. Hazard: this checkout had two sessions writing to it

During this session another process was actively editing and committing to the
same working tree. It created `Update/`, recreated those files within a minute
of them being moved aside, and committed `0dc5b84` ("Gate old builds behind a
required update", 1,660 insertions across 14 files) as the owner's git identity.

Nothing was lost, but one `mv` restore landed a directory inside itself as a
result. If you run agents against this checkout, know what else is running.
