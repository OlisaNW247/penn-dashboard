# Low Hanging Fruit — Handoff

_Last updated: 2026-08-26 (branch `claude/v4-github-repo-kvu0e0` — the v3.5 + v4 merge)_

## ⚠️ Current state: v3.5 and v4 merged (2026-08-26)

This branch merges **`v3.5`** (engine: readings-only courses, iCloud Tier 2
sync, background refresh, the Mac menu-bar tier, silent Canvas session
renewal, the Stale Request login fix, turned-in notifications) into **`v4`**
(product: swipe-to-complete card, lowercase chrome, per-course reminders,
semester rollover, onboarding course setup, `CoursePreferencesStore`).
Resolution policy: **v4 wins on UI, v3.5 wins on functionality.** Version
bumped to **2.0.0 (build 5)**. The load-bearing reconciliations:

- **Per-course state**: `CoursePreferencesStore` (v4) is the single canonical
  record. v3.5's iCloud mirroring now syncs the store's blob itself
  (`CloudPrefsMirror.mirroredKeys` includes `CoursePreferencesStore
  .storageKey`); pushes ride the store's new `didChange` hook, pulls land via
  `reloadFromDefaults()`. v3.5's `CourseContentDecisions` (readings opt-ins)
  stays as its own store alongside — folding it into `CoursePreferences` is
  a candidate follow-up, not done here.
- **Ledger**: union of v4's freshness/archive fields and v3.5's
  CloudKit-ready all-defaults constraints; still schema V1.
- **Notifications**: v4's per-class scheduling with v3.5's redesigned content
  (title = class name, body = lead phrase, no emoji). `LeadOffset.headline`
  for `.h24` is now "Due in 24 hours".
- **Course-name migration**: v3.5's launch-time normalization now re-keys the
  `coursePreferences` blob (`normalizeCourseKeys`) instead of the four legacy
  maps.
- **Grade Watcher stays hidden** (`FeatureFlags.gradeWatcher = false`, owner's
  call 2026-08-26) but all v3.5 session plumbing is merged and live for
  submission detection.
- **Settings vs Profile**: class management lives in the Profile surface
  (v4); readings-course toggles, iCloud sync, Mac login item, storage and
  troubleshooting live in Settings, restyled to v4's lowercase chrome.

**Verified on this branch, on a Mac (2026-08-26):** `swift test` — **608
tests / 61 suites green** (plus 4 XCTest scheduler tests), zero failures.
Getting there took five post-merge fixes the compiler and test run surfaced
(worth knowing about, all in this branch's log): `loadStringMap` re-added
after v4's consolidation deleted it out from under a v3.5 call site; a
`nonisolated` on `CoursePreferencesStore.storageKey` for the mirror's
static key list; the `.canvasModules` case in `RecurringTask.isOccurrence`;
the widget's rename-override mapping restored (and its nine-link filter
chain rewritten as a loop for the Swift 6 type-checker); and two v3.5-era
test helpers re-seeded through `CoursePreferencesStore` instead of the
legacy UserDefaults keys, which are a write-only projection now.

**Not yet done on this branch** — in order:
1. `xcodegen generate` at the repo root (quit Xcode first — the committed
   pbxproj was regenerated on `v3.5` and still carries 1.1.2/4; this branch's
   project.yml says 2.0.0/5). Commit the result **from this branch** —
   check `git branch --show-current` first.
