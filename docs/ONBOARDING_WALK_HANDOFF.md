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

## 8. Second pass — the indicator moved, and Connect learned to wait

_Appended later the same day (2026-09-08), on top of the walk described above.
New baseline: **774 tests / 78 suites**, up from 769/78 by the five tests in the
second change. Same rule as before — do not accept a lower count as success._

### The step indicator is at the bottom on every step now

`topBar` no longer takes a `dots` argument; it is back to just a back chevron
and an optional skip. The three steps whose screen is a full-bleed pane
(`canvasStep`, `gradescopeStep`, `classesStep`) carry the dots in a
`.safeAreaInset(edge: .bottom)` of their own, alongside the top inset they
already had, through a shared `stepDotsBar(current:)`. `connectedStep` puts
them above its "continue" button, the way `nameStep` and `remindersFooter`
always did.

The old `topBar` comment argued the dots *had* to sit up top on those three
steps because the panes own their bottom action bar and there was "no bottom
left to put dots in." That premise was wrong: a pane's own action bar and a
chrome bar beneath it coexist exactly the way its top action bar and the top
chrome already did. What is **not** wrong, and must not be undone, is the
reason those steps use `safeAreaInset` rather than a `VStack` sibling — a
sibling collapses the pane, which is section 4's whole story.

### "Connect Canvas" no longer shows before it can work

The button used to be on screen from the tips card onward, including while the
student was still typing their PennKey password, where tapping it always failed
with "Couldn't connect Canvas yet." It now appears only once Penn's SSO chain
has actually handed the pane back to Canvas.

`LoginNavigationObserver` gained `isSignedInDestination(host:path:marker:sawForeignHost:)`
— pure and `nonisolated`, so it is testable without a live `WKWebView`. Three
conditions, each load-bearing:

- the host must contain the caller's marker (`CanvasLoginPane` sets
  `"canvas.upenn.edu"`; `GradescopeLoginPane` sets nothing, so this can never
  fire there),
- a *foreign* host must have been seen first — the pane's own first load **is**
  `canvas.upenn.edu`, so a Canvas hop before the SSO chain is the start of the
  login, not the end of it,
- the path must not contain `/login` — Canvas bounces failed or partial SSO
  back onto its own login pages, same host, not a session.

Only `didCommit` counts; a redirect in flight may yet bounce onward.

**The 75-second fail-open backstop is not decoration.** Canvas is the only
required step in the walk, so a heuristic that misdetects and hides the button
forever locks a student out of the entire app. The timer starts when the
sign-in page is actually on screen, not while the tips card is up, and its
worst case is exactly the old always-visible behaviour. Do not remove it in the
name of tidiness.

Two wrong fixes, recorded because both look reasonable:

1. **Disabling the button instead of hiding it.** A greyed-out primary button
   invites the tap it is there to prevent, and reads as "the app is broken"
   rather than "not yet."
2. **Gating on cookie presence.** `canvas.upenn.edu` sets cookies *before* any
   login (CSRF, session-log), so the button would appear almost immediately —
   the bug, with more machinery behind it.

`LoginActionBar.showsConnect` defaults to `true` precisely so the Gradescope
call site did not have to change; "cancel", "reload" and "start over" are never
gated on it, because they are the documented escape hatches out of a stuck Penn
login.

### Seen, and not seen

Walked on an iPhone 17 Pro simulator: step 2 with the dots at the bottom, the
Connect button absent at the PennKey form, and the WebView still full-height
under the new bottom inset. **The reveal itself has never fired** — that needs
a real PennKey login, so it is proven only by the unit tests and by reading.
Steps 3, 4 and 5 remain unrendered by anyone, so their new bottom dots are
unseen too. Section 3's warning stands unchanged.

One cosmetic thing left deliberately: while Connect is hidden, "cancel" sits
alone on its row with empty space to its right. That space is where the button
arrives, so nothing jumps when it does — but if it reads as an orphan, that row
is the place to rebalance.

