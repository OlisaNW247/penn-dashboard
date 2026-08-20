# v3 integration handoff — six parallel branches

_Written 2026-08-20. Base for every branch below: `v3` @ `7e708fd`
(tree-identical to `d208a60`). Test baseline at that commit:
**286 tests / 25 suites green** (`cd LowHangingFruitKit && swift test`)._

Six tasks were spun off **simultaneously**, each in its own worktree off the same
base. They cannot see each other. This document is how they get back together.

## ⚠️ Read this first: they were designed to be sequential

The task prompts specified an order and named prerequisites. Running them in
parallel means several are building on a base that lacks their dependencies.
Two consequences, both real:

1. **CloudKit (task 6) had two hard prerequisites that do not exist in its
   base** — the `.unique` removal (task 4) and the completions/history
   migration (task 5). Its own prompt says "DO THIS LAST … verify they are done
   before starting." Expect it to have either duplicated that work or built on
   sand. **Treat its output as a draft to re-derive, not to merge.**
2. **Tasks 3 and 5 overlap semantically, not just textually.** Task 3 moves
   completion + grade-history keys into the App Group `UserDefaults` suite;
   task 5 removes those same keys from `UserDefaults` altogether and moves them
   into SwiftData. A naive merge yields code that writes both places or neither.
   **Task 5 supersedes task 3 for exactly those keys.**

## The six branches

| # | Task | Touches | Risk |
|---|------|---------|------|
| 1 | Verify Dynamic Type at accessibility sizes | `RedesignTokens.swift`, most view files, `LHFWidget/NextDueWidgetViews.swift` | Low — view layer only |
| 2 | Onboarding intro/mission screens | new `IntroView.swift`, `OnboardingView.swift`, `RootView.swift`, `AppState.swift` (`hasSeenIntro`) | Low–Med |
| 3 | `UserDefaults.standard` → App Group suite | `AppState.swift` (52 sites), `GradeWatcherStore.swift`, `NotificationScheduler.swift` | **High** |
| 4 | Remove `@Attribute(.unique)` | `StoredAssignment.swift`, `AssignmentStore.swift` | Med |
| 5 | Completions + grade history → ledger | `AppState.swift`, `GradeWatcherStore.swift`, `StoredAssignment.swift`, `AssignmentStore.swift` | **High** |
| 6 | Enable CloudKit sync | `AssignmentStore.swift`, `StoredAssignment.swift`, `project.yml`, privacy docs | **Highest** |

### Conflict hotspots
- `AppState.swift` — tasks **2, 3, 5** all edit it. Worst file in the repo right now.
- `GradeWatcherStore.swift` — tasks **3, 5**.
- `StoredAssignment.swift` / `AssignmentStore.swift` — tasks **4, 5, 6**.
- `OnboardingView.swift` — tasks **1, 2**.

## Merge order (do not deviate without a reason)

Integrate **one at a time**, onto `v3`, running the full suite after each. Do not
batch. Rebase each branch onto the accumulated result before merging it.

1. **Task 1 — Dynamic Type.** Least entangled with persistence; also the one
   validating an already-shipped change. Merge first so later UI work inherits it.
2. **Task 4 — drop `.unique`.** Small, foundational, persistence-layer.
3. **Task 5 — completions/history → ledger.** The big persistence change. Rebase
   onto 4 first (both touch `StoredAssignment`/`AssignmentStore`).
4. **Task 3 — App Group suite.** Rebase onto 5. **Drop any part of task 3 that
   migrates keys task 5 has already moved into SwiftData** (`completedAssignmentIDs`,
   `completionDates`, `gradeWatcherHistory`). The remaining ~24 keys still need it.
5. **Task 2 — onboarding intro.** Rebase onto 3 so `hasSeenIntro` is written
   through whatever the final `UserDefaults` accessor turned out to be.
6. **Task 6 — CloudKit.** Re-derive against the merged result. Verify every model
   property is optional-or-defaulted and that `.unique` is genuinely gone before
   enabling `cloudKitDatabase:`.

## Testing bar

Per merge step, all of:
- `cd LowHangingFruitKit && swift test` — **must not drop below 286**, and each
  branch should be adding to it. A merge that loses tests has lost work.
- iOS build: `xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- macOS build — the widget's `platformFilter: iOS` in `project.yml` is fragile;
  see the comments there before touching it.

### Migrations are the real risk
Three separate one-time migrations land across tasks 3, 5 and 6. A current user
upgrading from `7e708fd` runs **all of them in sequence, on one launch**.
Explicitly test:
- Fresh install (no prior data) — every migration must no-op safely.
- Upgrade from `7e708fd` with a populated store: completions, class selection,
  grade history, syllabus schemes and manual weights all survive.
- Re-running the migrations (relaunch) must not double-apply or clobber newer values.
- No App Group entitlement (unit tests, previews) — must degrade, never crash.

### Hazards that have already bitten
- **Tests share `UserDefaults.standard`.** Any test toggling selection/completion
  must normalize on the way in *and* out. See `GradeWatcherCourseResolutionTests`.
- **`xcodegen generate`**: Info.plist content must live in `project.yml`'s
  `info.properties` or regeneration deletes it. The widget dependency must use
  `platformFilter: iOS` (case-sensitive) — `platforms:` silently discards it.
- **Keychain cookies must stay device-bound** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  in `SessionCookieStore.swift`). Never sync live SSO session cookies.
- **Don't commit real Canvas/Gradescope data** — user ids, feed-token URLs, cookies.

## Still outstanding, independent of all six
- **Nothing has been tested against real Canvas/Gradescope data.** Every grade
  path is proven against fixtures only. The account is now signed in, so this is
  finally possible — and it is the highest-value verification left.
- `v2.75` carries unmerged macOS sidebar/landscape work (`9e6d8cf`) that exists
  on no other branch. A decision, not a task.
- `v2.5` has the app icon (`eada94a`) + version bumps worth cherry-picking — but
  **not** `b053006`, which gates Grade Watcher off and would defeat `v3`'s purpose.
- Gradescope exam statistics are **email-only** (confirmed against Gradescope's
  own docs); the student web page carries no statistics. A paste-the-email parser
  mirroring `SyllabusTextExtractor` is the viable route if wanted.
