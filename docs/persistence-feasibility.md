# Persistence Feasibility Research — Assignment Ledger

_Read-only research for `docs/assignment-persistence-plan.md`. Branch: `v3-assignment-durability`. Written 2026-08-09._

All findings below cite `file:line`. No source code was modified.

---

## Bottom line / recommendation

**SwiftData is viable. No blockers.**

- **Deployment target is iOS 17.0** for both the app and the widget extension (`project.yml`, `LowHangingFruit.xcodeproj/project.pbxproj:349,460`, `LowHangingFruitKit/Package.swift`). SwiftData requires iOS 17+, so it is fully supported. The Codable-in-App-Group fallback described in the plan §3.2/§9 is **not** needed.
- **App Group is already configured in both targets** (`group.com.lhf.lowhangingfruit`), so `ModelConfiguration(groupContainer:)` will work without any new entitlement or provisioning change.
- **No existing SwiftData or CoreData anywhere** — this is a greenfield store, no migration from a prior persistence layer.
- Toolchain is current: **Xcode 26.3, Swift 6.2.4**, project pinned to `SWIFT_VERSION = 6.0`.

Two things to be aware of when implementing (details in the relevant sections, none are blockers):
1. There is **no shared `ModelContainer` bridge** yet. `WidgetSnapshotStore` reaches the App Group by `containerURL(forSecurityApplicationGroupIdentifier:)` (a raw file path). A SwiftData store just needs its `ModelConfiguration(groupContainer: .identifier("group.com.lhf.lowhangingfruit"))`, and the `@Model` type must live in a module both the app and the widget import — today only `LowHangingFruitKit` (not `LowHangingFruitUI`) is imported by the widget target.
2. There are **no bundled fixture resources** for a feed-simulation harness. All existing tests build ICS/HTML/JSON payloads as inline string literals. The plan's §7.4 "recorded real feeds" would be new files, and the test targets currently have **no `Resources`/`Fixtures` directory or `Bundle.module` resource loading** at all.

---

## 1. iOS deployment target — SwiftData viable

**Result: iOS 17.0 minimum for both the app and the widget. SwiftData (iOS 17+) is supported.**

- `project.yml` (the xcodegen spec, the source of truth) sets a project-wide `deploymentTarget: iOS "17.0"`, `macOS "14.0"`.
- Generated `LowHangingFruit.xcodeproj/project.pbxproj`:
  - `IPHONEOS_DEPLOYMENT_TARGET = 17.0` at line **349** (Debug) and **460** (Release).
  - `MACOSX_DEPLOYMENT_TARGET = 14.0` at lines **350**, **461**.
