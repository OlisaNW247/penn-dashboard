# Low Hanging Fruit — Handoff

_Last updated: 2026-07-26 (branch `v2.5`)_

**LHF (Low Hanging Fruit)** is a personal academic dashboard for Penn students.
It reads the student's own **Canvas** calendar feed (plus **Gradescope**, and in
v2.5 Canvas **grades**) and shows assignments as one chronological "what's due
next" list, with local reminders. SwiftUI, iPhone-first (+ macOS from the same
code), everything on-device.

---

## ⚠️ Read this first

> **Branch map (2026-07-26).** `v2.5` is the **App Store submission branch**:
> release prep is applied and **Grade Watcher is gated off**
> (`FeatureFlags.gradeWatcher = false`) because it has never worked against a
> real Canvas session. `v3` is the **beta branch** — same release prep, plus
> Grade Watcher, the new grade report (floor/ceiling/target projections) and
> syllabus ingestion. Grade Watcher work continues there, not here.

Work is happening on branch **`v2.5`**, which builds on `V2` (PR #1) and adds
Grade Watcher, a Home/Lock Screen widget, submission auto-detection, and a
Light/Dark reskin. `v2.5` has been **force-pushed before** — always
`git fetch` and check divergence before pushing.

- `cd LowHangingFruitKit && swift test` → **189 tests / 16 suites passing.**
- iOS **Release** and macOS builds green; the widget `.appex` is verified
  embedded in `LowHangingFruit.app/PlugIns/`. **Signing is resolved** (see below).
- **`xcodegen generate` is now safe** — the `LHFWidget/Info.plist` trap is
  disarmed (see "Known bugs" below).

**The one open question blocking verification:** Grade Watcher needs a **live
Canvas cookie session**, which is separate from the cookieless ICS feed the
assignment list uses. Marco's device currently has **no stored Canvas session**
(he connected Canvas before v2.5 started persisting Canvas cookies), so Grades
is empty and Canvas submission detection is inert. The fix is for him to tap
**Reconnect Canvas** in Grade Watcher. Until he does, grades and submission
tracking cannot be verified end-to-end against real data.

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

## 🐛 Known bugs — status

**Both widget defects are FIXED.** The dependency now uses
**`platformFilter: iOS`**, not `platforms: [iOS]` — xcodegen 2.45.4 doesn't
filter the latter per-platform, it discards the dependency entirely (0 target
dependencies, 0 copy phases, `.appex` built and thrown away). `platformFilter`
is **case-sensitive**: `iOS` works, lowercase `ios` and plural `platformFilters`
are silently ignored. It's load-bearing in both directions — without it the
macOS destination fails outright on an embedded iOS-only appex, which is
presumably why the broken `platforms:` line was there. The `NSExtension` keys
now live in `project.yml`'s `info.properties`, so regeneration can't delete
them; **`git checkout -- LHFWidget/Info.plist` is no longer needed**.

**`UIUserInterfaceStyle: Light` is removed** from the app's Info.plist — it
pinned the interface style at the system level, so the in-app Light/Dark setting
could never engage. **Still unverified on a physical device.**

**Preview (demo) mode was broken past the dashboard** and is fixed: sample items
carry no Canvas URLs, so no course id resolved and Settings → Classes came up
empty. `PreviewModeTests` also caught that entering preview only seeded on the
*next* launch.

**Grade Watcher is gated off on this branch** (`FeatureFlags.gradeWatcher`). It
is not a fixed bug — it is a shipped-disabled feature. The engine is well
tested, but it needs a live Canvas cookie session (the dashboard's ICS feed is
cookieless) and has never worked end to end on device. Only the entry points are
hidden; everything behind them stays compiled and tested so `v3` keeps merging
cleanly, and re-enabling is a one-line change once it's verified.

**Note that Canvas grade data is still fetched** even with the UI hidden:
`AutoSyncCoordinator.refreshCanvasGrades` runs because automatic submission
detection is derived from the same payload. PRIVACY.md and REVIEW_NOTES.md
disclose it on those terms.

## 🔐 How login / session works (three different auth paths — don't conflate them)

- **Assignments — no login after onboarding.** Onboarding captures the personal
  Canvas **calendar-feed URL** (`…/feeds/calendars/user_<token>.ics`, a
  self-authenticating secret URL). Every sync is a plain cookieless HTTPS GET.
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
| Manual tick | user taps a card → `completedAssignmentIDs` + `completionDates` | **Yes** (UserDefaults) |
| Gradescope submitted | `Assignment.submitted` from the Gradescope scrape | with the item |
| Canvas submitted | `submittedCanvasAssignmentIDs`, derived by `updateSubmissionState()` from Grade Watcher snapshots | **No — recomputed every refresh** |

The Canvas set is deliberately **not** persisted so a retracted/corrected
submission self-heals. Visible consequence: on a cold launch an auto-filed item
sits in the active list until the first successful grade refresh lands, then
moves to Done. And because it is derived from the grades fetch, **no Canvas
session ⇒ the app does not know what's submitted.** Canvas doesn't push, so this
is polling while the session is alive — best-effort, never real-time.

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
      NotificationScheduler, AutoSyncCoordinator, SessionCookieStore
    LowHangingFruitKit/    # data layer, no UI (Olisa)
      Models/{Assignment, CourseCode, Term, AssignmentDeduplicator}.swift
      Canvas/{CanvasICSClient, ICSParser, CanvasGradesClient}.swift
      Gradescope/GradescopeClient.swift
      CanvasDiscovery/{CanvasDiscoveryClient, CanvasRequirementScanner}.swift
  Tests/LowHangingFruitKitTests/   # 189 tests
docs/grades.md             # Grade Watcher design brief
docs/appstore/             # App Store package (current; no-grades 1.0 copy)
```

- **Marco** owns the UI/app layer; **Olisa** owns the data layer. Cross-cutting
  model changes get a quick sync first.
- **Tests share `UserDefaults.standard`.** `AppState` persists there, so any test
  that toggles selection/completion must normalize on the way **in and out** —
  an interrupted run otherwise leaves state that fails the next one. See
  `GradeWatcherCourseResolutionTests`.

## 🧰 Build / run / test

```sh
cd LowHangingFruitKit && swift test              # 189 passing
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
  onboarding), `-LHFTabAll`, `-LHFTabDone`, `-LHFShowSettings`.
