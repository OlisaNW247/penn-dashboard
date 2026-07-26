# Low Hanging Fruit — Handoff

_Last updated: 2026-07-26 (branch `v2.5`)_

**LHF (Low Hanging Fruit)** is a personal academic dashboard for Penn students.
It reads the student's own **Canvas** calendar feed (plus **Gradescope**, and in
v2.5 Canvas **grades**) and shows assignments as one chronological "what's due
next" list, with local reminders. SwiftUI, iPhone-first (+ macOS from the same
code), everything on-device.

---

## ⚠️ Read this first

Work is happening on branch **`v2.5`**, which builds on `V2` (PR #1) and adds
Grade Watcher, a Home/Lock Screen widget, submission auto-detection, and a
Light/Dark reskin. `v2.5` has been **force-pushed before** — always
`git fetch` and check divergence before pushing.

- `cd LowHangingFruitKit && swift test` → **183 tests / 15 suites passing.**
- iOS device + simulator builds green. **Signing is resolved** (see below).
- The app is installed and running on Marco's iPhone.

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

## 🐛 Known bugs NOT fixed (inherited, still live)

**The v2.5 widget cannot work as committed — two independent defects:**

1. `project.yml` declares the widget dependency with `platforms: [iOS]`.
   xcodegen 2.45.4 **silently discards the whole dependency**: the generated
   project has zero copy-files phases and zero target dependencies, so the
   `.appex` is built and thrown away. Verified by removing that one line —
   dependencies go 0 → 5, copy phases 0 → 3.
2. The widget target points `info.path` at `LHFWidget/Info.plist` while listing
   only `CFBundleDisplayName`, so **every `xcodegen generate` rewrites that file
   from scratch and deletes the `NSExtension` /
   `NSExtensionPointIdentifier = com.apple.widgetkit-extension` block** — the
   declaration that makes it a WidgetKit extension at all. Commit `e8d4bc6`
   restored the file but did not disarm this, so the trap is still set. **If you
   run `xcodegen generate`, immediately `git checkout -- LHFWidget/Info.plist`.**

Fixes: drop the `platforms` filter (or upgrade xcodegen), and move the
`NSExtension` keys into `project.yml`'s `info.properties` so they survive
regeneration.

**Also worth checking:** the same commit range that added the Light/Dark setting
also added `UIUserInterfaceStyle: Light` to the app's Info.plist, which pins the
interface style at the system level. Confirm dark mode actually engages on
device — this was never verified.

---

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
  Tests/LowHangingFruitKitTests/   # 183 tests
docs/grades.md             # Grade Watcher design brief
docs/appstore/             # App Store package (STALE — describes Canvas-only 1.0)
```

- **Marco** owns the UI/app layer; **Olisa** owns the data layer. Cross-cutting
  model changes get a quick sync first.
- **Tests share `UserDefaults.standard`.** `AppState` persists there, so any test
  that toggles selection/completion must normalize on the way **in and out** —
  an interrupted run otherwise leaves state that fails the next one. See
  `GradeWatcherCourseResolutionTests`.

## 🧰 Build / run / test

```sh
cd LowHangingFruitKit && swift test              # 183 passing
xcodegen generate                                # then: git checkout -- LHFWidget/Info.plist
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

- **Fix the two widget defects** above — highest value, they make a shipped
  feature dead.
- **Verify grades + submission detection** once Marco reconnects Canvas.
- **`docs/appstore/` is stale** — it still describes the Canvas-only 1.0.
  Gradescope, grades and cookie persistence all change the compliance story;
  update before any submission.
- `.timeSensitive` notifications need the *Time Sensitive Notifications*
  capability enabled in Xcode to break through Focus (harmless without it).
- No explicit "Disconnect Gradescope"; `SessionCookieStore.clear()` exists but is
  not wired to any UI.
- `ProgressRingView` is now unused by the dashboard — delete it or find it a home.