- `LowHangingFruitKit/Package.swift`: `platforms: [.iOS(.v17), .macOS(.v14)]`, `swift-tools-version: 6.0`.
- **Widget extension** (`LHFWidgetExtension` target in `project.yml`): `supportedDestinations: [iOS]` and inherits the project's iOS 17.0 deployment target. It carries no lower per-target override in `project.yml` or `project.pbxproj`. So the widget is also iOS 17+.
- The app target is `supportedDestinations: [iOS, macOS]` (macOS 14 also clears SwiftData's macOS 14 floor).

Conclusion: adopt SwiftData directly. The Codable-in-App-Group fallback flagged in plan §9 is unnecessary.

## 2. App Group configuration

**Result: `group.com.lhf.lowhangingfruit` is declared in BOTH targets' entitlements. Ready for `ModelConfiguration(groupContainer:)`.**

- App entitlements — `App/LHFApp.entitlements:5-8`: `com.apple.security.application-groups` → `group.com.lhf.lowhangingfruit`. Wired via `CODE_SIGN_ENTITLEMENTS: App/LHFApp.entitlements` in `project.yml`.
- Widget entitlements — `LHFWidget/LHFWidget.entitlements:5-8`: identical group. Wired via `CODE_SIGN_ENTITLEMENTS: LHFWidget/LHFWidget.entitlements`.
- The group id is centralized in code as `WidgetSharing.appGroupID = "group.com.lhf.lowhangingfruit"` (`LowHangingFruitKit/Sources/LowHangingFruitKit/Widget/WidgetSnapshot.swift:7`).

**How the shared container is used today** (`WidgetSnapshot.swift`):
- Path resolution: `WidgetSnapshotStore.fileURL()` calls `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSharing.appGroupID)` and appends `widget-snapshot.json` (lines **46-50**).
- Write: `WidgetSnapshotStore.write(_:)` JSON-encodes and writes atomically, silently no-oping if the container is unavailable (lines **55-59**). Called from `AppState.publishWidgetSnapshot()` (`AppState.swift:711`), which runs at the end of every `rebuildDashboardItems()` (`AppState.swift:698`).
- Read: `WidgetSnapshotStore.read()` (lines **63-69**), called by the widget's timeline provider in `LHFWidget/NextDueWidget.swift:26,28,34`.

**What a SwiftData `ModelConfiguration(groupContainer:)` would additionally need (not yet set up):**
- The App Group id is available, so `ModelConfiguration(groupContainer: .identifier(WidgetSharing.appGroupID))` will resolve to the same container — no entitlement work required.
- **Module placement of the `@Model` type.** The widget target depends only on `LowHangingFruitKit` (`product: LowHangingFruitKit` in `project.yml`), NOT `LowHangingFruitUI`. `WidgetSnapshot`/`WidgetSharing` live in `LowHangingFruitKit` precisely so both processes can import them (see the doc comment at `WidgetSnapshot.swift:73-76`: "the widget extension target can't import LowHangingFruitUI"). Therefore the new `StoredAssignment` `@Model` and the `ModelContainer` factory must live in **`LowHangingFruitKit`** (not `LowHangingFruitUI`, where `AppState` lives) if the widget is to read the store directly per plan §8 step 6.
- **`import SwiftData`** does not appear anywhere yet (see §5) and would be new in the Kit module.
- No shared `ModelContainer` singleton / accessor exists — one must be created. There is currently no `UserDefaults(suiteName:)` usage either; all `UserDefaults` calls in `AppState` use `.standard` (e.g. `AppState.swift:120,121,791`), i.e. app-local, not the App Group. That is fine for SwiftData (it uses the container URL, not a defaults suite) but worth noting: nothing today shares a defaults suite across the app/widget boundary; the JSON file is the only shared artifact.

## 3. Existing feed/fixture data

**Result: NO bundled fixture files. All test payloads are inline string literals. A feed-simulation harness would start from scratch for its fixtures, though there are rich inline payloads to copy from.**

- No `Fixtures`/`Resources` directory under `LowHangingFruitKit/Tests` — the tests dir contains only `.swift` files (`LowHangingFruitKit/Tests/LowHangingFruitKitTests/`). No `.ics`, `.html`, or `.json` fixture files exist outside of build artifacts (`.build/`, `.iosbuild/`).
- No resource-loading in tests: `grep` for `Bundle.module`, `Data(contentsOf:`, `contentsOfFile`, `loadFixture` across `Tests/` returns **nothing**. The `Package.swift` test target declares no `resources:`.
- Existing inline payloads that could seed a harness:
  - **Canvas ICS**: `CanvasICSTests.swift:121` and `:139` build `BEGIN:VCALENDAR…` payloads as `"""…"""` / `\r\n` strings. `HardeningTests.swift` feeds many malformed/partial ICS strings to `ICSParser.parse` (lines ~15-40+).
  - **Gradescope HTML**: `GradescopeTests.swift` has numerous inline `let html = """…"""` blocks (lines 9, 30, 66, 97, 122, …) — a good source of realistic Gradescope markup.
  - **Canvas grades JSON** (submission/`workflow_state` payloads, directly relevant to persisting `canvasSubmitted`): `CanvasGradesClientTests.swift:28-80,124-133` — inline JSON with `submission` objects (`workflow_state`, `submitted_at`, `missing`, `late`, `score`).
  - **Submission logic**: `SubmissionDetectionTests.swift` constructs `AssignmentSubmissionInfo` values in code (helper at line ~14), not from fixtures.
  - **Sample dashboard data**: `SampleData.swift` (in `LowHangingFruitUI`, not tests) builds a rich in-memory `[DashItem]` set for previews/App-Store preview mode — usable as a seed but it is `Assignment` value types, not raw feed payloads.
- **What's missing for plan §7:** the ordered multi-sync `(ICS payload, Gradescope payload)` fixture sequences (§7.1), and the §7.4 "recorded real anonymized ICS feeds" as bundled resources. To load recorded feeds from disk, the test target would need a `resources:` declaration in `Package.swift` plus `Bundle.module` loading — neither exists today. The alternative (consistent with the current codebase style) is to keep them as inline `String`/`Data` literals in a new `FeedSimulationTests` file.

## 4. Current sync/persistence wiring (what a store swap must touch)

All in `LowHangingFruitKit/Sources/LowHangingFruitUI/AppState.swift`.

**The two in-memory pools** (plan's "no assignment database"):
- `@Published var canvasItems: [Assignment] = []` — line **34**
- `@Published var gradescopeItems: [Assignment] = []` — line **35**

Neither is restored in `init()` (line **119**); `init` restores only `canvasICSURL`, `completedAssignmentIDs`, hidden/deleted course keys, connection flags, onboarding/preview flags, user name, appearance — all from `UserDefaults.standard` (lines **120-131**). Confirms plan §2: assignments are never persisted.

**Where `canvasItems` is assigned (the wholesale-replace sites):**
- `AppState.swift:311` — `canvasItems = fetched` inside `sync()` (the live ICS replace the plan targets).
- `AppState.swift:233` and `:721` — `canvasItems = SampleData.items().map(\.assignment)` (preview / `loadSampleData`, DEBUG).
- Reset to `[]`: lines **209**, **255**.

**Where `gradescopeItems` is assigned:**
- `AppState.swift:405` — `gradescopeItems = try await client.fetchAssignments().map(Self.normalizingCourse)` (live Gradescope replace).
- Reset to `[]`: line **291**.

**`rebuildDashboardItems()`** — defined at `AppState.swift:669`. It is the single funnel that turns the pools into the published dashboard buckets:
- Reads `canvasItems` (line **675**) and `gradescopeItems` (into `AssignmentDeduplicator.merge`, line **680**), applies completion/term/course-selection filters (lines **685-690**), sets `assessments`/`assignments`/`laterAssignments`, and calls `publishWidgetSnapshot()` (line **698**).
- **Called from 20 sites** (every mutation path): lines **137, 211, 234, 256, 283, 292, 312, 408, 481, 509, 517, 586, 592, 598, 724, 740, 751, 781** (plus the definition at 669 and a comment ref at 562). Under the plan, `rebuildDashboardItems` becomes the read-from-store point (plan §8 step 2); the two fetch handlers (`sync()` at 311→312, Gradescope at 405→408) become `reconcile(...)` calls instead of assignment+rebuild.

**Every call site that reads the pools directly and would need to point at the new store:**
- `rebuildDashboardItems()` — `canvasItems` (675), `gradescopeItems` (680). Primary consumer.
- `allCourseCodes()` — `AppState.swift:465`: `let pool = canvasItems + gradescopeItems`. This is the class-list source (plan §4 "Class bugs" — must read the store so the list survives empty fetches).
- `updateCanvasCourseIDCache()` — `AppState.swift:567`: iterates `canvasItems` to cache course-id-by-code.
- Canvas course-id resolution — `AppState.swift:847`: iterates `canvasItems` (in the Grade Watcher course-id path).
- Grade Watcher refresh — `AppState.swift:444`: passes `gradescopeItems` into `gradeWatcher.refresh(...)`.
- Dedup entry — `AppState.swift:680` via `AssignmentDeduplicator.merge(canvasItems:gradescopeItems:)`.

Submission truth today: derived, not persisted — restored blank each launch. `updateSubmissionState()` is called after Grade Watcher refresh (`AppState.swift:446`); the submitted-set is `submittedCanvasAssignmentIDs` (referenced in plan §2), populated only from a live cookie session. This is what plan §4 "Submission state" moves onto the ledger (`canvasSubmitted`/`gradescopeSubmitted`).

Completions and course metadata that **stay in UserDefaults** (unchanged by the plan, per §6): `completedAssignmentIDs` (`AppState.swift:121,791`), `completionDates` (`796,801`), hidden/deleted course keys (`123,124,485,521`), course name overrides (`558`), and the course-id cache `canvasCourseIDsByCode` (`576`, key `canvasCourseIDsByCodeKey`).

## 5. Existing SwiftData/CoreData use & toolchain

**Result: none. Greenfield.**

- `grep` for `import SwiftData`, `import CoreData`, `@Model`, `ModelContainer`, `ModelConfiguration`, `NSPersistentContainer`, `NSManagedObject` across `LowHangingFruitKit/Sources`, `App/`, and `LHFWidget/` returns **zero** matches in source. (CoreData `.pcm` module-cache entries appear under `build/` only — those are SDK precompiled modules, not project usage.)
- The only current cross-process persistence is the JSON `WidgetSnapshotStore` (App Group file) and `UserDefaults.standard` (app-local). No shared defaults suite, no database.

**Toolchain (from this machine):**
- `xcodebuild -version`: **Xcode 26.3, Build 17C529**.
- `swift --version`: **Apple Swift 6.2.4** (swiftlang-6.2.4.1.4, clang-1700.6.4.2), target arm64-apple-macosx26.0.
- Project-pinned language version: `SWIFT_VERSION = 6.0` (`project.yml` and `project.pbxproj:293,383,410,493`); `swift-tools-version: 6.0` in `Package.swift`. The installed 6.2.4 compiler is comfortably newer than the pinned 6.0 and current SDKs (iphoneos26.2) fully support SwiftData.

---

### One-line answer to plan §9's open question
Deployment target is **iOS 17.0 (both app and widget)** → go with **SwiftData**; the Codable-in-App-Group fallback is not required.