2. iOS build: `xcodebuild -project LowHangingFruit.xcodeproj -scheme
   LowHangingFruit -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device pass: onboarding walk, swipe card, readings-only classes showing
   by default (the opt-in nudge now fires only for silent courses needing a
   module import — see AppState.includesAsOptedInContent), Mac menu-bar
   build, and — only with two devices — the iCloud sync toggle.

Everything below this section is historical context from earlier sessions.

---

_Previous update: 2026-08-20 (branch `claude/lhf-v3-canvas-merge-6msbyo`)_

**LHF (Low Hanging Fruit)** is a personal academic dashboard for Penn students.
It reads the student's own **Canvas** calendar feed (plus **Gradescope**, and
Canvas **grades**) and shows assignments as one chronological "what's due next"
list, with local reminders. SwiftUI, iPhone-first (+ macOS from the same code),
everything on-device.

---

## ⚠️ Read this first

Work is on **`claude/lhf-v3-canvas-merge-6msbyo`** — `v3` (Marco's SwiftData
ledger, grade report, projections, syllabus ingestion, intro flow) with the
**v2.5 Canvas login hardening merged in**, plus a hardening pass on the ledger
itself.

- `cd LowHangingFruitKit && swift test` → **365 tests / 34 suites passing.**
- **`v3` does not have the Canvas login hardening.** The hardening lives on
  `v2.5` and on this branch.
- **This is no longer a fast-forward.** `v3` moved while the branch was in
  flight: PR #5 (`claude/bold-tesla-2142f1`) landed an independent
  implementation of shared preferences and completion-on-the-ledger — the same
  two gaps this branch had already closed. That has been merged here, resolved
  toward `v3` in the overlapping areas because its versions carry
  `MigrationChainTests`, `SharedDefaultsMigrationTests` and the
  `@Attribute(.unique)` removal. `v3` is now fully contained in this branch, so
  `git merge --ff-only` works from `v3`'s side.
- **Coordinate with Marco before landing it.** His `28891ca`
  (`docs/v3-integration-handoff.md`) sequences six parallel branches into `v3`,
  and 30+ commits arriving out of that order is what the document exists to
  prevent. PR #5 is evidence the collision is real, not hypothetical.

**Not yet verified on hardware.** `swift test` runs without an App Group
entitlement, so `AssignmentStore.makeDefault()` and `UserDefaults.lhf` both
take their non-entitled fallback paths. Three things are therefore **untested by
the suite** and need a device build:

1. the manual-assignment migration, which *deletes* the `manualAssignments`
   UserDefaults blob after copying it to the ledger,
2. `SharedDefaultsMigration`'s one-time copy from `.standard` into the suite,
3. the widget reading hidden/renamed/deleted courses out of that suite.

Check Settings → Storage after upgrading an existing install: it should say
**"Saved on this device."**

## 🆕 What changed in this session (2026-08-21)

**The v3 merge is done and green — 365 tests, 34 suites.**

`v3` had moved: PR #5 shipped a second, independent implementation of the same
shared-preferences and completion-on-the-ledger work this branch had. Neither
line contained any of the other's unique work, so it was merged rather than
resolved by picking a side — `v3`'s versions won the overlap (better migration
test coverage, plus the `@Attribute(.unique)` removal), and this branch's
unique work was re-applied on top: the Canvas login hardening, `LedgerSchemaV1`,
`saveChanges()` with `LedgerStats.isHealthy`, `pruneAgedOut()`, and the
manual-work-on-ledger API.

**One security correction the merge itself created.** `canvasICSURL` is off
`SharedDefaultsMigration.legacyKeys`. It belonged there on `v3`, where the feed
URL was an ordinary preference; once the hardening lands it is a Keychain-held
bearer credential, and copying it into the shared suite would put it back into
unencrypted, backed-up storage. Nothing is orphaned — `ICSFeedURLStore.load()`
reads the pre-hardening value from `UserDefaults.standard` and moves it to the
Keychain. `SharedDefaultsMigrationTests` now asserts the key is *absent*, so
re-adding it fails loudly.

**Lesson worth keeping.** Three rounds of compile errors on this merge all had
one shape: a conflict resolved by taking one whole side of a file, dropping the
losing side's unique work while leaving its callers in place. Whole-file
resolution is only safe when one side is strictly newer. Check first.

---

## 🆕 What changed in this session (2026-08-20)

**The v2.5 → v3 merge was broken and is fixed.** A silent git auto-merge left
duplicate `clearAll()` and `loadPreviewSnapshots(_:now:)` in
`GradeWatcherStore.swift`; the branch did not compile. Kept the first of each
(the v3 version, whose comment mentions syllabus schemes). Nothing else in the
merge had the same defect — the compiler was the audit.

**Ledger hardening.** An audit of the SwiftData ledger against the four
symptoms a separate `docs/assignment-persistence-plan.md` proposed fixing found
that plan was written against **`main`**, where no ledger exists at all — on
`v3` almost all of it was already built. Six real gaps remained, and all six are
now closed:

1. **Schema versioning.** `LedgerSchema.swift` adds `LedgerSchemaV1` +
   `LedgerMigrationPlan`, wired into every `ModelContainer`. Without it, the
   first incompatible model change would have thrown on an existing store,
   fallen back to in-memory, and shown the user an empty dashboard with no
   error — the exact data loss the ledger exists to prevent. `stages` is empty
   on purpose; the point is that the *next* change is a migration.
2. **Honest failures.** `makeDefault()` keeps the reason it degraded instead of
   discarding it (`storageFailureReason`).
3. **Checked writes.** `try? context.save()` is gone; `saveChanges()` records
   `lastSaveError` / `failedSaveCount`. Settings → Storage now has three states,
   because a store can be perfectly on-disk and still be failing every write.
4. **Pruning.** `pruneAgedOut()` deletes what `isAgedOut` already hides, bounded
   by the identical predicate, so finished work stays untouchable.
5. **User-created work on the ledger.** Manual assignments and recurring tasks
   were JSON blobs in defaults — the one category of work Canvas cannot
   re-supply had none of the ledger's protection. Migrated, and exempt from the
   feed-gone/aging rules.
6. **Shared preferences.** `SharedDefaults` moves non-credential preferences to
   the App Group suite so the widget can see hidden courses and renames. It
   falls back to `.standard` unless the App Group container actually exists —
   `UserDefaults(suiteName:)` succeeds for *any* string, so without that check
   the "shared" suite is a private domain that only hides values already in
   `.standard`.

Completion is now single-source: the ledger owns `completedAt`, and the old
defaults keys are read once at launch, migrated, and deleted.

**Tests: 239 → 329.** New suites: `LedgerHardeningTests`,
`MergedCompletionWithoutSyncTests`, `RecordedICSFixtureTests` (the recorded-feed
fixtures the old plan asked for), plus additions to `AssignmentStoreTests`,
`LedgerWidgetReaderTests` and `AssignmentDeduplicatorTests`.

---

## 🆕 What changed in this session (2026-07-26)

**Bug fixes**

- **Grade Watcher resolved no courses.** Canvas course ids only ever arrive
  attached to an ICS item's URL, and the parser understood only direct
  `/courses/<id>/assignments/<id>` links. Canvas also emits calendar-style
  `/calendar?include_contexts=course_<id>` URLs, which resolved to nothing — so
  every class vanished and the screen claimed "no classes selected" while the
  picker showed them all switched on. `AppState.courseID(from:)` now reads both
  shapes; resolved ids are cached in `canvasCourseIDsByCode` (persisted) so a
  class stays fetchable in a week when it has nothing due and contributes no URL.
- **Completing a cross-posted assignment produced two Done cards.**
  `DashboardViewModel.reload` rebuilt its completed pool from the **raw**
  `canvasItems + gradescopeItems`, not the deduplicated pool. Since completing a
  merged item marks *both* underlying ids done (via `linkedID`), both originals
  qualified for Done. `AppState` now publishes `mergedCoursework` and Done reads
  that. Covered by `DoneDuplicationTests` — verified to fail (2 cards) without
  the fix.
- **Grade Watcher failed silently.** `GradeWatcherStore.error` was set on every
  non-expiry failure and **never rendered**, so a missing Canvas session looked
  identical to "no grades yet": empty cards, no explanation. Now surfaced as an
  amber banner with **Reconnect Canvas** + **Try again** actions (also on the
  expired-session banner and the "can't match your classes" empty state).

**Features / UI**

- **Edit classes** (Settings → Classes): swipe to **Rename** or **Delete**,
  long-press for a menu that adds "Reset to <code>"; deleted classes still
  collapse into a restore list. Renaming is **cosmetic only** — selection,
  reminders, grades and dedup all still key on the Canvas course code, so a
  re-sync can't undo a rename or orphan a class. Renamed labels show on the
  dashboard and Done cards via `EnvironmentValues.courseNameOverrides`
  (an empty map = old behaviour, so previews stay AppState-free).
- **Settings and Grades are pushed pages, not sheets.** Both hang off the
  dashboard's `NavigationStack` via `ContentView.DashRoute`. `SettingsSheet` was
  renamed to **`SettingsPage`** and no longer owns a `NavigationStack` or a
  modal "Done" button. Both pages carry `.lhfSheetTheme()` so they use the app's
  paper palette instead of the system grouped background.
- **Header redesign.** The weekly progress ring is gone from the top right,
  replaced by two circular icon buttons on one line — Grades, then **Settings in
  the corner**. `ProgressRingView` still exists but is no longer on the
  dashboard.
- **Splash plays 1.4× (40% faster)** via `SplashPlayer.playbackRate`. The
  safety-net timeout (6s → ~4.3s) and the handoff fade (0.45s → 0.32s) are
  scaled to match. Reading "40% faster" as 1.4× speed; if it should mean "40%
  less time" that's 1.667 in one constant.
- Removed the "your archive says otherwise." line from the Done footer and the
  **Debug** section from Settings.

---

### Session 2 (2026-07-26) — App Store prep + the grade report

**App Store blockers cleared** (details in `docs/appstore/CHECKLIST.md`, rewritten):
both widget defects, the dark-mode Info.plist pin, preview mode covering every
screen, **Disconnect Canvas / Disconnect Gradescope** in Settings → Account
(`SessionCookieStore` previously had no UI caller at all), privacy manifests
updated (+ the widget got its first one), `docs/PRIVACY.md` rewritten for
grades/Keychain/syllabus/widget/Gradescope, and all five `docs/appstore/` files
brought up to v2.5. Screenshots regenerated, now including Grades and the report.

**The grade report + syllabus ingestion** (new `docs/grades.md` §13). This
reverses two of §8's cuts on purpose:

- `GradeProjection` / `GradeProjector` — floor / at-this-pace / ceiling, and
  `requiredAverage(for:)` ("you need 94.7% on what's left for an A"). Pure math
  over `GradeBreakdown`, no new fetches.
- `GradeReportView` — pushed from each card's **Full report**; per-class watch
  toggle.
- `SyllabusParser` — deterministic, on-device, no model. Trustworthy because of
  one gate: **weights must sum to 90–110**, and a misread essentially never
  does. Also reads drop rules, expected item counts, letter cutoffs and curve
  language.
- `SyllabusMatcher` — syllabus categories → Canvas groups, exact/confirmed/
  fuzzy/unmatched, sharing `TitleNormalizer` with the Gradescope overlay.
  Coverage is all-or-nothing because the engine's manual weights are.
- `CanvasSyllabusClient` + `SyllabusTextExtractor` — syllabus_body, pages, PDF
  files, plus paste/import.
- `GradeCutoffs` — replaces the old `GradeScale` file (which still exists as a
  thin wrapper), adds custom syllabus cutoffs.

**Engine changes are additive:** `CategoryResult.possibleScoredRaw` is now
exposed (projections need pre-drop decided points), and
`Input.syllabusWeightedCategoryIDs` changes only the reported `weightSource`
(new `ScoreSource.syllabus`), never the arithmetic.

## 🐛 Known bugs — status

**Both v2.5 widget defects are FIXED** (were: the widget was built and thrown
away, and every `xcodegen generate` deleted its `NSExtension` block):

1. The widget dependency now uses **`platformFilter: iOS`** instead of
   `platforms: [iOS]`. xcodegen 2.45.4 doesn't filter a `platforms:` dependency
   per-platform — it discards it entirely (0 dependencies, 0 copy phases).
   `platformFilter` is **case-sensitive**: `iOS` writes Xcode's `platformFilter`
   attribute; lowercase `ios` and plural `platformFilters` are silently ignored.
   Getting this right matters in both directions — without the filter the macOS
   destination fails outright ("contains embedded content built for the iOS
   platform"), which is presumably why the broken `platforms:` line was there.
   After the fix: dependencies 0 → 5, copy-files phases 0 → 3, **iOS Release and
   macOS builds both green**.
2. `NSExtension` / `NSExtensionPointIdentifier` now live in `project.yml`'s
   `info.properties`, so regeneration can't delete them. **The
   `git checkout -- LHFWidget/Info.plist` dance is no longer needed.**

Verified end to end: a Release build produces
`LowHangingFruit.app/PlugIns/LHFWidgetExtension.appex` with the correct
`NSExtensionPointIdentifier`.

**`UIUserInterfaceStyle: Light` is removed** from the app's Info.plist. It
pinned the interface style at the system level, so the in-app Light/Dark setting
could never engage. The app now applies `.preferredColorScheme` from
`AppState.appearanceMode` alone. **Still unverified on a physical device.**

**Preview (demo) mode was broken past the dashboard** and is fixed:
`selectedCanvasCourseIDs()` resolved nothing (sample items carry no Canvas
URLs), so Grade Watcher showed "Can't reach Canvas for your classes" with a
Reconnect button that ejected the tapper out of preview into Penn SSO. Fixtures
now cover the class list, grades, the report, and the widget snapshot; the
Reconnect action is hidden in preview. `PreviewModeTests` also caught that
entering preview only seeded on the *next* launch.

## 🔐 How login / session works (three different auth paths — don't conflate them)

- **Assignments — no login after onboarding.** Onboarding captures the personal
  Canvas **calendar-feed URL** (`…/feeds/calendars/user_<token>.ics`, a
  self-authenticating secret URL). Every sync is a plain cookieless HTTPS GET.
  Because that URL *is* the credential, it lives in the Keychain via
  `ICSFeedURLStore` — **not** UserDefaults, where `v3` still keeps it.
  ICS carries **no submission state** (`CanvasICSClient.normalize` hardcodes
  `submitted: false`).
- **Grades + Canvas submission detection — need a live cookie session.**
  `CanvasGradesClient` replays persisted Canvas cookies
  (`SessionCookieStore`, Keychain; gathered via `AutoSyncCoordinator.canvasCookies()`).
  Penn SSO expires server-side and **cannot be refreshed silently** — the WebView
  login has to run again, which is what the Reconnect button does.
- **Gradescope** — no student API, so login cookies are persisted and replayed
  (`GradescopeClient`), throttled to ≤ 1 sync / 15 min.

### Submission state — what the app does and doesn't know

Three independent notions of "done", and they are **not** interchangeable:

| Signal | Source | Persisted? |
|---|---|---|
| Manual tick | user taps a card → `StoredAssignment.userCompleted` / `completedAt` | **Yes** (ledger) |
| Gradescope submitted | `Assignment.submitted` from the scrape → `gradescopeSubmitted` | **Yes** (ledger) |
| Canvas submitted | Grade Watcher `workflow_state` → `applySubmissionState()` → `canvasSubmitted` | **Yes** (ledger) |

All three are durable now. The Canvas flag is written as a full **replace**
rather than a merge, which is what preserves the self-healing property the old
recompute-every-refresh design had: a retracted or TA-cleared submission goes
back to unsubmitted on the next refresh. `submittedCanvasAssignmentIDs()` seeds
`AppState` at launch, so the app knows what you turned in *before* — or without —
any grade refresh.

Each flag also carries **when it was last observed**
(`canvasSubmissionObservedAt` / `gradescopeSubmissionObservedAt`, newest of the
two via `submissionObservedAt`). The flag alone cannot separate "not submitted,
confirmed a minute ago" from "not submitted, as far as we knew last Tuesday",
and those mean different things to a student deciding what to work on. Nil means
*never observed* — unknown, which is not the same as stale, and must not be
rendered as "last checked ages ago".

Still true: Canvas state is derived from the grades fetch, so **no Canvas
session ⇒ no fresh answer.** Canvas doesn't push, so this is polling while the
session is alive — best-effort, never real-time. What's changed is that a stale
answer now says so instead of disappearing.

Not yet modelled: late / missing / excused / resubmitted (Canvas sends these in
`workflow_state`; we collapse them to a Bool), and a manual student override for
when Canvas is wrong or unreachable.

---

## 🏗️ Architecture / layout

```text
App/                       # Xcode app target (@main, Info.plist, PrivacyInfo, icon)
LHFWidget/                 # iOS WidgetKit extension (Home + Lock Screen "Next Due")
project.yml                # xcodegen source of truth → LowHangingFruit.xcodeproj
LowHangingFruitKit/
  Sources/
    LowHangingFruitUI/     # SwiftUI + app logic (Marco)
      RootView, ContentView, AppState, DashboardViewModel
      OnboardingView, SettingsPage, SplashView
      GradeWatcherView / GradeWatcherStore / GradeCourseCardView
      GradeReportView / SyllabusSetupView
      NotificationScheduler, AutoSyncCoordinator, SessionCookieStore
    LowHangingFruitKit/    # data layer, no UI (Olisa)
      Models/{Assignment, CourseCode, Term, AssignmentDeduplicator}.swift
      Canvas/{CanvasICSClient, ICSParser, CanvasGradesClient}.swift
      Grades/{GradeEngine, GradeProjection, GradeCutoffs, TitleNormalizer,
              GradescopeOverlay}.swift
      Syllabus/{SyllabusParser, SyllabusMatcher, SyllabusReconciler,
                SyllabusTextExtractor, CanvasSyllabusClient, SyllabusModels}.swift
      Gradescope/GradescopeClient.swift
      CanvasDiscovery/{CanvasDiscoveryClient, CanvasRequirementScanner}.swift
  Tests/LowHangingFruitKitTests/   # 365 tests
