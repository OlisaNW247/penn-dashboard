# LHF (Low Hanging Fruit)

A personal academic dashboard for Penn students. Reads the student's own **Canvas**
calendar feed and **Gradescope**, merges them into one chronological "what's due
next" list, tracks grades, and sends local reminders. SwiftUI, iPhone-first, also
builds for macOS from the same source. **The student's own data is on-device by
default** — grades, completions, submission state, the work list, the student's
name, and Canvas/Gradescope cookies never leave the phone. There is no analytics,
tracking, or third-party SDK. Since 2026-09-09 the product's user-facing name is
**Locust** (display names and copy only; bundle ids, module names, app-group
names and defaults keys keep their LHF names), and on launch the app fetches a
public update-policy file (`update-manifest` branch) that can require an
update — identifier-free, fail-open, see `Update/`.

That said, the app is no longer backendless. LHF runs a small Supabase project
(Postgres + Edge Functions; see `backend/PROTOCOL.md`) that every install talks
to via an anonymous account created on first launch — no email, no password, no
name. Two things go through it: course materials (syllabus, course pages,
modules, assignment descriptions, announcements) fetched from Canvas with the
student's own login are uploaded and pooled per Canvas course, so classmates
share one copy and a new student gets the course instantly (sync is automatic —
after Canvas connect, then on the existing refresh loop, hourly staleness; no
manual sync, no user-entered API key); and questions to **ask** (the screen
itself is titled **"the tree"**) are sent to the backend with the on-device
context document and matched excerpts, answered by an AI model via OpenRouter
under LHF's own key (default `z-ai/glm-5.3-flash`, with OpenRouter's
data-collection-deny flag), with the Announcement Watcher's "AI assist"
toggle (on by default since 2026-09-08; a student can turn it off in
Settings) routed the same way, and only for announcements a cheap on-device
gate judges could carry a task. Neither questions nor answers are stored — only
per-user daily request counts and token totals. Settings has a button to delete
a student's enrollment/usage rows and anonymous account from the backend.
Offline, over quota, or with the backend unreachable, ask answers on-device as
before: `OnDeviceAssistantResponder` computes exact answers from the dashboard's
items, retrieves policy and content answers from the course materials the app
syncs (`CourseKnowledgeCollector` → `CourseKnowledgeStore`), and on iOS 26 /
macOS 26 Apple Intelligence devices rephrases via Apple's on-device model
(`OnDeviceLanguageModel`). Say it this way — "the student's own data stays
on-device; course material is pooled server-side; ask has an on-device
fallback" — rather than flatly "everything is on-device" (stopped being true on
`assistant-ui`) or "no server" (stopped being true adding the backend).

Live on the App Store: **1.2.1** (App Store id `6783911002`, released
2026-09-04 — Marco confirmed against Apple's public lookup; this line has
been stale before, re-check rather than trust it). **2.0.1 (build 6)** was
uploaded from `v3.5`; `v5` carries it, now with the backend, the Locust
onboarding and the update gate on top.

## Commands

```bash
# Tests — the primary gate. Runs on the macOS host.
cd LowHangingFruitKit && swift test

# iOS build
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# macOS build (the package; `swift test` also exercises this)
cd LowHangingFruitKit && swift build

# Backend — Deno/Supabase Edge Functions, a separate toolchain from the above
cd backend && deno task test
cd backend && deno task check
```

`-LHFDemoData` (DEBUG only) seeds the bundled sample courses so the app is
usable without a real Canvas session, and pairs with `-LHFShowSettings`,
`-LHFShowGrades`, `-LHFShowReport` or `-LHFShowAssistant` to land directly on a
screen instead of tapping through to it on every rebuild:

```bash
xcrun simctl launch booted com.lhf.lowhangingfruit -LHFDemoData -LHFShowAssistant
```

