# LHF (Low Hanging Fruit), shipped as **Smooth**

## Start here: every session reads this file, and updates it before it ends

This file and `ROADMAP.md` are the project's memory. Sessions don't remember
each other; these two files are how the next one knows what this one did.

**At the start of a session:** read this file top to bottom, then
`ROADMAP.md`. Treat both as claims to re-check rather than facts: when a
line here disagrees with the code, the code wins, and fixing the line is
part of the job. The release number below has been stale before.

**Before a session ends (or before the last commit of a piece of work),
update them.** What goes where:

| Changed | Update |
|---|---|
| What the app does (a screen, a setting, a feature added or removed) | **What the app does**, below, and **Done recently** in `ROADMAP.md` |
| The test count after a verified run | **Test baseline** (count, date, branch, how it was run) |
| A new or merged branch; a new ship line | **Branches** |
| A bug that looked like something else, or a fix whose wrong version was tempting | a new entry in **Traps that have already bitten** |
| Something still unverified on a device, or known broken | **Known gaps**, and **Now** in `ROADMAP.md` if it blocks a release |
| A privacy-relevant behaviour (what leaves the phone, how to delete it) | the intro below **and** `docs/PRIVACY.md`, in the same commit |
| A plan, idea, or experiment set aside | `ROADMAP.md` (**Next**, **Later**, or **Tried and parked**) |

Keep the register: prose that says *why*, dated when a fact can go stale
(`2026-09-24`, never "yesterday"). Replace a stale line; don't append a
contradiction beside it. Commit these files with the change they describe,
not in a separate "docs" commit later.

---

A personal academic dashboard for college students. It reads the student's
own **Canvas** (calendar feed plus their signed-in session) and
**Gradescope**, merges them into one chronological "what's due" list, tracks
grades, and sends local reminders. SwiftUI, iPhone-first, and it also builds
for macOS from the same source. The user-facing name is **Smooth** (since
2026-09-12; it was **Locust** from 2026-09-09). Display names and copy only:
bundle ids, module names, App Group names and defaults keys keep their LHF
names.

**Schools.** Built for Penn, and since 2026-09-23 it also signs in to the
Canvas of Brown, Columbia, Cornell, Dartmouth, Harvard, Princeton and Yale,
or any HTTPS Canvas address a student types in
(`CanvasInstallation.verifiedSchools` / `.custom(address:)`). Everything
server-side is Penn-only for now: pooled course materials, the server path
of ask, the announcement AI assist, and "stay signed in" (PennKey).
Non-Penn installs run fully on-device, because the backend keys course
material by numeric Canvas course id, and two schools' ids would collide.

**Privacy posture; say it this way.** "The student's own data stays
on-device; course material is pooled server-side; ask has an on-device
fallback." Grades, completions, submission state, the work list, the
student's name, and Canvas/Gradescope cookies never leave the phone. The
PennKey password, if the student saves it, stays in this phone's Keychain
and only ever goes to Penn's login page. There is no analytics, tracking,
or third-party SDK. Don't say "everything is on-device" (untrue since
`assistant-ui`) or "no server" (untrue since the backend). `docs/PRIVACY.md`
is the student-facing version and must change in the same commit as any
behaviour it describes.

**The backend.** A small Supabase project (Postgres plus Edge Functions;
`backend/PROTOCOL.md` is the contract). Every Penn install talks to it
through an anonymous account created on first launch: no email, no
password, no name. Two things go through it:
- **Course materials.** Syllabus, course pages, modules, assignment
  descriptions and announcements are fetched from Canvas with the student's
  own login, then pooled per Canvas course so classmates share one copy.
  Sync is automatic: after Canvas connects, then on the refresh loop with
  hourly staleness. There is no manual sync. Since 2026-10-02 (`v8`, not
  yet verified on a device) the same sync also reads **Ed Discussion** for
  any class whose Canvas site has an Ed tool: the app performs the tool's
  LTI launch in a hidden WebView (with the Keychain's Canvas cookies
  injected first, or the launch bounces to Penn WebLogin), reads Ed's
  session token out of the landed page's `localStorage` (since
  2026-10-09; Ed keeps no session cookie) into the Keychain
  (`EdSessionTokenStore`, with any Ed cookies in
  `SessionCookieStore.Service.ed` as a fallback), reads the board with
  `EdClient` (`x-token`), and keeps only announcements, pinned threads
  and staff posts (`EdThreadFilter`) as documents of kind `ed`. Student,
  private and anonymous posts never leave the phone; no author is ever
  named. `docs/ED_DISCUSSION.md` is the design record;
  `FeatureFlags.edDiscussion` is the kill switch.
- **ask** ("the tree"). Questions go to the backend with the on-device
  context document and matched excerpts, and are answered by a model via
  OpenRouter under LHF's own key (see the ask section below). The
  Announcement Watcher's AI assist is routed the same way, only for
  announcements that an on-device gate judges could carry a task. It is on
  by default, and a student can turn it off under Profile → notifications,
  which `docs/PRIVACY.md` promises. Neither questions nor answers are
  stored, only per-user daily request counts and token totals.

Disconnecting Canvas deletes the student's enrollment/usage rows and
anonymous account from the backend. Since 2026-09-24 there is no separate
delete button; the disconnect confirmation says so. Offline, over quota, or
with the backend unreachable, ask answers on-device:
`OnDeviceAssistantResponder` computes exact answers from the dashboard's
items, retrieves policy and content answers from synced course materials
(`CourseKnowledgeCollector` → `CourseKnowledgeStore`), and on iOS 26 /
macOS 26 Apple Intelligence devices rephrases via Apple's on-device model
(`OnDeviceLanguageModel`). Eight Edge Functions live in
`backend/supabase/functions/`: `ask`, `ask-canary`, `delete-account`,
`discover-websites`, `extract-announcement`, `extract-profile`,
`map-categories`, `sync`.

**Visual language.** Marco's Smooth design: a white paper ground with
tomato/marigold/lemon/teal/cobalt/grape accents, an "after sunset" dark
mode, the S app mark, and bundled type registered at runtime by
`SmoothFontRegistry` (`RedesignTokens.swift`):
- Satoshi (Fontshare FFL).
- Inter, Familjen Grotesk and Space Mono (all SIL OFL, licence files beside
  them in `Resources/`).
- Roobert SemiBold for the dashboard title: a commercial face from
  Displaay, cleared for shipping on 2026-09-15 under a personal agreement
  Olisa holds. There is deliberately no licence file in the repo; the
  agreement is Olisa's to produce if it is ever asked for.