docs/grades.md             # Grade Watcher design brief (§13 = report + syllabus)
docs/appstore/             # App Store package (current as of 2026-07-26)
```

- **Marco** owns the UI/app layer; **Olisa** owns the data layer. Cross-cutting
  model changes get a quick sync first.
- **Tests share `UserDefaults.lhf`.** `AppState` persists there, so any test
  that toggles selection/completion must normalize on the way **in and out** —
  an interrupted run otherwise leaves state that fails the next one. See
  `GradeWatcherCourseResolutionTests`.
- **Preferences live in the App Group suite, not `.standard`.** Every read and
  write goes through the single `UserDefaults.lhf` accessor
  (`Persistence/SharedDefaults.swift`), which resolves to
  `group.com.lhf.lowhangingfruit` and falls back to `.standard` when there's no
  entitlement. That's what lets the widget see completions, hidden/deleted
  courses and manual assignments at all. `SharedDefaultsMigration` copies the
  pre-existing keys across once per install, guarded by a marker in the
  destination; the list is frozen, so **new keys don't belong on it** — they're
  born in the suite. Session cookies stay in the Keychain
  (`SessionCookieStore`), deliberately device-bound, and do **not** move.
  The **Canvas feed URL** does not move either: it is a bearer credential and
  lives in the Keychain via `ICSFeedURLStore`, which is why `canvasICSURL` was
  taken off `legacyKeys` when the login-hardening line merged in. Save and
  restore through `UserDefaults.lhf` in tests, never `.standard` directly, or
  the values you write are not the ones `AppState` reads — see `IntroFlowTests`.

## 🧰 Build / run / test

```sh
cd LowHangingFruitKit && swift test              # 365 passing
xcodegen generate                                # safe now — Info.plist trap disarmed
bash docs/appstore/capture-screenshots.sh        # regenerate App Store screenshots
```

**Signing is resolved.** `project.yml` carries `DEVELOPMENT_TEAM: 24A3TDB277`
(Olisa's team, "GABRIEL NKOLISA NWOGUGU") on **both** the app and widget targets.
Marco's iPhone (`00008150-000A25D63428401C`) is registered in the provisioning
profile. Xcode has the team signed in, so `-allowProvisioningUpdates` can
register new devices.

**Install to the device** (requires **Developer Mode ON** — Settings → Privacy &
Security → Developer Mode → restart; it cannot be enabled from the Mac, and the
phone must be **unlocked** to launch):

```sh
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates -derivedDataPath /tmp/DD build
xcrun devicectl device install app --device 00008150-000A25D63428401C \
  /tmp/DD/Build/Products/Debug-iphoneos/LowHangingFruit.app
