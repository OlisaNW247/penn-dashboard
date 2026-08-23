# v4 — plan

_Branch `v4`, created off `v3` @ `a4fcca6`. Written 2026-08-23._

v4 has two halves. The first is **closing out v3**: three branches of finished,
unmerged work — one of which fixes a live data-corruption bug — plus the docs
that explain, in plain language, what the app now does with your data. The
second is **the profile half**: a real home for "these are my classes, this is
how I want to hear about each one," and the semester rollover that makes the app
survive September.

---

## Root causes I verified before writing this

These change the shape of the work, so they come first.

### The splash video has no sound. It never did.

Both `splash.mp4` and `splash_dark.mp4` are **video-only** — `ffprobe` reports a
single h264 stream, no audio track — and `SplashView.swift:137` already sets
`player.isMuted = true`. There is nothing to remove.

What actually happens: **the app never configures `AVAudioSession`** (confirmed —
the symbol appears nowhere in the codebase). So when `AVPlayer` starts, iOS
activates the shared audio session under its default `.soloAmbient` category,
and `.soloAmbient` means *"stop everyone else's audio."* Spotify gets paused by
the session activation itself, not by any sound the app makes.

The fix is one call, not an asset re-encode: set the category to `.ambient` with
`.mixWithOthers` before playback. Muting more, or stripping an audio track that
isn't there, would do nothing.

### Last semester's notifications: the term cap only looks forward

`AppState.withinTermCap` (`AppState.swift:784`) reads:

```swift
if let term = assignment.term { return term <= current }   // future term → excluded
```

Past terms pass. And the comment two lines up says the quiet part out loud:
*"Undated and overdue items always pass."* Combine that with the v3 ledger, which
deliberately **never deletes** and exempts finished work from aging, and every
Spring 2026 row you ever saw is still live, still on the dashboard, still
feeding `reschedule()`. The ledger did its job; the filter never learned about
semesters ending.

### "Only one class shows up" is the same bug's other half

The class list is derived from whatever the Canvas ICS feed currently contains.
A course that hasn't posted an assignment yet contributes no items, so it
contributes no class. In week one of a semester that's *most* of your courses.
`canvasCourseIDsByCode` already caches resolved course ids so grades keep
working through a quiet week — but nothing does the equivalent for the class
list, and there is no way to add a class by hand.

### Recurring-item detection is already built — it's just not in onboarding

`CanvasRequirementScanner` scans syllabus and announcement HTML and returns
`CanvasRequirementSuggestion`s (readings, check-ins, weekly posts — the
non-assignment obligations). `RecurringTask` turns them into scheduled
occurrences. `AppState.addCanvasSuggestion` accepts them. All of it works and is
tested.

It is reachable from exactly one place: Settings → Tasks. Onboarding never runs
the scan, never shows the suggestions. Item 4.2 is mostly **wiring**, not
building.

### There is no tab bar

The app is one `NavigationStack` with pushed routes (`DashRoute.settings`,
`.grades`, `.report`). A "Profile tab" means introducing a `TabView` — the
largest structural change in v4 and the main reason the UI work has to be
sequential.

---

## Decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | What does v4 build on? | Merge the three open branches into `v4` **first**, as phase 0. One of them fixes on-disk corruption; another carries the Canvas login hardening `v3` still lacks. |
| D2 | Real tab bar, or another pushed page? | **Real `TabView`: Dashboard · Profile · Settings.** The user asked for a tab, and Profile is where per-class setup lives — it needs to be one tap away, not buried behind a gear. |
| D3 | Where do per-course preferences live? | **New `CoursePreferences` type + its own store**, not more keys on `AppState`. This is the de-conflicting move that makes parallel work possible at all. |
| D4 | How does semester rollover trigger? | **Detected and offered, never automatic.** Silently hiding a student's work is the one failure this app cannot have. Show a "New semester?" card; the student confirms. |
| D5 | Does old-semester data get deleted? | **No.** Archived — `isArchived` on the ledger row, excluded from dashboard/notifications, still reachable in Done history. The v3 ledger's whole thesis is that deleting is how you lose things. |