Baseline on `v5`, verified on a Mac (2026-09-12): **1230 tests / 121 suites
green** (plus 4 XCTest scheduler tests), after "decided" became a syllabus
prediction (`GradeCountPredictor`, docs/grades.md §16: every category gets
a count with a source, attendance is decided by time elapsed, the
"semester share unknown" caveat is gone) and the grade card and report
were cut down to numbers and tables (three tap levels; a copy-budget
test holds the text helpers to six words). 2,400 blind lines from two
concurrent agents that compiled first time; the five first-run failures
were stale test premises and a due-exactly-now fixture race with the
first-launch hold. Before that, 1193/119 on
2026-09-11 after the app learned to ask the
deployed `map-categories` function for a suggested category mapping and
offer it in the categories editor as "use it / not now" (docs/grades.md
§15.8; 1,500 blind lines, compiled first time). Before that, 1170/117 on
2026-09-10 after Grade Watcher round 3
(docs/grades.md §15: the category map -- every course's Canvas groups and
items are regrouped into syllabus categories by `GradeCategoryMap` /
`GradeRegrouper`, attendance items and zero-point placeholders are
classified out by `GradeItemClassifier`, the student edits the map in
`GradeCategoryMapEditor`, and the deployed `map-categories` function can
propose one; Deno 308). Round 3 was 3,400 blind lines and needed four
fix commits to go green: two memberwise-init/argument-order compile
errors, a main-actor trap in a View static called from a test (trap
below), and one real logic bug plus one test-pollution bug (trap below)
that the first full run exposed together. Before that, 1104/109 the same
day after Grade Watcher round 2 (the
server's syllabus extraction and the registrar's components reach Grade
Watcher: suggested schemes, automatic exclusion of a zero-credit or
pass/fail site via `GradeSiteExclusion`, syllabus reuse from the synced
materials; Deno 278). Before that, 1068/105 after Grade Watcher round 1
(docs/grades.md §14: semester-aware "decided", per-item/category/course
overrides with provenance, the "how this is calculated" panel, site labels;
1,400 blind lines that compiled first time). Before that, 1032/101 the same
day after the first-launch hold
(`AppState.isCanvasSubmissionVerified` — overdue Canvas work in a course
never yet checked against Canvas waits in `awaitingCanvasCheck` behind a
"checking canvas" notice instead of reading as owed), Grade Watcher fetching
three courses at a time, and the "from announcements" card caveat. That sat
on the 1020/98 mark of 2026-09-09, after merging Marco's `onboarding-walk`
(the Locust intro and walk, the update gate and its 33 tests) onto the
976/95 mark of earlier that day. That 976/95 was up from
937/92 the day before, after
the Canvas assignment id learned to come from the ICS URL fragment (see the
trap below — this is what made a section-override assignment show once and
read as submitted on a real phone, the first real-device fix of a submission
bug), module-imported rows learned their id too, and three collapses now
fold the same assignment's listings into one dashboard item
(`AssignmentDeduplicator.collapseCanvasOverrides`, `.collapseCanvasDuplicates`,
and the Gradescope pairing; title fallback in `SubmissionMatcher`).
The 937 mark covered the course-websites layer, the Announcement Watcher
rewrite, and multi-site course identity (a code can now be several Canvas
sites; each site's documents are labelled by the registrar's activity for its
section). All of it was written without a compiler; the one first-run compile
error so far was a raw string closed early by a `"#` inside `href="#"`
(double the delimiter). The backend
is deployed to the live Supabase project with all six functions; the live
path is still exercised only by hand on a device, never by `swift test`
(`BackendServices.client` is nil under tests).

Earlier on `v5`: 853/90 (2026-09-07, registrar catalog + component
tagging); 838/89 (2026-09-07, the backend change); 804/87 (2026-09-06, the
merge of `v3.5` and the ask knowledge engine).

Earlier: `assistant-ui`, verified on a Mac (2026-09-02), **736 tests / 76
suites green** (plus 4 XCTest scheduler tests), up from 693/70 on `v6` — itself
verified on a Mac the same day, closing out v6's uncompiled Announcement Watcher
work; `assistant-ui` later reached **769/78** on 2026-09-07 after the update
gate added 33 tests and 2 suites. Earlier marks for reference: 608/61 on the
v3.5+v4 merge, 517/55 on final
`v3.5`, 456/40 on pre-merge `v4`. Hold the rule: a change that lowers the test
count has lost work — investigate rather than accept it.

One known flake, pre-existing and untouched: `CourseContentDashboardTests`
("flipping a content decision never changes `canvasCourseIDsByCode`…") races
another suite over shared `UserDefaults` and fails perhaps one run in four. It
passes in isolation. See the shared-`UserDefaults` trap below — the fix belongs
in the polluting suite, not in the assertion.

## Layout