## 9. Third pass — Locust branding and the interactive intro

_Appended 2026-09-08. This work is still uncommitted on `onboarding-walk`.
Baseline remains **774 tests / 78 suites** and the iOS simulator build succeeds._

The product is now called **Locust** everywhere user-facing. Internal names
such as the bundle identifiers, target names, `LowHangingFruitKit`, migration
keys, and code symbols were intentionally not renamed; changing those would be
a compatibility/project migration rather than a copy change. The supplied
persimmon/branch logo was converted to a transparent resource at
`LowHangingFruitUI/Resources/locust-logo-transparent.png` and appears on the
first onboarding step.

The intro is now deliberately sparse:

1. The original nine assignments scatter around the first screen; only the
   title remains.
2. Those same views organize into explicit `CLASS → Assignment` rows; only the
   title remains.
3. The chips disappear and four slim feature strips appear together under
   “How Locust keeps you ahead.” Dashboard, Reminders, Ask, and Grades each
   pair a compact label with a miniature of the real UI: a Canvas + Gradescope
   assignment stack, a Locust notification, the assistant's real
   tree/persimmon prompt treatment, and a Grade Watcher card. There are no
   repeated titles or descriptive subheads inside the previews.

There is no fifth Canvas/login feature and no “Preview with sample data” link
on the intro. The only primary action on the last page is **Get started**.

The complete four-strip page was rendered on an iPhone 17 Pro simulator. Debug
launch arguments make repeatable visual checks possible:

```text
-LHFDemoData -LHFOnboardingHarness -LHFIntroPage 2
```

`-LHFOnboardingHarness` also clears the in-memory onboarding/intro gates for
that launch. For a normal installed build, deleting the app from the phone and
installing it again clears those local flags and shows the intro from the
beginning. The physical iPhone was listed as `unavailable` at the end of this
pass, so the new build could not be installed there; simulator visual QA is
complete.

## 10. Final cleanup — direct service sign-in and simpler choices

_Appended 2026-09-09 on `onboarding-walk`. This section supersedes the older
login-action-bar and five-step descriptions above._

The setup walk now begins directly on Penn's Canvas sign-in. The native header
keeps the intro's large serif styling, but the reset-login, calendar-link,
reload, start-over, cancel, instructional copy, and manual Connect controls
have all been removed. Once Canvas returns from Penn SSO to a signed-in Canvas
page, the app saves the session and continues automatically.

Gradescope follows the same stripped-back pattern: a native **Connect
Gradescope** title, **Skip** in the top-right, and the Gradescope login page.
There are no bottom controls. Gradescope authenticates on its own host, so the
navigation observer treats the first committed non-`/login` Gradescope page as
the return destination, saves its cookies, syncs, and advances automatically.
Canvas retains the stricter requirement that its flow must first leave for a
foreign Penn SSO host before a return can count as authenticated.

Reconnect entry points are service-specific. Canvas reconnect buttons open
only Canvas setup, while Gradescope reconnect buttons open only Gradescope
setup; neither replays the complete onboarding walk. A focused DEBUG harness
opens the Gradescope page directly for review:

```text
-LHFGradescopeOnboardingHarness -LHFDemoData
```

The remainder of the walk was reduced to four steps. Notifications is titled
**Pick your notifications** and contains only lead-time choices. The
per-course screen uses short scan states, one reminder toggle, and one
"Items with nothing to submit" toggle with examples. Long evidence,
explanatory, and per-setting copy was removed.

Verification for this pass:

- `CanvasLoginHardeningTests`: 12 tests passed, including the same-host
  Gradescope return case.
- `IntroFlowTests`: 7 tests passed, including service-specific reconnect
  routing.
- Debug build for the iPhone 17 Pro simulator succeeded.
- The focused Gradescope page was rendered in the simulator with its title,
  top-right Skip button, and live Gradescope form visible.