---

## The workstreams

### W0 — Close out v3 _(phase 0, solo, no parallelism)_

Merge in order, full suite after each:

1. **`claude/lhf-submission-freshness`** (1 commit, off the tip). Timestamps when
   submission state was observed. Cleanest merge available.
2. **`claude/lhf-ship-safe-fixes`** (3 commits, off the tip). Contains the
   **partial-refresh bug that writes `canvasSubmitted = false` to disk** for
   every course a refresh didn't cover — turned-in work reappears as owed on the
   next cold launch, permanently. Also the reviewer preview-mode lockout, the
   widget's missing `CA92.1` privacy declaration (automated `ITMS-91053`
   rejection risk), a `splitCourse` whitespace bug that hides whole courses, and
   VoiceOver on the primary tab control.
3. **`origin/claude/lhf-v3-canvas-merge-6msbyo`** (a real fork, ~3,450 / 2,160
   lines). Brings v2.5's Canvas login hardening, ledger schema versioning,
   honest save-failure reporting, manual assignments onto the ledger, and the new
   app icon. It **lacks** v3's uniqueness / migration-chain / SharedDefaults
   work, so this is a genuine merge with conflicts, not a fast-forward.

Also here: CloudKit sync (v3 task 6) never produced a commit. The schema is
CloudKit-*eligible* now — `.unique` is gone, new fields are optional-and-defaulted
— but `cloudKitDatabase:` is set nowhere. Decide in v4 whether to finish it; it
is not required by anything else on this list.

### W1 — Splash audio session _(item 5)_

