# LHF (Low Hanging Fruit)

A personal academic dashboard for Penn students. Reads the student's own **Canvas**
calendar feed and **Gradescope**, merges them into one chronological "what's due
next" list, tracks grades, and sends local reminders. SwiftUI, iPhone-first, also
builds for macOS from the same source. **Everything is on-device** — no server, no
accounts, no analytics, no third-party SDKs.

Shipped on the App Store as **1.1.2 (build 4)**.

## Commands

```bash
# Tests — the primary gate. Runs on the macOS host.
cd LowHangingFruitKit && swift test

# iOS build
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# macOS build (the package; `swift test` also exercises this)
cd LowHangingFruitKit && swift build
```

This branch is the **merge of `v3.5` and `v4`** (v4's UI, v3.5's engine work —
readings-only courses, iCloud Tier 2 sync, background refresh, the Mac menu-bar
tier, Canvas session renewal). Baseline on this branch, verified post-merge on
a Mac (2026-08-26): **517 tests / 55 suites green** (plus 4 XCTest scheduler
tests), up from 456/40 on pre-merge `v4`. Hold the rule: a change that lowers
the test count has lost work — investigate rather than accept it.

## Layout

| Path | What |
|---|---|
| `LowHangingFruitKit/Sources/LowHangingFruitKit/` | Pure model + parsing + persistence. No SwiftUI. |
| `LowHangingFruitKit/Sources/LowHangingFruitUI/` | Views and `AppState`. Imports the Kit. |
| `App/` | iOS/macOS app target, entitlements, assets |
| `LHFWidget/` | Home/Lock Screen widget extension — a **separate process** |
| `docs/` | Design docs and plain-language explainers |
| `project.yml` | xcodegen source of truth for the Xcode project |

## Architecture

### Three storage tiers — pick deliberately

Documented at length in `docs/persistence-explained.md`. The short version:

1. **SwiftData ledger** (`Persistence/StoredAssignment.swift`, `AssignmentStore.swift`)
   — the student's own record of work: assignments, completions, grade
   observations, manual work. Loss here is unrecoverable, so this tier never
   deletes.
2. **App Group `UserDefaults`** (`Persistence/SharedDefaults.swift`, reached as
   `UserDefaults.lhf`) — preferences: cheap to re-enter, meaningless off-device.
   Per-course settings live here in `CoursePreferences`.
3. **Keychain** (`SessionCookieStore.swift`) — session cookies and the Canvas feed
   URL (it embeds a per-user token, so it is a bearer credential). Device-bound
   via `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. **Never sync these.**

### The ledger is the point

The app used to hold assignments in memory and do `canvasItems = fetched` — a
wholesale replace — so a rolling Canvas feed or one flaky fetch erased work the
student had already seen and completed. `reconcile()` now *edits*: it upserts,
flags vanished items `isGoneFromFeed` rather than deleting, and refuses a
suspiciously empty fetch. Aging is deliberate (gone **and** 14 days overdue;
undated, still-in-feed, and finished items never age out).

When touching this, assume the invariant is "**nothing the student did is ever
lost**" and work backwards from there.

### Course identity

The Canvas course code (`"PHYS 151"`) is the key that selection, reminders,
grades, dedup and `CoursePreferences` all use. `CourseCode.parse` derives it from
Canvas's descriptor (`PSYC 1010-005 202430 Intro to Psych`). A failed parse falls
back to the raw descriptor, which is both an ugly label *and* a key nothing else
agrees with — so parsing bugs are identity bugs, not cosmetic ones. Renaming a
course is deliberately cosmetic only.

## Traps that have already bitten

- **`xcodegen generate` deletes Info.plist content** unless it lives in
  `project.yml`'s `info.properties`. The widget dependency must be
  `platformFilter: iOS` — case-sensitive; `platforms:` is silently discarded.
  Don't regenerate unless a build actually demands it.
- **Tests share `UserDefaults.standard`.** Any test touching selection or
  completion must normalize on the way in *and* out, or it fails the *next*
  suite. Use a scratch suite (`UserDefaults(suiteName:)` + `removePersistentDomain`).
- **`UserDefaults(suiteName:)` succeeds for any string**, entitlement or not. The
  real test for a usable App Group is asking `FileManager` for the container.
- **Without the App Group entitlement the ledger degrades to memory** and the app
  looks completely normal until a relaunch loses everything. Settings → Storage
  exists to surface this.
- **`AVAudioSession` is never configured by default**, and `AVPlayer` then
  activates it as `.soloAmbient`, which stops the user's music. `SplashView` sets
  `.ambient` + `.mixWithOthers`. The splash clips have **no audio track** — if
  this resurfaces, muting is not the fix.
- **Regex patterns needing real Unicode characters must not be raw strings.**
  `#"...\u{2013}..."#` passes the escape through literally, the pattern fails to
  compile, and `try?` turns that into a silent wrong answer.
- **`swift test` compiles the macOS slice.** iOS-only API (`PageTabViewStyle`,
  WidgetKit, `AVAudioSession`) must sit behind `#if os(iOS)` / `canImport` or it
  breaks the test build.