xcrun devicectl device process launch --device 00008150-000A25D63428401C \
  --terminate-existing com.lhf.lowhangingfruit
```

Debug builds are development-signed and **expire in ~7 days** — reinstall to
refresh. `CompileAssetCatalogVariant` has failed transiently once; a straight
retry fixed it.

- **DEBUG launch flags:** `-LHFDemoData` (populated dashboard, skips splash +
  onboarding), `-LHFTabAll`, `-LHFTabDone`, `-LHFShowSettings`,
  `-LHFShowGrades`, `-LHFShowReport`. These are DEBUG-only; the
  **reviewer-facing** demo is preview mode, which ships in Release.
- **Widget App Group:** automatic provisioning registers
  `group.com.lhf.lowhangingfruit` for development, but the **App Store
  distribution profile needs the App Groups capability on both App IDs** or the
  container URL is nil in the shipped build and the widget stays empty.

## 📌 Important constraints

- **Canvas developer/OAuth API is denied by Penn IT** → the assignment list comes
  from the **calendar ICS feed**. The *self-scoped session API* (the user's own
  login cookies) is reachable and is what grades/discovery use — that is a
  different door from the denied developer keys.
- No backend of ours; everything on-device. No analytics/tracking/ads.
  `PrivacyInfo.xcprivacy` declares no collection.
- **Do NOT commit real Canvas/Gradescope data** — user ids, secret feed-token
  URLs, cookies. Use synthetic values in tests and fixtures.
- **Pushing** needs the **`Marcomercader`** gh account
  (`gh auth switch --user Marcomercader`); `marco-opertti-lightfeatherio` has no
  access to `OlisaNW247/penn-dashboard`.

## 🔭 Follow-ups

**Blocking a submission (need a person, not a commit):**

- **Verify the ledger migrations on device** — see "Read this first". The test
  suite structurally cannot reach them.
- **Upload 1.1.1 to App Store Connect.** The version page exists; the build was
  never uploaded, so the Build section is still empty. Independent of all the
  v3 work — it ships from `v2.5`.
- **Fold this branch into Marco's six-branch v3 integration**, rather than
  merging over it.
- **Verify grades + submission detection on device.** Reconnect Canvas on the
  iPhone. This is the headline feature and it has never run against real data.
- **Verify dark mode and the widget on device** — both were unverifiable before
  this session's fixes and remain unverified on hardware.
- **Decide the Gradescope question** (Guideline 5.2.2). The prepared
  justification is in `docs/appstore/REVIEW_NOTES.md`; the alternative is to
  gate Gradescope out of this submission.
- **Host `docs/PRIVACY.md`**, fill its contact email, and get a support URL.
- **Register bundle IDs + the App Group** under team `24A3TDB277`, and settle
  who owns the App Store Connect record.
- **Dark-mode screenshots and the widget screenshot** — the capture script
  can't drive those; it prints a reminder at the end.
- **Re-record the demo video** to the new `DEMO_VIDEO.md` script.

**Code:**

- `.timeSensitive` notifications need the *Time Sensitive Notifications*
  capability enabled in Xcode to break through Focus (harmless without it).
- `ProgressRingView` is still unused by the dashboard — delete it or find it a home.
- The syllabus parser is deliberately conservative. When real syllabi start
  failing the 90–110 gate, add fixtures to `SyllabusParserTests` **first** — the
  gate is what makes the parser trustworthy, so loosen it only against evidence.
- Grade-change notifications are a natural next step: `GradeWatcherStore.history`
  already records one observation per course per day.