| Path | What |
|---|---|
| `LowHangingFruitKit/Sources/LowHangingFruitKit/` | Pure model + parsing + persistence. No SwiftUI. |
| `LowHangingFruitKit/Sources/LowHangingFruitUI/` | Views and `AppState`. Imports the Kit. |
| `…/LowHangingFruitUI/Resources/` | Bundled media. Load via `bundledImage(_:ext:)` (`Bundle.module`) — a bare `Image("name")` resolves against the *main* bundle and silently renders nothing. |
| `App/` | iOS/macOS app target, entitlements, assets |
| `LHFWidget/` | Home/Lock Screen widget extension — a **separate process** |
| `backend/` | The Supabase project: SQL migrations, Edge Functions, `PROTOCOL.md` (the contract the app and server are both written against) |
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

### Update gate

`LowHangingFruitKit/Sources/LowHangingFruitKit/Update/` (`AppVersion`,
`UpdatePolicy`, `UpdateManifestClient`, `UpdatePolicyCache`) and the
`LowHangingFruitUI` trio `UpdateGate.swift` / `UpdateRequiredView.swift` /
`UpdateAvailableBanner.swift` are a forced-update version gate: on launch and
foreground it fetches one small public static manifest and can show an
undismissable wall below `minimumVersion` or a dismissible banner below
`latestVersion`. The contract is **fail open** — any fetch failure, unset
manifest URL, or unparseable version leaves the last-known verdict untouched
rather than inventing a block, because a broken version check must never be
the thing that locks a student out of their own ledger.

**It is live.** The manifest is the `update-manifest` orphan branch of this
repo, served at
`raw.githubusercontent.com/OlisaNW247/penn-dashboard/update-manifest/lhf-update.json`.
An orphan branch because a shipped build has that URL compiled into it and can
never be told a new one, so the path must not move when feature branches merge;
and because GitHub's web UI can edit it from a phone, which is the only way to
lift a bad block.

`minimumVersion` and `latestVersion` are kept **equal** — every release is
mandatory, so `UpdateAvailableBanner` never fires in practice. Bump both on each
release, but **only once the new build is actually downloadable**. A floor above
what the App Store will serve is the one unrecoverable mistake here: the wall's
button leads to a version that still fails the check, and everyone is stuck. The
30-day ceiling in `UpdatePolicyCache` only rescues people who are offline.

Two things that surprise people. The gate cannot reach builds that shipped
without it — 1.2.1 and earlier never fetch the manifest, so no floor retires
them; only a future release can. And local builds are `2.0.0`, above any floor
that is safe to publish, so the wall never appears in normal development: to see
it, build with `MARKETING_VERSION=1.0.0` (that is how the live path was verified
end to end) or pass `-LHFForceUpdateWall`.

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
- **`Path.addLines` moves, it does not connect.** Building a filled outline as
  `addLines(leftEdge)` then `addLines(rightEdge.reversed())` produces two
  separate open polylines, not one closed region, because the second call does
  a `move(to:)` to its first point. Filling that yields two zero-area slivers.
  The shape still *draws* — as a pair of hairlines with the page showing
  between them, which reads as a pale object with dark edges rather than as
  nothing — so it survives code review and previews and is only obvious on a
  device screenshot. Walk the second edge with explicit `addLine(to:)`
  (`BranchBackdrop.taperedPath`).
- **A prompt-cache prefix must be byte-stable or it is not a cache.** Anthropic
  caching is a *prefix match*: one changed byte anywhere invalidates everything
  after it, silently, with no error and no symptom except the bill. So
  `AssistantContextDocument` never reads a clock, never emits a relative date
  ("in 3 days"), sorts every collection, and pins its formatters to
  `en_US_POSIX`/UTC. The wrong fix — and it looks completely reasonable — is
  "put today's date at the top of the document so the model knows what day it
  is": that changes the prefix every day, and with a timestamp, every request.
  The current date belongs in the user message, after the `cache_control`
  breakpoint. Verify with `usage.cache_read_input_tokens`; a persistent zero
  means something upstream is varying.
- **Knocking a flat background out of artwork is a flood fill, not a colour
  key.** `Resources/persimmon.png` is the app logo with its cream plate
  removed, and the obvious approach — make every cream pixel transparent —
  destroys it: the seams *between* the calyx lobes are the same cream as the
  plate, so keying on colour punches holes straight through the calyx and the
  lobes lose the separation that makes them legible at 26pt. Fill from the
  image border instead, so only cream reachable from the edge goes. The same
  logic catches a subtler case — an *excluded* shape's enclosed detail (a
  leaf's cream vein) is equally unreachable from the border, so it survives as
  a stray mark floating where its leaf used to be, and has to be culled by
  asking which shape encloses it. There is no PIL, ImageMagick or numpy on the
  dev Mac; `sips` resizes and converts but does none of this. A short
  CoreGraphics script run with `swift file.swift` is the tool.
