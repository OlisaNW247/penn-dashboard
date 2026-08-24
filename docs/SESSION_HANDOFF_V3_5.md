# v3.5 session handoff — state, gates, and the next session's job

_Written 2026-08-24 at the end of a long build session. Read top to
bottom before touching anything. Companion docs:
`READINGS_COURSES_PLAN.md`, `BACKGROUND_REFRESH_PLAN.md`,
`LAPTOP_INTEGRATION_PLAN.md`, `STALE_REQUEST_HANDOFF.md` (historic)._

## 1. Where things stand

Branch **`v3.5`**, ~45 commits, pushed. Everything below compiled and
passed `swift test` on the owner's Mac (~470 tests / 50 suites) unless
marked otherwise.

**Shipped to the App Store already (v1.1.2, from the earlier
`claude/stale-request-handoff-docs-g6n5tp` branch):** the Canvas
"Stale Request" login fix (duplicate-POST guard + auto-recover in
`LoginNavigationObserver`), diagnostics report repair, privacy/support
pages (hosted at olisanw247.github.io/lhf-site/).

**On `v3.5`, device-validated:**
- Readings-only course pipeline end to end (`READINGS_COURSES_PLAN.md`
  has the full map): profile engine → nudge → opt-in → modules-JSON
  import → planner date overlay (two-pass join: content-id, then
  normalized-title — Pages carry no content_id). Validated on LGST 1010:
  55 imported, 20 dated.
- Enrollment currency + academic-code filters (junk courses out of
  Grade Watcher; "TAP 2028" is the accepted false positive).
- "Turned in ✓" notifications + Settings toggle (default on).
- Pre-login "press sign-in once" notice card.
- Splash no longer pauses background audio (.ambient session).
- Persimmon icon, iOS + macOS.
- Tier 1 Mac: `LHFScenes` (scene-level shared AppState), menu-bar extra
  whose LABEL anchors the always-on 5-min loop, launch-at-login toggle,
  grouped form styling.
- Test-runner isolation (`SharedDefaults.isTestRunner`) — see trap #1.

**On `v3.5`, compiled but NOT yet device-validated:**
- iOS BGAppRefreshTask background refresh (`LHFBackgroundRefresh`,
  task id `com.lhf.lowhangingfruit.refresh`) — needs a day of organic
  observation or the debugger simulate trick
  (`BACKGROUND_REFRESH_PLAN.md` has it).
- **Tier 2 Phase A iCloud sync — the next session's main job.** Code
  complete (commits `4fd8a2b`..`8b97371`): entitlements, CloudKit-ready
  schema defaults, `AssignmentStore.makeDefault(syncEnabled:)`,
  `init(cloudKitGroupURL:)`, Settings toggle "Sync between my devices"
  (default OFF, applies at relaunch), `CloudPrefsMirror` (KVS,
  whole-value LWW over four pref blobs). ZERO of the CloudKit path has
  ever executed — swift test structurally cannot reach it.

## 2. The next session starts HERE

Phase A device bring-up, with the owner driving both devices:

1. Owner: signed into the Apple developer account in Xcode; first
   build after the entitlements auto-provisions
   `iCloud.com.lhf.lowhangingfruit`. Signing errors are the likeliest
   first blocker — resolve before anything else.
2. `xcodegen generate` (entitlements/project.yml changed), build to Mac
   AND iPhone, same iCloud account, toggle sync on on both, relaunch.
3. Acceptance: completion ticked on Mac appears on phone within ~2 min
   and vice versa; renames/decisions propagate via KVS; toggling sync
   OFF leaves local data intact; `storageFailureReason` surfaces in the
   Settings status line when CloudKit fails to start.
4. Likeliest first bugs: `ModelConfiguration(url:cloudKitDatabase:)`
   signature drift (flagged unverified by the implementer),
   CloudKit rejecting the schema despite the added defaults, duplicate
   rows post-merge (the id-uniqueness invariant lives in `rowsByID()`
   sweep — watch it), and CloudKit Dashboard needing the dev-schema
   reset dance.
5. Only after A holds for days: Phase B — CKQuerySubscription visible
   pushes (reach a force-quit phone), APNs entitlements, the
   remote-notification background mode. Design sketch in
   `LAPTOP_INTEGRATION_PLAN.md`; alert text via
   alertLocalizationKey over the CD_ mirrored fields is the fiddly bit.
6. Before ANY App Store submission of v3.5 work: deploy the CloudKit
   dev schema to production in CloudKit Dashboard, bump to 1.2.0 in
   BOTH project.yml version blocks, and get Marco's review — this
   branch reaches deep into his UI layer (login pane semantics,
   observer steering exceptions, scenes restructure) and into the
   shared persistence layer.

### 2b. Pre-flight audit, 2026-08-24 (container session — NOT compiled)

A follow-up session without a Swift toolchain statically audited the
Phase A code before device bring-up. Everything below is on
`claude/session-handoff-v3-5-56jkcr`; the owner's next
`git pull && swift test` is the compile gate for all four edits — **none
of them has been compiled.**