Set `.ambient` + `.mixWithOthers` before playback, iOS-only (`#if os(iOS)` — the
type doesn't exist on macOS). Touches **`SplashView.swift` and nothing else.**

### W2 — Profile tab + Settings split _(items 4.1, 4.3, 6)_

`TabView` in `RootView`, new `ProfileView`, and Classes moves out of
`SettingsPage` into Profile. Profile owns: the class list, per-class visibility,
per-class notification setup, add-a-class, and the semester card. Settings keeps
account, appearance, reminders-in-general, storage, grades.

### W3 — Per-course notification preferences _(items 4.2, 4.4)_

Today `NotificationScheduler` has one global `leadOffsets` set and one global
digest. W3 adds a per-course layer on top: which lead times, whether recurring
non-assignment items notify, whether the course is muted entirely. Reads through
`CoursePreferences` (D3), so `AppState` barely changes.

### W4 — Semester rollover + add-a-class _(item 4.5)_

Three pieces:
- **Detect** a term boundary (`Term(date:)` vs the terms present in the ledger).
- **Archive**, not delete: `isArchived` on `StoredAssignment`, honored by
  `rebuildDashboardItems` and by `reschedule()`. Fix `withinTermCap` to bound
  the past as well as the future.
- **Add a class by hand**, with manual assignments attachable to it, so a course
  that hasn't posted anything to Canvas yet still exists in the app.

### W5 — Onboarding per-course setup _(item 4.2)_

After the class picker, walk each selected course: run
`CanvasRequirementScanner` against its syllabus and announcements, show what it
found ("weekly reading, Sundays"), let the student accept/edit/skip each, and set
that course's notification preferences. Wiring, mostly — see the root-cause note
above.

### W6 — Documentation _(items 1, 2, 3)_

Three plain-language docs, no jargon, written for you six months from now:
- `docs/v4-changes.md` — what changed and why, in simple terms.
- `docs/persistence-explained.md` — how saving works now, and the recipe for
  adding a new persisted thing.
- `docs/database-explained.md` — what SwiftData is, what one student's database
  physically is, where it lives, what happens on reinstall, and what CloudKit
  would change.

---

## Conflict map — why the phasing looks like this

`v3`'s six-agents-at-once experiment is documented in `docs/v3-integration-handoff.md`.
It produced two branches with zero commits, two that overlapped semantically, and
one built on prerequisites that didn't exist in its base. The lesson isn't "don't
use agents" — it's **partition by file ownership, not by topic.**

| File | Wanted by |
|---|---|
| `AppState.swift` (1,139 lines) | W0, W3, W4, W5 |
| `OnboardingView.swift` (549) | W0, W5 |
| `SettingsPage.swift` (386) | W0, W2 |
| `NotificationScheduler.swift` | W3, W4 |
| `ContentView.swift` / `RootView.swift` | W2 |
| `StoredAssignment.swift` / `AssignmentStore.swift` | W0, W4 |
| `SplashView.swift` | W1 only |
| `docs/**` | W6 only |

`AppState.swift` is the bottleneck again. **Phase 1 exists to remove it.**

---

## Phasing

### Phase 0 — Integration (solo, no agents)
W0. Three merges, full suite between each. Nothing else runs concurrently —
every other workstream's base depends on the outcome.

### Phase 1 — The foundation commit (one agent, alone)
Create `CoursePreferences` (the model) and its store, plus the one `AppState`
seam that exposes it. Small, fully tested, merged before phase 2 begins. This is
what lets W3, W4 and W5 later touch `AppState` **barely, or not at all** —
without it they collide exactly the way v3's tasks 3 and 5 did.

### Phase 2 — Genuinely parallel (three agents, simultaneous)
Disjoint file sets, verified against the table above:

| Agent | Owns | Files it may touch |
|---|---|---|
| **A — splash** | W1 | `SplashView.swift` |
| **B — docs** | W6 | `docs/**` only |
| **C — term logic** | W4, Kit half | `Term.swift`, new `SemesterRollover.swift`, `StoredAssignment.swift`, `AssignmentStore.swift` + tests |

Agent C does **pure logic** — detection, archiving, the corrected term cap — and
touches no view and no `AppState`. Its UI lands in phase 3.

### Phase 3 — Sequential UI (one agent at a time, rebasing each onto the last)
Order matters; each inherits the previous one's structure:

1. **W2 — Profile tab + Settings split.** First, because it creates the container
   everything else renders into.
2. **W4-UI — semester card + add-a-class.** Renders into Profile, driven by agent
   C's logic.
3. **W3 — per-course notification prefs.** Renders into Profile, reads phase 1's
   store.
4. **W5 — onboarding per-course walk.** Last, so it configures preferences whose
   shape is already final.

### Phase 4 — Verification (you, on device, with real data)
See below.

---

## Testing bar

Per merge, all of:
- `cd LowHangingFruitKit && swift test` — **must not drop below the current 328**
  (`@Test` count on `v3`; each workstream should add to it).
- iOS build: `xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- macOS build — `platformFilter: iOS` in `project.yml` is fragile; read the
  comments there before touching it.

Migration-specific, since W4 adds another one on top of v3's three:
- Fresh install — every migration no-ops safely.
- Upgrade from `a4fcca6` with a populated store — completions, class selection,
  grade history, syllabus schemes, manual weights all survive.
- Re-running migrations must not double-apply.
- No App Group entitlement (tests, previews) — degrade, never crash.

---

## What only you can do

1. **Nothing in the grade or submission path has ever been tested against real
   Canvas data.** Every one of those paths is proven against fixtures. The
   account is signed in now; this is the highest-value verification left, and it
   is not something an agent can do.
2. **The semester rollover needs your actual fall data to be worth trusting.**
   It is late August — the boundary is happening right now, on your phone, which
   is the best possible test case and one that won't come around again for
   months.
3. **Decide on CloudKit** (D1's tail) and on the tab bar (D2) before phase 3
   starts — both are load-bearing for everything after them.