- **The Canvas assignment id is in the ICS event's URL *fragment*.** Canvas's
  `to_ics` (`app/models/calendar_event.rb`) writes every assignment event's
  URL as `/calendar?include_contexts=course_<id>&month=…&year=…#assignment_<id>`
  — never `/assignments/<id>` — and its section-override branch rewrites the
  UID to `event-assignment-override-<overrideID>` and the summary to
  `"<title> (<section>) [<code>]"` while leaving that URL alone (its own
  source says `# TODO: event.url`). So the fragment is the only id an
  override row carries, and the number in an override UID is an *override*
  id, a different id space: join on it and the wrong work reads as done.
  `Assignment.canvasAssignmentID` reads the fragment; the diagnostics
  report's `via=fragment` is the proof it worked. Confirmed on a real phone
  2026-09-09 after every PHYS 0151 lab row showed `via=none`.
- **`PersimmonMark`'s `size:` argument does not constrain it.** Its body is a
  `GeometryReader` that ends in `.frame(maxWidth: .infinity, maxHeight:
  .infinity)`, so the view expands to fill whatever space its parent hands
  it; `size:` only sizes the image drawn *inside* that already-expanded
  frame. Passing `size: 64` into an unconstrained `VStack` slot renders a
  full-screen persimmon, not a 64pt one — a caller must also apply an
  explicit `.frame(width:height:)`, exactly as the file's own `#Preview`
  does. The wrong fix would have been either hunting for a magic `size:`
  value that happens to look right in one place, or editing `PersimmonMark`
  to drop the `GeometryReader`/fill-to-frame behavior — every existing
  caller relies on that behavior and already pairs it with its own explicit
  frame. This is invisible in code review and in Xcode previews, where the
  surrounding layout happens to be bounded anyway, and only showed up on a
  device screenshot.
- **An unsized `Color.clear` expands to fill, and `minHeight:` is a floor, not a
  ceiling.** `OnboardingView.skipButton` returned a bare `Color.clear` for steps
  with no skip action, and `topBar` wrapped it in
  `.frame(minWidth: 44, minHeight: 32)`. `Color.clear` has no intrinsic size, so
  it took every point of height on offer, inflated the top bar, centred the back
  chevron a third of the way down the screen and pushed everything below it with
  it. The symptom pointed elsewhere entirely — the Canvas WebView rendered as a
  thin band under a screenful of empty background, which reads as "the login
  pane isn't filling" — so three separate fixes went looking for missing height
  inside the panes (`.frame(maxHeight: .infinity)` on the pane, a
  `safeAreaInset` restructure of the chrome, a fill on `OnboardingView.body`)
  and none of them touched the cause. The height was never missing; an invisible
  view was eating it. Size the placeholder at the source
  (`Color.clear.frame(width: 44, height: 32)`). Two tells worth remembering:
  `backButton` was never affected because it uses fixed `width:height:`, so the
  asymmetry between the two ends of one bar was the clue; and temporary
  `.border(Color.red)` on three views found this in one build cycle after three
  cycles of reasoning had not. When a layout bug survives two fixes, stop
  reasoning and draw the frames.
- **Never commit real Canvas/Gradescope data** — user ids, feed-token URLs, cookies.
- **A `static func` on a SwiftUI `View` is main-actor isolated, and Swift 6
  enforces it at run time.** `GradeCourseCardView.decidedText` is a pure
  string rule that tests call directly; the `{ $0.lowercased() }` closure
  inside its `map` inherited the View's isolation and, on swift-testing's
  executor, died in `_dispatch_assert_queue_fail` -- `swift test` exits
  with "signal code 5" and no "Fatal error" line, and the crash report's
  main thread shows only an idle run loop (read the `triggered` thread from
  the `.ips`). Three earlier tests in the same suite passed because they
  returned before the closure was formed. Mark such helpers `nonisolated`;
  do not mark the test suite `@MainActor`, which hides the trap and leaves
  the next background caller (a widget, a notification body) to find it.