Resolved from step 4's list:
- **Signature drift is a non-issue.** Verified against Apple's SwiftData
  docs: `ModelConfiguration.init(_:schema:url:allowsSave:cloudKitDatabase:)`
  exists, as do `.automatic` / `.none` / `.private(_:)` on
  `ModelConfiguration.CloudKitDatabase`. Every spelling the branch uses
  matches.
- Schema re-checked: `StoredAssignment` and `StoredGradeObservation`
  are both CloudKit-compliant (every non-optional defaulted, no
  `.unique`, no relationships).

Found and fixed (watch these in the first `swift test`):
1. **`AppState.disconnectCanvas()` had `cloudPrefsMirror?.push(...)`** —
   optional chaining on a non-optional `let`, which is a compile error.
   This contradicts §1's "everything compiled" claim, so treat the tip
   of the branch as having missed at least one compile pass. Fixed to
   plain member access (matching the file's three other call sites).
2. **Trap #2 was only half-applied.** `AssignmentStore`'s local inits
   pin `cloudKitDatabase: .none`, but `GradeHistoryStore` (both inits)
   and `LedgerWidgetReader.snapshot(storeURL:)` left it at `.automatic`.
   Since `StoredGradeObservation` is CloudKit-compliant, the entitled
   device build would NOT have thrown — grade history would have
   silently mirrored to CloudKit for every user, sync toggle or not.
   All three now pin `.none` (plus the raw-container helper in
   `AssignmentLedgerUniquenessTests`, for the invariant's sake).

One acceptance-criteria caveat for step 3: SwiftData's CloudKit import
is push-driven, and the remote-notification background mode / APNs
side is deliberately Phase B. Until then, cross-device *import* latency
is at the mercy of launch/lifecycle events — so if a tick doesn't show
up in ~2 min, relaunch the receiving app before declaring sync broken.
Only a tick that survives a relaunch without appearing is a real bug.

## 3. Traps this session hit — do not relearn these

1. **macOS resolves the App Group container WITHOUT the entitlement.**
   `swift test` on the dev Mac was writing fixtures into the real Mac
   app's ledger/defaults/widget file. `SharedDefaults.isTestRunner`
   guards all three choke points. Never remove those guards.
2. **`ModelConfiguration`'s `cloudKitDatabase:` defaults to
   `.automatic`**, which adopts the first entitled container — now that
   entitlements exist, every non-cloud store MUST pin `.none`
   (both `AssignmentStore` local inits do; keep it that way).
3. **xcodegen regenerates Info.plist from project.yml's properties
   map** — plist-only keys silently vanish. Versions, background modes,
   BGTask ids all live in project.yml.
4. **`#if canImport(BackgroundTasks)` passes on macOS** (Catalyst ships
   the framework; symbols are unavailable) — guards need `&& os(iOS)`.
5. **swift test compiles the macOS slice only** — anything inside
   `os(iOS)` guards is compiled ONLY by the owner's device build; treat
   ⌘R as that code's compiler. Inverse: Mac-side code (LHFScenes etc.)
   IS fully covered by swift test.
6. **Delegate methods must match SDK signatures exactly** — the whole
   Stale Request saga hinged on a missing `@MainActor @Sendable` on a
   completion handler: near-match = silently never called. The
   respondsToSelector probe in `makeWebView` logs a tripwire.
7. **`enterPreviewMode()` persists a flag** that poisons every AppState
   constructed after it; tests must clear it unconditionally (a
   conditional restore self-perpetuates a stuck flag).
8. **Sub-second Date equality** in tests: parsed fractional timestamps
   ≠ whole-second expectations even when they print identically.
9. Canvas API notes: modules need `include[]=content_details` for any
   dates; Pages have `page_url`, never `content_id`; planner
   (`/api/v1/planner/items`) is the only source of student-to-do dates
   and what the Canvas dashboard renders; `/courses` HTML lists past
   enrollments (slice before the Past/Future markers).

## 4. How to run the session (what worked)

Overseer/doer split per CLAUDE.md: subagents (`implementer`,
`mechanic`, `verifier` in `.claude/agents/`) do the writing; the
overseer surveys anchors first, writes standalone briefs (subagents see
NO conversation), reviews the actual diff before committing, and runs
the owner's Mac as the compile gate after every package ("a change that
has not been compiled is not done" — this container has no Swift
toolchain). The owner runs a tight loop:
`git pull && swift test 2>&1 | tail -3` then ⌘R; on failure they paste
`swift build 2>&1 | grep -B 3 -A 12 "error:"`. Diagnostics-first
debugging paid for itself every time: extend the copyable report /
os_log before guessing (see the import-path "confession" pattern in
AppState's `moduleImportLog`).

## 5. Open items beyond Phase A

- Marco review of the whole branch (repeatedly flagged, still pending).
- 1.2.0 version bump at submission time.
- Ledger migration device-verify note in `STALE_REQUEST_HANDOFF.md` §7
  (probably implicitly satisfied by this session's install-over builds;
  never formally checked).
- BGAppRefresh organic-wake observation on the phone.
- Mac icon is full-bleed square; native-style rounded-rect margins are
  a cosmetic pass someone may want.
- `docs/brief.md` and a few doc comments still say "RootView" for what
  is now `RootCore`/`OwnedRootView` — cosmetic staleness.
- Support page could gain "don't force-quit for faster notifications".