- **An unsandboxed macOS test run resolves the App Group container WITHOUT the
  entitlement** (learned 2026-08-24) — `swift test` on a dev Mac would reach the
  real Mac app's ledger, shared defaults, and widget snapshot.
  `SharedDefaults.isTestRunner` guards all three choke points. Never remove
  those guards.
- **Preferences go through `UserDefaults.lhf`**, never `UserDefaults.standard`.
  Tests must save and restore through the same accessor or they are not reading
  what `AppState` writes.
- **Credentials never go in defaults.** Session cookies live in the Keychain
  (`SessionCookieStore`); so does the Canvas feed URL (`ICSFeedURLStore`),
  because `…/feeds/calendars/user_<token>.ics` is a bearer credential. This is
  why `canvasICSURL` is absent from `SharedDefaults.legacyKeys`.
- **Never commit real Canvas/Gradescope data** — user ids, feed-token URLs, cookies.

## Conventions

- **Comments explain *why*, at length, in prose.** Read `StoredAssignment.swift`,
  `SharedDefaults.swift` or `CourseCode.swift` for the register. Thin comments
  that restate the code are worse than none. When a fix is non-obvious, record
  what the *wrong* fix would have been.
- **Commits**: short imperative subject, then prose paragraphs explaining the
  reasoning and what was rejected. End with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Tests are `swift-testing` (`@Test` / `@Suite`), not XCTest.

## Branches

| Branch | What |
|---|---|
| `main` | Old — 1.0.0 App Store prep. Not the ship line. |
| `origin/v2.5` | The **shipped** line, 1.1.1 build 3. Grade Watcher gated off. |
| `v3` | Grade Watcher un-gated, grade report, syllabus, the SwiftData ledger |
| `v3.5` | v3 plus readings-only courses, iCloud Tier 2, background refresh, Mac tier, session renewal |
| `v4` | v3 plus integration + Profile tab, per-course reminders, semester rollover |
| this branch | **v3.5 + v4 merged** — v4's UI over v3.5's engine |
| `v2.75` | Unmerged macOS sidebar/landscape work that exists nowhere else |

## Known gaps

- **Nothing has ever been tested against real Canvas or Gradescope data.** Every
  grade, submission and syllabus path is proven against fixtures only. This is the
  highest-value verification outstanding.
- **The `LedgerSchemaV1` migration has never opened a real pre-existing on-disk
  store.** v4 runs four migrations in one launch; the failure mode is a silent
  fallback to an empty ledger.
- **CloudKit sync is opt-in and default-off** (Settings → "icloud sync",
  docs/LAPTOP_INTEGRATION_PLAN.md Tier 2). The schema is CloudKit-eligible —
  every property on `StoredAssignment` carries a default — and every store
  pins `cloudKitDatabase: .none` unless the toggle was on at launch. The
  sync path has had little real-device soak time; treat it as Phase A.
- The onboarding per-course walk is covered by tests but has never been walked on
  a device (it needs a real Canvas session; preview mode skips onboarding).

## Overseer / doer split

You are acting as the overseer on this project, not the implementer.
Your job is to plan, delegate, and review — not to write code yourself.

### Division of labor
- All non-trivial file writes, edits, and command execution go through the
  `implementer` subagent. Trivial one-line fixes you spot while reviewing are
  fine to make yourself, but default to delegating.
- Use the `verifier` subagent for an independent check on anything
  security-sensitive, architecturally significant, or where you want a second
  opinion beyond your own review.
- You do the planning, task breakdown, delegation-brief writing,
  acceptance-criteria review, and integration decisions yourself.

### Before delegating
Break the request into the smallest tasks that can each be verified
independently. For each one, write a delegation brief that stands alone — the
subagent sees NONE of your conversation. Every brief must include:
1. The specific goal and exact scope (what NOT to touch, too).
2. Relevant file paths, current state, and any conventions to follow.
3. Concrete acceptance criteria — how you'll know it's done correctly.
4. What to report back (files changed, how it was verified, open questions).

### After a subagent reports back
Don't accept on trust. Before integrating:
1. Check the result against the acceptance criteria you gave it.
2. Spot-check the actual diff, not just the subagent's summary.
3. If it's wrong or incomplete, send a specific corrective follow-up to the
   same subagent rather than redoing the work yourself.
4. After two failed revision rounds on the same task, stop delegating it and
   say what's going wrong — don't keep looping silently.

### Working style
- Keep a running task list so the state of play is visible.
- Give short status updates between steps, not a transcript of every subagent
  exchange.
- If a task is ambiguous at the planning stage, ask before writing the
  delegation brief — don't pass ambiguity down and hope it guesses right.
- Flag anything security-sensitive, destructive, or architecture-changing for
  explicit sign-off before delegating it.

### The one rule that matters most here
**A change that has not been compiled is not done.** Say so plainly rather
than implying otherwise — from a subagent's report, or your own. Both of this
project's worst days came from resolved-but-uncompiled Swift being pushed.