- **Seeding a persisted flag through `UserDefaults.lhf` in a test is not
  hermetic even with backup-and-restore.** `FirstLaunchHoldDashboardTests`
  wrote `canvasSessionConfirmedDeadV1 = true` for the duration of each test
  and restored it after; that looked like the sanctioned pattern. But every
  `AppState.init` in every concurrently running suite that landed inside
  that window read a dead Canvas session, engaged the first-launch hold,
  and hid its own overdue fixtures -- ten assertions in four unrelated
  suites (dedup, Done tab, ledger scenarios, cookie store) failed at once
  with no grade code in their stacks, after two green runs of pure
  scheduling luck. The tell was the timing: every failure at 1.3-1.8s, the
  window that suite ran in. A flag another suite's `init` reads needs a
  per-instance seam (`forceCanvasSessionConfirmedDeadForTesting()`), not a
  shared-domain write. Restore-on-exit protects the *next* suite, never the
  ones running *alongside*.
- **A jsonb column outlives the TypeScript type that wrote it.**
  `catalog_courses.components` rows written on 2026-09-07 had no
  `meetings`; the next day's code iterated `component.meetings`, the stored
  rows were read back untouched, and every manifest naming that course
  returned 500 for a day — silently, from the app's side, because the
  upload is gated on the manifest and the only symptom was
  `last_full_sync_at` never filling. Normalize jsonb at the read boundary
  (`dbRowToCatalogRow`), let a legacy row force a refetch
  (`catalogNeedsFetch`), and never let an enrichment step fail the exchange
  it decorates (`handleManifest` catches the catalog step). Deno tests
  cannot catch this: they only ever see rows the current code wrote.
- **Nothing under `backend/` can be exercised from `swift test`**; run its deno
  tests separately (`cd backend && deno task test`, `deno task check`).
  `BackendServices.client` is nil under tests and in an unconfigured build, so
  the app is fully on-device there — a green test run proves nothing about the
  backend path.

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
| `origin/v2.5` | Former ship line, 1.1.1 build 3. Grade Watcher gated off. |
| `v3` | Grade Watcher un-gated, grade report, syllabus, the SwiftData ledger |
| `v3.5` | v3 plus readings-only courses, iCloud Tier 2, background refresh, Mac tier, session renewal. Carries the **uploaded** 2.0.1 build 6 (and the shipped 2.0.0 build 5 before it). |
| `v4` | v3 plus integration + Profile tab, per-course reminders, semester rollover |
| `claude/v4-github-repo-kvu0e0` | **v3.5 + v4 merged** — v4's UI over v3.5's engine. 2.0.0 build 5. |
| `v6` | 2.0.0 head plus Grade Watcher back on, the Announcement Watcher, and the Mac build lane. 693/70. |
| `assistant-ui` | v6 plus **ask** — the class-context chat, its Claude backend, and "the tree" screen it lives on. 736/76. Marco's UI work; folded into `v5`. Later also carries the update gate (769/78). |
| `onboarding-walk` | Marco's Locust rename, three-page intro, five-step onboarding walk, and the update gate turned on. Merged into `v5` 2026-09-09. |
| `update-gate` | The update gate alone, independently mergeable. |
| `update-manifest` | **Orphan branch, never merge.** Holds `lhf-update.json`, the live update policy the shipped app fetches from raw.githubusercontent.com; edit it from GitHub's web UI to lift or set a version floor. |
| `v5` | **Current line** (rebuilt 2026-09-06). `assistant-ui` + `v3.5` (2.0.1 build 6) + the ask knowledge engine: on-device course materials, the no-key responder, retrieved excerpts for the Claude backend; now also carries the Supabase backend (`backend/`) — anonymous accounts, pooled course-material sync, and ask's OpenRouter-backed server path, with the on-device responder as fallback, plus Marco's Locust intro/onboarding walk and the update gate (merged 2026-09-09 from `onboarding-walk`). New work goes here. |
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

### Model tiers and token economy
The overseer runs on the session's top model (Fable); doers are pinned
cheaper in `.claude/agents/` frontmatter — `implementer`/`verifier` on
Sonnet, `mechanic` on Haiku. For built-in agents, pass the tier per call:
`model: "haiku"` for `Explore`/searches/surveys, `model: "sonnet"` for
anything with judgment in it. The top model never does bulk reading or
mechanical edits, and doers never make architecture calls.

Token discipline runs both directions:
- Briefs name files by `path:line`; never paste bodies the doer can read.
- Doer reports are a diff, verification results, and open questions —
  no narration, no restating the brief.
- The overseer reads targeted line ranges, not whole files, and sends
  independent agents in one batch.
- Delegation has overhead (~a few k tokens per spawn): a change smaller
  than its own brief is cheaper done directly — that, not laziness, is
  what the "trivial fixes yourself" allowance above is for.

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