**Release state.** Live on the App Store: **3.0.0 (build 11)** (App Store
id `6783911002`, released about 2026-10-01; confirmed on the store page by
Olisa 2026-10-09, with 1.2.1 live before it from 2026-09-04). This line has
been stale before, so re-check it rather than trust it. `project.yml`
stamps **3.0.1 (build 12)** on `v8` (2026-10-09, the sign-out fix below;
not yet archived). The `update-manifest` floor is still 1.2.1; raising it
to 3.0.0 is Olisa's call. Builds 7–9 of 3.0.0
were uploaded from `v5` and none was released (build 8 was rejected under
2.1(a), see Known gaps). Build 10 was uploaded 2026-09-16 at 9:54 AM,
from before stay-signed-in existed, and attached to that rejected
submission but never resubmitted. Build 11 is the first from `V7`
(uploaded 2026-09-27, with Olisa's session logic restored; see the
24-hour trap). App Store Connect refuses an upload whose build number is
not higher than every build it has seen, so check TestFlight → Builds
there, not this file, before picking the next one.

App Store Connect, as left on 2026-09-27 (re-check it): the app is
"Smooth For Students", team Stem Forward Co., whose Account Holder is
Olisa's Apple ID. The updated Apple Developer Program License Agreement
was accepted that day with Olisa's OK; until the Account Holder accepts a
new one, Apple blocks every submission. The iOS version record was
renamed 2.0.0 → 3.0.0, and its What's New and review notes were saved
(the notes as pasted are at the top of `docs/appstore/REVIEW_NOTES.md`).
Marco was finishing by hand: remove 3.0.0 from the old rejected
submission `067299d2…`, swap build 10 for 11, then Add for Review →
Submit. Whether he submitted is not recorded here. The version is set to
release automatically once approved; raise the `update-manifest` floor
only after 3.0.0 is actually downloadable. macOS 1.0 shows "Ready for
Distribution" there (reviewed 2026-08-30), whatever older docs say. On launch the app fetches a public update-policy file that can
require an update (`Update/`, below).

## What the app does

Screen by screen, as of 2026-09-25 on `V7`. Keep this current. It is the
fastest way for a new session to know what exists.