- **Widget App Group:** automatic provisioning registers
  `group.com.lhf.lowhangingfruit`; without it the container URL is nil and the
  widget shows its empty state. (Moot until the two widget bugs above are fixed.)

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

**Blocking submission (need a person, not a commit):**

- **Verify submission auto-filing on device** — reconnect Canvas; it rides the
  same session Grade Watcher does and has never run against real data.
- **Verify dark mode and the widget on device** — both were unverifiable before
  this session's fixes.
- **Decide the Gradescope question** (Guideline 5.2.2) — prepared justification
  is in `docs/appstore/REVIEW_NOTES.md`.
- **Host `docs/PRIVACY.md`**, fill its contact email, get a support URL.
- **Register bundle IDs + the App Group** under team `24A3TDB277`; settle who
  owns the App Store Connect record.
- **Dark-mode and widget screenshots** by hand; re-record the demo video.

**Code:**

- `.timeSensitive` notifications need the *Time Sensitive Notifications*
  capability enabled in Xcode to break through Focus (harmless without it).
- `ProgressRingView` is unused by the dashboard — delete it or find it a home.
- Grade Watcher: fix it on `v3`, verify on device, then flip
  `FeatureFlags.gradeWatcher` and restore the grade copy in
  `docs/appstore/LISTING.md` / `REVIEW_NOTES.md` (both were trimmed for this
  build; `v3` has the versions that describe grades).