- **Onboarding.** A three-beat intro (`MissionIntroView`), then
  `OnboardingView`'s walk:
  1. school
  2. Canvas login (WebKit, the school's own SSO; Penn is PennKey + Duo)
  3. Gradescope login (optional)
  4. reminders
  5. a per-course setup walk (`OnboardingCourseSetup`)

  "Just exploring? preview with sample data" on the first pane is preview
  mode, App Review's only way in (see Known gaps). A reconnect from the
  dashboard banner opens the Canvas login directly; the school picker is
  behind the back chevron, and since 2026-10-09 (blind) picking a
  different school there asks "switch school?" first, because it signs
  the student out and forgets the saved password and Duo trust. A student can instead
  paste a Canvas calendar link (`PasteFeedLinkSheet`); that install gets
  the feed but no session, so no Grade Watcher.
- **Dashboard** (`ContentView`):
  - **Header.** The "Smooth" wordmark and the weekday. Tapping the wordmark
    ripples its squiggle and sweeps a shine across it. A grades button
    (when Grade Watcher is usable) and a profile button sit beside it.
  - **Banners.** A sync error, and a Canvas "needs a refresh" banner when
    the session is dead.
  - **Control row.** A full-width **todo · all · prev** switch
    (`DashViewPicker`), then a **class filter** menu (narrows all three
    views, with a clearable chip under the row), **+** (the add sheet: a
    one-off or weekly assignment, class picked from a grid of per-class
    coloured chips, `CoursePicker`), and
    the **megaphone**. The megaphone opens the announcement finds sheet;
    its badge counts only unread finds, and rows unread when opened are
    tagged NEW (`AnnouncementReadState`).
  - **todo**: overdue plus the next two days.
  - **all**: future work through the term.
  - **prev** (`DoneView`): leads with "N down this week", shows this week's
    finished work, and opens "earlier this semester" in place.
  - **Cards.** Tap a card to open it (full date, "edit date"); swipe right
    to complete it, with a small paper-scatter animation. A floating
    button opens **ask**.
- **Grade Watcher** (`GradeWatcherView`). Per-course grades from Canvas's
  API with the student's session:
  - syllabus categories (`GradeCategoryMap`, editable in
    `GradeCategoryMapEditor`, with a server-suggested mapping)
  - a "decided" syllabus prediction (`GradeCountPredictor`)
  - per-item/category/course overrides with provenance
  - a "how this is calculated" panel
  - the grade report (`GradeReportView`)

  `docs/grades.md` is the design record.
- **ask / "the tree"** (`AssistantView`). A chat about your classes: the
  server path for Penn, with the on-device responder as fallback.
- **Profile** (`SettingsPage`; `ProfileView` is only a wrapper), in order:
  1. your name
  2. accounts (Canvas and Gradescope connect/disconnect; "update password"
     only when Penn rejected a saved PennKey password; at Penn, three
     read-only sign-in health lines under Canvas since `v8`: password
     saved or not (or rejected, or waiting on Duo), whether Duo
     remembers this phone, last silent sign-in in plain words;
     and a read-only "ed discussion" status line, since there is nothing
     to connect)
  3. appearance (system / light / dark)
  4. reminders (on/off; 1 hour, 3 hours, 1 day, 2 days; "turned in"
     confirmations)
  5. classes (rename, hide, delete/restore; "add recurring task")
  6. notifications (per-class reminders, lead times, announcements on
     dashboard, items with nothing to submit, the announcement "ai assist"
     opt-out)
  7. sync (iCloud sync, off by default; on macOS, open at login)

  Semester rollover and "add a class" live in `ProfileSemesterSection`.
- **Background.** A 5-minute refresh loop while open, `BGAppRefreshTask` in
  the background (`BackgroundRefresh.swift`), silent Canvas session renewal
  (`CanvasSessionRenewer`, plus the saved PennKey password where
  available), grade-change and "turned in" notifications.
- **Widget** (`LHFWidget/`, a separate process). Next-due list in small and
  medium; lock-screen inline, rectangular, and circular ("N due" within 24
  hours).
- **Mac.** The same app, plus a menu-bar extra that keeps the sync loop
  alive (`LHFScenes.swift`) and open-at-login.

## Commands

```bash
# Tests — the primary gate. Runs on the macOS host.
cd LowHangingFruitKit && swift test
# If a parallel run hangs (see Test baseline), this is the reliable form:
cd LowHangingFruitKit && swift test --no-parallel

# iOS build (simulator)
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# iOS build to a connected phone, then install and launch
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug \
  -destination 'id=<device UDID from -showdestinations>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <CoreDevice id from `xcrun devicectl list devices`> <path>/Smooth.app
xcrun devicectl device process launch --device <CoreDevice id> com.lhf.lowhangingfruit

# macOS build (the package; `swift test` also exercises this)
cd LowHangingFruitKit && swift build

# Backend — Deno/Supabase Edge Functions, a separate toolchain from the above
cd backend && deno task test
cd backend && deno task check
```

`xcrun devicectl` launch fails with `FBSOpenApplicationServiceErrorDomain
error 1` when the phone is locked; the install still succeeded. The built
product is `Smooth.app` (see the macOS naming trap below).

`-LHFDemoData` (DEBUG only) seeds the bundled sample courses so the app is
usable without a real Canvas session, and pairs with `-LHFShowSettings`,
`-LHFShowGrades`, `-LHFShowReport`, `-LHFShowAssistant`, `-LHFTabAll` or
`-LHFTabDone` to land directly on a screen:

```bash
xcrun simctl launch booted com.lhf.lowhangingfruit -LHFDemoData -LHFShowAssistant
```

`-LHFAgeCanvasSession` (DEBUG only) backdates the saved Canvas cookies'
`capturedAt` by 25 hours before launch, so the real renew-on-open path runs
now instead of tomorrow. Every silent-renewal step in a DEBUG build is
printed as an `LHF-RENEW` line and kept in `UserDefaults.lhf`
`debugRenewalLogV1` (last 50: time, app state, status; never a cookie, URL
or credential). Watch it live on a tethered phone (the `--` matters, or
devicectl eats the flag):

```bash
xcrun devicectl device process launch --console --terminate-existing --device <CoreDevice id> com.lhf.lowhangingfruit -- -LHFAgeCanvasSession
```

After the fact, read it (and the session flags) straight off the phone,
read-only, from the App Group plist:

```bash
xcrun devicectl device copy from --device <CoreDevice id> --domain-type appGroupDataContainer --domain-identifier group.com.lhf.lowhangingfruit --source Library/Preferences/group.com.lhf.lowhangingfruit.plist --destination /tmp/lhf.plist
```

Crash reports come off the phone the same way (`--domain-type
systemCrashLogs`, files named `Smooth-<date>.ips`; list them with
`xcrun devicectl device info files --device <id> --domain-type systemCrashLogs`).
An `.ips` is one JSON header line plus a JSON body: read the thread with
`"triggered": true`. Reading someone else's phone needs it paired in
Xcode → Devices and Simulators first; Finder's "Trust" alone is not
enough for `devicectl`.

Release upload (2026-09-27, the path that worked; do **not** run
`xcodegen generate` first, whatever `docs/appstore/CHECKLIST.md` used to
say, and bump `CURRENT_PROJECT_VERSION` by hand in both `project.yml` and
`project.pbxproj`):

```bash
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Release -destination 'generic/platform=iOS' -archivePath build/Smooth.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Smooth.xcarchive -exportPath build/export -exportOptionsPlist docs/appstore/ExportOptions.plist -allowProvisioningUpdates
```

The export step uploads straight to App Store Connect, using the Apple
account signed into Xcode. Submitting for review is a separate, manual
step in App Store Connect; there is no API key on the dev Mac.

## Test baseline

**Current: 1539 tests / 154 suites, all green, on `v8` (2026-10-09,
`swift test --no-parallel`, on Olisa's Mac, 3.3 s).** The second compile
of the day: the sign-out review fixes (predicted 1536/154: 16 in
`SilentRenewalCoreTests`, 4 in `SwitchSchoolConfirmationTests`,
`SignInHealthTests` net +17) plus the Ed token transport (3 in
`EdWiringTests`), 1499 + 37 + 3, zero errors and zero failures, so
nothing was lost. `BackgroundRefresh.swift` is `#if os(iOS)`, so
`swift test` never compiles it: a change there also needs the iOS
`xcodebuild` from Commands before it counts as compiled. Hold the rule:
a change that lowers the count has lost work. Investigate rather than accept it, and when a
count drops on purpose (a feature removed with its tests), say which tests
and why in the commit.

Known problems, all pre-existing:
- **Full-run hang.** A parallel `swift test` sometimes stops forever with
  the main thread inside `SecItemCopyMatching` →
  `ItemImpl::checkIntegrity` (the legacy macOS file keychain). It is not a
  Keychain prompt; no SecurityAgent is running. Sampled 2026-09-23 through
  `CanvasAccessTokenStore.load()`; `fac110d` gated that read behind
  `FeatureFlags.canvasAccessTokenValue`, and it still recurred on
  2026-09-24 in the Keychain suites. `--no-parallel` has never hung. When
  it recurs, sample it from a second terminal before killing it:
  `sample $(pgrep -f LowHangingFruitKitPackageTests | head -1) 3 -file /tmp/sample.txt`.
- **`SessionCookieStoreTests` "a calendar-link-only install … cannot use
  Grade Watcher"** reads `canvasSessionExpired` as true. It passes alone
  and in `--no-parallel` runs, but fails most parallel full runs since the
  session-persistence commits (`fac110d`..`99609c0`, 2026-09-24); before
  them it was about one run in ten. A cross-suite race over process-wide
  state that hasn't been pinned down.
- **`CourseContentDashboardTests`** ("flipping a content decision never
  changes `canvasCourseIDsByCode`…") races another suite over shared
  `UserDefaults`, perhaps one run in four. See the shared-`UserDefaults`
  trap: the fix belongs in the polluting suite, not the assertion.

Two lessons from diagnosing the hang: `swift test 2>&1 | grep` fully
buffers the runner's stdout, so the last line printed is not where it
stopped (use `script -q /tmp/log swift test` for a pty); and `--filter`
matches Swift type names (`SessionCookieStoreTests`, or
`SessionCookieStoreTests.testName` with multiple `--filter` flags), never
the quoted display names.

History (newest first; each verified on a Mac). The notes say what moved
the count, so a later drop can be traced:
- 1539/154 `v8`, 2026-10-09 (later that day): the sign-out review fixes
  (`SilentRenewalCoreTests`, `SwitchSchoolConfirmationTests`,
  `SignInHealthTests` rewritten) and the Ed session-token transport
  (three in `EdWiringTests`).
- 1499/152 `v8`, 2026-10-09: Ed Discussion ingestion (`EdIngestionTests`,
  `EdClientTests`, `EdKindTests`, `EdWiringTests`) and the sign-out fix
  (`RenewalPolicyTests`, `ReconnectPaneTests`, `SignInHealthTests`; two
  tests in `CanvasSessionDeadStateTests` rewritten for the new latch rule,
  none removed).
- 1411/140 `V7`, 2026-09-27: Olisa's 24-hour cookie rule restored
  (`df759f8`, `a16ea07`). Four tests removed on purpose because they pinned
  the "keep cookies forever" rule that was reverted:
  `SessionCookieRotationTests.sessionCookieWithoutExpiryIsRetained` and
  `.explicitExpiryIsAuthoritative`, and `SessionCookieStoreTests`'
  `finalCookieDeletionDoesNotResurrectPersistedValue` and
  `partialCookieDeletionDoesNotResurrectRemovedValue`.
- 1415/140 `V7`, 2026-09-25: `CourseAccentTests` (stable per-class
  colour) with the class-chip picker.
- 1412/139 `V7`, 2026-09-24: Settings trimmed, "1 week before" retired
  (one new test, two moved from `.d7` to `.d2`).
- 1411/139, 2026-09-24: class-filter and recurring-task course adoption.
  Dice and steps prototypes removed with their tests.
- 1407/138, 2026-09-24: session persistence (`fac110d`..`99609c0`), 12 new.
- 1395/138, 2026-09-23, on `V7-polish`.
- 1371/136 `v6`, 2026-09-23: Ed Discussion recon probe
  (`docs/ED_DISCUSSION.md`).
- 1336/130, 2026-09-17: gated Canvas access tokens and stay-signed-in.
- 1253/125 `v5`: expected after reverting the preview-mode removal on
  2026-09-16 (build 9). Not re-verified on `v5` itself.
- 1241/123, 2026-09-15: preview mode removed, 12 tests deleted with it
  (reverted next day).
- Earlier marks:
  - 1252/125 and 1253/125 (2026-09-15)
  - 1250/123 and 1244/122 (2026-09-12, the Smooth merge)
  - 1230/121 and 1193/119 (2026-09-11)
  - 1170/117, 1104/109 and 1068/105 (Grade Watcher rounds 1–3, 2026-09-10)
  - 1032/101 and 1020/98 (2026-09-09)
  - 976/95, 937/92, 853/90, 838/89 and 804/87 (early `v5`)
  - 736/76 and 769/78 (`assistant-ui`)
  - 693/70 (old `v6`), 608/61 (v3.5+v4 merge), 517/55 (`v3.5`)
  - 456/40 (`v4`)
- Deno: 324 at the last recorded run (2026-09-15). Re-run
  `deno task test` before trusting it.

Nothing under `backend/` is exercised by `swift test`, and the live backend
path has only ever been exercised by hand on a device.

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
| `ROADMAP.md` | The plan: release blockers, next features, parked experiments. Read with this file at the start of every session. |
| `smooth-prototype/` | Marco's dependency-free HTML/CSS/JS tester for the Smooth redesign. Isolated from the app; `python3 -m http.server 4173 --directory smooth-prototype`. |
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
them; only a future release can. And local builds are `3.0.0` (`project.yml`), above any floor
that is safe to publish, so the wall never appears in normal development: to see
it, build with `MARKETING_VERSION=1.0.0` (that is how the live path was verified
end to end) or pass `-LHFForceUpdateWall`.

### ask: the model, the hedge, and the loop that tunes them

`backend/supabase/functions/ask/index.ts` streams the answer. Primary
model `openai/gpt-4.1-mini` (`LHF_MODEL`), no reasoning field; if it has
produced no content delta by 5 s, `z-ai/glm-5.3-flash` at
`reasoning.effort: low` (`LHF_ASK_FALLBACK_MODEL`) starts alongside and
whichever streams first wins, the other aborted; a primary that fails
or ends empty before any content hands over outright; once content has
flowed nothing switches. Olisa's rule: never more than a ten-second
wait. Every request writes one row to `ask_outcomes` -- outcome, tokens
including reasoning, chars, deltas, first-delta and total latency,
pre-race and race time, the model that answered and why (`detail`), and
a `probe` tag for synthetic traffic -- never the question or answer.
The pre-race reads (auth, quota, enrolment, profiles, catalog) are
timed (`ask: timing {...}` in the function log), overlapped, and capped:
quota fails open at 1.5 s, auth at 3 s.

`ask-canary` serves the same `handleAsk` with probe overrides on
(`probe: { model, maxTokens, reasoning, provider, contextTrimChars,
fallbackModel, disableFallback, hedgeAfterMs }`), so a candidate change
is measured before it touches `ask`. The loop runs from any Node 22
shell with the Management API token: `node
backend/scripts/deploy-function.mjs ask-canary --also ask` deploys,
`node backend/scripts/ask-probe.mjs --slug ask-canary --runs 20 --set
mixed --tag <tag>` fires 14k-token syllabus prompts and exits non-zero
on any empty or errored run, and a `select ... from ask_outcomes where
probe = '<tag>'` through `POST /v1/projects/<ref>/database/query` reads
the result. Deploying `ask` itself is a production change and needs a
person's go. The 2026-09-22 promotion was 55/55 on the canary (first
word median 1.8 s, p95 3.9 s, max 6.5 s) and 5/5 on production.

### Stay signed in (Penn only)

Canvas signs students out from time to time, and reconnecting means PennKey
(and often Duo) again. Stay signed in removes that: the app saves the
student's PennKey username and password and re-fills Penn's login form
itself.

- **How it turns on.** There is no toggle (removed 2026-09-24, owner's
  call: everyone should stay signed in). After every *interactive* Canvas
  login at Penn, while no password is saved, `OnboardingView.canvasConnected`
  offers `PennKeyCredentialsSheet`. The sheet shows a lock, one line
  ("encrypted in this phone's keychain. never sent to smooth."), and the two
  fields. "Not now" is always available; nothing is stored unless the
  student saves. The offer is gated on `CanvasInstallation.penn`: the sheet
  asks for a PennKey, and other schools must never see it.
- **Where it lives.** `PennKeyLoginForm` (Kit, pure) recognizes the
  identity provider's form and knows how to fill it.
  `PennKeyCredentialStore` keeps the credentials in the Keychain,
  this-device-only, never synced.
- **How it's used.** When the visible reconnect pane or the background
  `CanvasSessionRenewer` hits an expired session, the fill happens through
  one seam. `LoginNavigationObserver` auto-fills and submits the IdP form
  in the visible pane. The renewer does the equivalent with one JavaScript
  submission of that same IdP credential form per attempt, never more than
  one. It never resubmits the SAML response form the browser posts back to
  Canvas afterward: that form is exactly what the login WebView's
  universal-link guard already has to rebuild by hand (see the Canvas
  Student trap below), and resubmitting it would double-POST it.
- **Failure handling.** One rejected password disables auto-login outright
  rather than retrying, so a typo or a changed password can't lock the
  PennKey account; Profile → accounts then shows "update password".
- **Duo is a hard boundary.** The stored credential only ever reaches the
  IdP's password field, never a Duo prompt. A student enrolled in Duo still
  completes that step themselves whenever Duo asks (with Duo's own "remember
  this device" for 30 days, roughly monthly).
- **When it runs.** Whenever the saved Canvas cookie is more than 24 hours
  past its last save (`SessionCookieStore.load`), on launch or on returning
  to the foreground, on a Grade Watcher 401, and, since `v8` (2026-10-09,
  blind), on each foreground refresh while the session is expired and
  `AppState.shouldRetrySilentRenewal` says the cooldown has passed, and on
  background wakes now that the crash below is fixed. A background
  renewal runs in `RenewalContext.background` with a 20 s budget and can
  only ever *help*: `.renewed` saves cookies, `.passwordRejected` still
  disables auto-login, and every other outcome changes nothing, so a
  hidden WebView stalled on Duo in the background cannot latch the
  session dead. In the foreground `.timedOut` never latches, a
  `.landedOnLoginPage` latches only on the second consecutive landing,
  and `.needsDuo` still latches, because a retry would push a Duo
  notification to the student's phone and only an interactive login can
  grant trust. Every outcome is written to `lastSilentRenewalSummaryV1`
  (outcome, time, context; never a URL or credential) and shown in
  Profile → accounts in plain words, with whether a password is saved
  (and whether Penn rejected it or Duo is waiting) and whether a live
  Duo cookie exists ("duo remembers this phone"; never a date, because
  the cookie seen on a device lives 399 days while Penn's remember window
  is about 30).
  The second blind round (2026-10-09, after a three-slice review of the
  first): every production trigger goes through
  `AppState.startSilentCanvasRenewal()`, which stores the task so the
  background wake can `awaitPendingSilentRenewal()` before telling iOS it
  is done, and `BGTask.expirationHandler` → `abortSilentRenewal()` tears
  the WebView down; the dashboard hides the reconnect banner while
  `isSilentRenewalInFlight`; a `.failed` navigation (offline, captive
  portal) is `.timedOut`, never a login landing
  (`CanvasSessionRenewer.failedNavigationOutcome`); the background's
  "Duo has asked" stand-down is its own persisted flag
  (`backgroundDuoStandDownV1`, lifted only by `.renewed`, an interactive
  login or a newly saved password); the renewer's hour cooldown is seeded
  from `lastSilentRenewalAttemptAtV1` (so `-LHFAgeCanvasSession` now also
  clears that key); and a token mint or Grade Watcher success resets the
  landing streak (`noteCanvasSessionProvenAlive`). The runbook for the
  device check is `docs/SIGNOUT_VERIFICATION.md`.
  Every successful pass through Duo re-issues Duo's 30-day
  `browsertrust` cookie, so a student who opens the app at least monthly
  should never see Duo again. Since `v8` the Canvas login pane's pre-login
  purge keeps that cookie (`CanvasInstallation.preLoginPurgeDomainHints`);
  before, every manual reconnect deleted it, which is the most likely
  reason students with a saved password still saw Duo and the banner
  (`docs/SIGNOUT_INVESTIGATION.md`). Disconnecting still purges Duo.
- **Removal.** Disconnecting Canvas deletes the saved password.
- **Verified on a device, 2026-09-27, in the foreground.** On Marco's
  phone, with a real PennKey and Duo, `-LHFAgeCanvasSession` renewed in 8
  seconds, hands-free, and Duo re-issued its trust. Olisa's phone renewed
  the same way on its own that afternoon. A renewal during a *background*
  wake has never happened on any phone, because background wakes crash
  first.

## Traps that have already bitten

- **`xcodegen generate` deletes Info.plist content** unless it lives in
  `project.yml`'s `info.properties`. The widget dependency must be
  `platformFilter: iOS` — case-sensitive; `platforms:` is silently discarded.
  Don't regenerate unless a build actually demands it.
- **iOS names an app from `CFBundleDisplayName`; macOS does not.** The Mac
  build called itself "LowHangingFruit" for every version of the Smooth
  rename, in the application menu beside the Apple logo, in About, and under
  its icon, while the phone said Smooth — because nothing on macOS reads
  `CFBundleDisplayName`. The menu bar, About box and alerts read
  **`CFBundleName`**, which was still `$(PRODUCT_NAME)`; Finder, Launchpad
  and the Dock read neither, they read the **file name of the .app bundle**,
  which is `PRODUCT_NAME` itself. So the rename took all three keys, and the
  fix is not complete with any two of them. The keys had to go in
  `project.yml`, not just `App/Info.plist` — the Mac archive is the one lane
  that must run `xcodegen generate`, for the per-SDK entitlements override,
  which is precisely the step that rewrites the plist (see the trap above).
  Renaming `PRODUCT_NAME` is safe for the ledger because every path that
  holds student data derives from the bundle id or the App Group, neither of
  which moved; what it does break is a script hard-coding the built product's
  path, and it leaves an existing Mac user's pinned Dock tile stale.

- **Tests share `UserDefaults.standard`.** Any test touching selection or
  completion must normalize on the way in *and* out, or it fails the *next*
  suite. Use a scratch suite (`UserDefaults(suiteName:)` + `removePersistentDomain`).
- **`UserDefaults(suiteName:)` succeeds for any string**, entitlement or not. The
  real test for a usable App Group is asking `FileManager` for the container.
- **Without the App Group entitlement the ledger degrades to memory** and the app
  looks completely normal until a relaunch loses everything. A "storage"
  section in Settings used to surface this; it dropped out of the page in a
  Settings merge before `V7` and its dead code was deleted on 2026-09-24,
  so today **nothing warns the student** (only the iCloud sync row, and only
  while sync is on). See Known gaps.
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
- **Inverting black-on-white artwork for dark mode makes a negative.**
  The "chill" Buddha was drawn in dark mode with `.colorInvert()` +
  `.blendMode(.screen)`, which lights the shadows and darkens the face.
  Dark mode now draws `chill-dark.png` (the enclosed paper kept, ink and
  border-reachable paper transparent, flood-filled as below) as a template
  tinted light blue (`smoothCobaltInk`). Likewise the pastel accents are fills, never text:
  use their `…Ink` partners (`courseAccentInk(for:)`) for type.
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
- **An installed Canvas Student app steals the login WebView's return hop.**
  Confirmed 2026-09-12: with Canvas Student on the phone, "connect
  Canvas" opened the Canvas app and never connected; deleting Canvas
  Student fixed it. WebKit treats a main-frame navigation as a universal
  link candidate when it traces back to a user gesture (the identity
  provider's page was loaded by the user's Duo tap, and that permission
  propagates to navigations the page starts) and the destination host
  differs from the current main-frame host. The SAML return from
  idp.pennkey.upenn.edu to canvas.upenn.edu is exactly that, and Canvas
  serves the app-association file on canvas.upenn.edu, so iOS hands the
  hop to Canvas Student. Nothing in Locust opens a Canvas URL on purpose;
  the code had not changed in a month; the phone had. A programmatic
  `WKWebView.load(_:)` is never an app-link candidate, so
  `LoginNavigationObserver` cancels a cross-host arrival at the guard host
  and re-issues it itself (`appLinkGuardHost`). The wrong fix is
  cancelling and reloading `navigationAction.request`: WebKit never puts
  a POST body on that request, so the SAML POST would arrive empty. The
  guard rebuilds the POST from the identity provider's form in the page
  before re-issuing it, and allows the navigation unchanged when it cannot.
- **`NLEmbedding.sentenceEmbedding(for:)` blocks the calling thread while
  iOS downloads the asset.** On a fresh install (2026-09-12, the first
  Smooth build, the app deleted and reinstalled for the icon) the first
  question in ask showed the streaming cursor for two minutes and nothing
  else. Not the network: the phone's 60 s URLSession timeout would have
  printed the fallback message. `CourseSearch.rerank` asked Apple's
  NaturalLanguage framework for the English sentence embedding, on the
  main actor, synchronously, before the request was even built, and on a
  device that has never loaded that asset the call waits for a system
  daemon to fetch it, with no timeout and outside any URLSession. The
  tell: a stuck cursor that outlives every network timeout, on a device
  that just had the app reinstalled or was just restored. The embedding is
  a bonus on top of BM25, so `SentenceEmbeddingProvider` hands it out
  only once it is already loaded and starts the load on a background task
  the first time anyone asks; retrieval itself now runs off the caller's
  actor. The wrong fix is moving the whole search to a background queue:
  the student still waits minutes for an asset that may never arrive.
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
- **A thinking model's reasoning counts against `max_tokens`, and the
  server never forwards it.** `z-ai/glm-5.3-flash` streams its reasoning as
  `delta.reasoning`; `_shared/openrouter.ts` forwards only `delta.content`.
  On a real phone (2026-09-14) "when's my next exam?" with a 14.5k-token
  prompt of real syllabi reasoned until the 1200-token cap and emitted no
  content: the server returned 200 after 35 s having sent exactly one
  line, `done`, and the student saw an empty bubble. Two repros with
  synthetic prompts of the same size reasoned briefly and answered, so
  size alone does not trigger it; real course text does. The tells: the
  `ask-trace` line `7 stream finished: 1 lines, 0 deltas … completion
  1200`, and `pg_stat_statements` showing the quota RPC never slow (it was
  the first suspect). `reasoning: { enabled: false }` was rejected by
  OpenRouter with 400 on its first live call and the 400 body was not
  logged then (it is now, `ask: upstream failure detail`) -- because `glm-5.3-flash` is an
  always-thinking model; OpenRouter rejects every attempt to disable it.
  Resolved 2026-09-22 by measurement on `ask-canary` (see the ask section
  under Architecture): `reasoning: { effort: "low" }` cuts its thinking to
  ~6 tokens but a third of requests still took 8-66 s to the first word
  with zero reasoning tokens -- provider time-to-first-token, which no
  parameter reaches -- so the primary is now `openai/gpt-4.1-mini`
  (1.9-3.0 s every time, and right about "tomorrow" where the cheaper
  models were wrong) with `glm-5.3-flash` at low effort as a five-second
  hedge. The client's `BackendAssistantResponder` still hands an empty
  `done` to the on-device answerer as the last resort.
- **A 504 from `/rest/v1` can be the API gateway, not Postgres.** The
  2026-09-13 20:47 "database stall" was `sb_gateway_version: 2` timing out
  after ~5 s (`origin_time: 5126`, 29-byte body
  `{"message":"Gateway Timeout"}`) on the hop to PostgREST, with Postgres
  idle, no restart, no errors, and the RPC's max ever 23 ms. Before
  blaming the database, pull `edge_logs` for the request id and read
  `origin_time`, then `pg_stat_statements` for the query; the management
  API's `logs.all` returns nothing for windows wider than a few minutes,
  so query narrow windows. Also from that day, a misdiagnosis worth
  keeping: every ask logged "record_ask_usage exceeded 4000ms deadline"
  while the row still landed, and this file blamed the write running
  after `yield done`. Measured on 2026-09-22, the write lands in 125-440
  ms; the warning came from the timeout promise's own `setTimeout`, which
  nothing cleared when the request won the race, and
  `EdgeRuntime.waitUntil` kept the isolate alive long enough for it to
  fire. Fixed by clearing that timer in `finally` (`quota.ts`,
  `outcomes.ts`). The tell that should have caught it sooner: the warning
  fired on every request at exactly the deadline, never at a
  request-shaped time.
- **A recycled Canvas site carries the previous year's due dates, and one
  of them can define the whole term.** `GradeCountPredictor.term(for:)`
  anchored the term on the earliest due date across a course's items, and
  `Term.elapsedWeeks` clamps to the term's own length, so CIS 4500 read
  "week 14 of 14" on 2026-09-15 — the third week of the semester — while
  every other course read "week 1 of 14". The site was reused: three items
  still carried 2025 dates ("Met Instructor" 2025-10-14, "Class
  Participation" and "Ed Participation" 2025-12-09) ahead of the real work
  starting 2026-09-11. The term now starts after the last gap wider than
  the term's own length, since two items more than a whole term apart
  cannot belong to the same term. The first attempt used a tuned 8-week
  threshold and its own new test caught the flaw on the first compile: the
  last 8-week-plus gap in that course is the eleven weeks between the
  September homework and the December final, so it anchored on the final
  exam and claimed the semester begins in December. When a rule needs a
  magic number, check whether the quantity it is really about is already
  in scope — here it was `weeks`, the parameter one line away.
- **Penn restricts student Canvas access tokens.** The app can mint a 120-day
  Canvas access token from inside the student's own login and use it for
  `/api/v1` fetches (`CanvasAccessToken.swift`, `CanvasAccessTokenMinter.swift`,
  `CanvasAccessTokenStore.swift`, `accessToken:` on the Canvas clients), but
  Olisa's own Canvas settings page shows "+ New Access Token" greyed out, with
  the tooltip "Your Canvas administrators have chosen to limit your ability to
  generate your own access token" (canvas.upenn.edu/profile/settings) — the
  tell to check for on any other Penn account before assuming this works. A
  mint would 403 for every Penn student, so `FeatureFlags.canvasAccessTokens =
  false` gates the whole path off rather than deleting it, for the day Penn
  issues an OAuth developer key (what the Canvas Student app uses) or lifts
  the restriction. `CanvasDiscoveryClient` must stay cookie-only regardless of
  that flag, because bearer tokens are only honoured on `/api/` paths
  (`lib/authentication_methods.rb`) and discovery hits non-API pages. The
  wrong fix in both directions: storing nothing and living with the daily
  re-login the app already had before this work is simply the *previous*
  state, not a fix owed here; and scraping the password back out of the
  login page's DOM to synthesize a token is the fix that was considered and
  rejected — it defeats the whole point of a scoped, revocable token by
  handing the app a full credential anyway.
- **The 24-hour cookie rule is what keeps a student signed in; removing it
  signed Marco out.** `fac110d` (2026-09-24) dropped
  `SessionCookieStore.load()`'s rule that treats a no-expiry Canvas cookie
  as dead 24 hours after its last save. The reasoning looked sound: the
  server, not a local clock, should decide when a session is dead, so keep
  the cookie until Canvas rejects it. But that rule is the *trigger*: it is
  what flips `canvasSessionExpired` and runs `CanvasSessionRenewer` on the
  next open, while the app is on screen and the hidden WebView runs at full
  speed. Without it the renewer only ran after a Grade Watcher 401, and on
  2026-09-26 one such attempt on Marco's phone filled the saved password
  and then sat on Duo until the 30 s timeout. That read as `.needsDuo`,
  latched `autoLoginAwaitingDuoV1` and `canvasSessionConfirmedDeadV1`, and
  showed the reconnect banner. Olisa's phone, still on a 2026-09-21 build
  with the rule, never signed out. The tells, read off the phones with
  `devicectl`: the two flags true on one phone and false on the other,
  and Duo's `browsertrust` cookie re-issued at each successful renewal.
  Restored for Penn byte for byte from `39b2fff` (`df759f8`), including
  the connect pane's `login/saml` start URL and cookie filters, and the
  failed-connect no-op (`a16ea07`). The wrong fix: trusting the server
  and dropping the clock, as above. Because background wakes crash (next
  trap), the 2026-09-26 failure was a renewal with the app open, not a
  background stall; whether Duo's trust had lapsed or its page was just
  slow that day is unknown.
- **Every background refresh crashed from 2026-08-24 until `v8`, invisibly**
  (fixed 2026-10-09, blind: the launch handler is now `{ @Sendable task in
  … }` into a `nonisolated` static, and background renewals never latch;
  the history stays here because the wrong fix is still tempting).
  `LHFBackgroundRefresh.register()` hands `BGTaskScheduler` a launch
  handler with `using: nil`, so iOS runs it on its own background queue.
  The closure inherits main-actor isolation, and Swift 6 checks that at
  run time, so the app dies on entry (`SIGTRAP`, `_dispatch_assert_queue_fail`,
  thread queue `com.apple.BGTaskScheduler (com.lhf.lowhangingfruit.refresh)`)
  before any work happens. It is the same trap as the `decidedText` entry
  above. Nobody sees it, because the app is closed at the time. The tell
  is the `.ips` reports on the phone (`Smooth-<date>.ips` under
  `systemCrashLogs`, five on Marco's phone from 2026-09-24 to 09-27). The
  consequence that matters: "Olisa's proven logic" has only ever been
  renew-on-open; no background refresh or background re-login has ever
  run. The wrong fix is to fix the crash alone. That turns on background
  re-logins, the one path never tested, whose hidden WebView may stall on
  Duo and latch `needs Duo`. Fix it together with a foreground-only guard
  on `CanvasSessionRenewer` (`ROADMAP.md` → Now).
- **A background wake that starts a renewal and does not await it has
  not run a renewal.** The first `v8` fix made `BGTask` wakes renew: the
  fresh `AppState()`'s `init` sees the expired cookie and fires
  `Task { await attemptSilentCanvasRenewal() }`, then `run()` does its
  syncs (which return in a second or two when the cookie is dead, because
  there is nothing to sync with) and calls `setTaskCompleted`. iOS then
  suspends the process with the renewal mid-navigation, or mid password
  submission, and nothing is saved or recorded; the next wake starts over
  and, six hours on, submits the password again. Found by review before
  any device saw it (2026-10-09). The fix is a stored task
  (`startSilentCanvasRenewal` / `awaitPendingSilentRenewal`) plus a
  teardown on expiry; the wrong fix is a timer in `run()`, which would
  race the renewer's own 20 s budget. From the same review: a `.failed`
  WebKit navigation (offline) fell through the host classification with a
  nil URL and came out as `.landedOnLoginPage`, so two tunnels an hour
  apart could latch a live session dead; and the one-hour attempt
  cooldown lived only in memory, so two relaunches bypassed it. The
  general tell: a "blind" commit's riskiest paths are the ones no test
  can drive (`BackgroundRefresh.swift` is iOS-only and never compiled by
  `swift test`); review those by hand before the device does.
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

`V7` is the line; everything current is on it. The rest is history, kept
because some of it holds work that exists nowhere else.

| Branch | What |
|---|---|
| `v8` | **Current line (2026-10-02 onward).** `V7` plus Ed Discussion ingestion (`docs/ED_DISCUSSION.md`): the `ed` document kind on both sides of the wire, the pure Kit `Ed/` layer, `EdClient`/`EdIngestion`, and the app wiring (`EdSessionLauncher`, `EdDiscussionCoordinator`, the Settings status row). Compiled green 2026-10-09 (1499/152); nothing run on a device yet. Also carries the sign-out fix, stamped 3.0.1 (12). |
| `V7` | The line from 2026-09-23 to 2026-10-02. Contains all of `v6`, `v5`, `V7-polish` and `v8-features`: the session-persistence work, the Settings trim, the todo · all · prev switch and class filter, multi-school sign-in, and (2026-09-27, `df759f8`/`a16ea07`, from the since-deleted `v7-olisa-session`) Olisa's `39b2fff` session logic restored for Penn. 3.0.0 (11) was archived from `ddef468`. New work branches from here, and lands back here. |
| `v8-dice-toggle` | `V7` as of 2026-09-24 with the dashboard's dice "pick one for me" button (`PickAssignmentSheet`, `DashboardViewModel.pickCandidates`). Kept on purpose, not for merging as-is; see `ROADMAP.md` → Tried and parked. |
| `v8-features`, `V7-polish` | Feature branches, fully merged into `V7` (fast-forward). Safe to delete. |
| `update-manifest` | **Orphan branch, never merge.** Holds `lhf-update.json`, the live update policy the shipped app fetches from raw.githubusercontent.com; edit it from GitHub's web UI to lift or set a version floor. |
| `v6` | The line from 2026-09-16 to 2026-09-23: `v5` plus the gated Canvas access-token plumbing and stay-signed-in. In `V7`. |
| `v5` | The **App Store submission line** that uploaded 3.0.0 builds 7–9 (2026-09-06 to 2026-09-16): `assistant-ui` + `v3.5` + the ask knowledge engine, the backend, the Locust onboarding, the update gate, the Smooth redesign and dark mode. In `V7`. |
| `codex/redesign-v5`, `codex/fire-dark-mode`, `codex/smooth-header-layout`, `codex/assignment-pop-empty-celebration` | Marco's design branches (Smooth redesign, "after sunset" dark mode, header and completion polish); `docs/DARK_MODE_HANDOFF.md` and `docs/SMOOTH_INTRO_AND_APP_POLISH_HANDOFF.md` are his notes. Merged into `v5`. |
| `assistant-ui`, `onboarding-walk`, `update-gate` | ask and "the tree"; the Locust intro and onboarding walk; the update gate alone. All folded into `v5`. |
| `v3.5`, `v4`, `v3`, `claude/v4-github-repo-kvu0e0` | The 2.x era: the SwiftData ledger, Grade Watcher, readings-only courses, iCloud Tier 2, background refresh, the Mac tier, per-course reminders, semester rollover. Carried uploaded (never live) 2.0.x builds. In `v5`. |
| `origin/v2.5` | Former ship line, 1.1.1 build 3, Grade Watcher gated off. |
| `main` | Old: 1.0.0 App Store prep. Not the ship line. |
| `v2.75` | Unmerged macOS sidebar/landscape work that exists nowhere else. |

`claude/*` branches on the remote are agent working branches from August;
none is a ship line.

## Known gaps

- **Ed Discussion ingestion has not completed a sync on a device** (`v8`,
  2026-10-02, blind). The DEBUG "probe ed discussion" row settled the one
  real unknown on 2026-10-09 on Olisa's phone: the launch lands on Ed only
  once the Keychain's Canvas cookies are injected into the hidden WebView,
  and Ed's session is a `localStorage` token (`authToken`), not a cookie
  (a cookie-only `GET /api/user` is 401). The token path
  (`EdSessionTokenStore`, `EdAuth.token`) was wired, compiled and
  re-probed that day: `native whoAmI (token): status=200 courses=19`.
  The backend accepts kind `ed` since 2026-10-10 (migration
  `20261002090000_ed_kind.sql` applied through the Management API's
  `database/query`, `sync` version 7 deployed with
  `backend/scripts/deploy-function.mjs`; Node's fetch needs
  `NODE_USE_ENV_PROXY=1` in the cloud container or the proxy never
  injects the token). What remains is one full sync on a device:
  `courseKnowledgeSyncVersion` 4 forces it on the next launch, and the
  Profile row should then read "connected" with the Ed courses. The
  feature fails soft throughout: every error is a note in the sync trace
  and the Settings status line, never a thrown error.
- **Nothing has ever been tested against real Canvas or Gradescope data.**
  Every grade, submission and syllabus path is proven against fixtures
  only. This is the highest-value verification outstanding.
- **Stay signed in is proven in the foreground only.** A real PennKey and
  Duo renewed silently on two phones on 2026-09-27. If a student is ever
  signed out again, read `debugRenewalLogV1` off a DEBUG build before
  redesigning. App Store 3.0.0 users were signed out anyway; the
  investigation and the fix are `docs/SIGNOUT_INVESTIGATION.md` and the
  `v8` sign-out commit of 2026-10-09 (blind: Duo-preserving pre-login
  purge, reconnect straight to the Canvas login, background wakes
  un-crashed with a never-latch guard, foreground retries instead of a
  one-shot latch, a sign-in health line in Profile, Gradescope cookies
  re-stamped on sync), plus the second blind round of 2026-10-09 that a
  three-slice review of that commit forced (the background wake now waits
  for its renewal, see the trap below). None of it has run on a device;
  `docs/SIGNOUT_VERIFICATION.md` is the runbook. Known follow-ups, not
  blocking: a saved-password student whose session dies inside the
  six-hour credential cooldown gets GET-only retries whose landings count
  toward the latch; the live foreground `AppState` does not re-read the
  summary a background wake wrote until relaunch; `run()` reports
  `success: true` even when it skipped everything.
- **Background refresh crashed on every wake from 2026-08-24 to `v8`** (see
  the background-refresh trap, now historical). The `v8` fix has not been
  exercised on a device: verify with Xcode's Debug → Simulate Background
  Fetch on a DEBUG build and `debugRenewalLogV1`.
- **Non-Penn schools have only been exercised by tests.** The seven verified
  installations and the custom-address path have never been signed into on a
  device.
- **The `LedgerSchemaV1` migration has never opened a real pre-existing
  on-disk store.** v4 runs four migrations in one launch; the failure mode
  is a silent fallback to an empty ledger.
- **A non-persistent ledger is invisible.** If the App Group container is
  missing, `AssignmentStore` runs in memory and nothing on screen says so
  (see the App Group trap). Needs a small warning, somewhere a student
  would see it, whenever `assignmentStore.isPersistent` is false or saves
  are failing.
- **CloudKit sync is opt-in and default-off** (Profile → sync,
  docs/LAPTOP_INTEGRATION_PLAN.md Tier 2). The schema is CloudKit-eligible:
  every property on `StoredAssignment` carries a default, and every store
  pins `cloudKitDatabase: .none` unless the toggle was on at launch. The
  sync path has had little real-device soak time; treat it as Phase A.
- **The onboarding per-course walk** is covered by tests but has never been
  walked on a device (it needs a real Canvas session).
- **Recurring tasks can't be edited or deleted** from anywhere in the app.
  A task saved without a class is filed under the class its title names
  (`RecurringTask.adoptingCourse`), but anything else wrong with a saved
  task is permanent until this exists (`ROADMAP.md` → Next).
- **Preview mode is App Review's only way in, and it was removed once.** The
  only sign-in at Penn is PennKey, which nobody outside Penn can be issued,
  so the "just exploring? preview with sample data" link on the intro's
  first pane (and again at the foot of the Connect Canvas step) is the whole
  of the reviewer's path. Apple's 2.1(a) note says a video is not enough and
  a "demonstration mode" is. It was removed at Olisa's instruction on
  2026-09-15 (3ace7f0), build 8 went up without it, and Apple rejected that
  build under 2.1(a) on 2026-09-16 (submission 067299d2…). The removal was
  reverted the same day for build 9. Do not remove it again, and do not
  gate it behind `#if DEBUG`: the DEBUG `-LHFDemoData` seam is a different
  thing (a launch argument compiled out of release, for
  `capture-screenshots.sh` and the demo video) and it does not help a
  reviewer.

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
Sonnet, `mechanic` on Haiku. A cloud session that starts on `main` does
not register those definitions (seen 2026-10-09: "Agent type 'verifier'
not found"); fall back to `general-purpose` with `model: "sonnet"` and
paste the role's rules into the brief. For built-in agents, pass the tier per call:
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
