# Release review: 3.5.0 (21), the merged tree at `c694ce7` (2026-11-22)

A read-only review of the release line `claude/ambassador-header` at
`c694ce7`, made the evening before Marco's planned ship, in a worktree cut
from it. Three parts, as asked: merge damage, build configuration,
readiness of the student-facing and App Review text. No phone was touched,
nothing was installed, nothing deployed. Verification here is filtered
`swift test --no-parallel --filter <Type>` runs, the Deno suite, and one
unsigned iOS build in **Release** configuration (the master session's build
of this tree was Debug; the archive is Release, so Release was the one to
spend the single allowed build on).

**Verdict in one line:** the Swift tree is sound and ready to archive; the
things to fix before pasting into App Store Connect are in the review
notes and the listing, not in the code. One doc contradiction is a
blocker for the paste, nothing is a blocker for the build.

## Summary by severity

**Blocker (for the App Store Connect paste, not for the archive)**

- B1. `docs/appstore/REVIEW_NOTES.md:43-44` and `:303-305` tell App Review
  the Sweeper's remote push is silent and "nothing visible is ever sent
  from the server". The code (`backend/supabase/functions/_shared/apns.ts`
  `sendSweepPush`, `LHFSweeperCheck/NotificationService.swift`) and
  `docs/PRIVACY.md:310-333` describe an **alert** push whose body is
  "checking your next deadline", rewritten by the notification extension to
  "PS7 is in · alarm off" or "PS7 · not turned in yet". Two sources of our
  own disagree; a reviewer who sees the line has a 2.3.1 ground. Replacement
  text is under Part 3.

**Should fix before ship**

- S1. The same paragraphs state as present fact that "the app registers for
  silent remote notifications" and "our server sends a push". In this build
  neither can happen: there is no `aps-environment` entitlement (every
  registration fails, logged as `register-failed`), `sweeper-wake` is not
  deployed, and `SweeperWakeRules.gatesPass` fails on `hasToken`, so the
  cookie copy and the manifest the extension would read are deleted at
  every foreground pass. Either phrase it as conditional ("if enabled in a
  later update") or leave the push out of the 3.5.0 notes entirely. The
  honest sentence for 3.5.0 is: nothing about the Sweeper leaves the phone.
- S2. `docs/appstore/LISTING.md` → App Privacy answers: no "Device ID"
  (APNs token) line. Correct **only while the wake stays dormant**, which
  it is in this build. If Olisa enables the capability and the function is
  deployed to a build that still carries `FeatureFlags.sweeperWake = true`,
  the label needs Identifiers → Device ID, App Functionality, linked, not
  for tracking, before that build ships. Put it in the 3.5.0 checklist as a
  conditional step so it is not forgotten.
- S3. `backend`: `deno task check` fails on four pre-existing `TS2741`
  errors at `_shared/catalog.ts:861` (`CatalogEntryMeetingWire` missing
  `room`, from the `origin/v10` merge). `deno test --no-check` passes
  (1012 / 0). Nothing deploys from this release, so it blocks nothing
  tonight; it is the first thing the next `sync` deploy will hit. One-line
  fix: add `room` to the fixture objects at the four call sites (or make
  the field optional on the wire type).
- S4. `docs/appstore/LISTING.md:3` says "Last updated 2026-11-17"; the
  What's New in 3.5.0 (448 characters) predates the Sweeper accuracy work
  (2026-11-18) and the tree work merged on 2026-11-21. It omits nothing
  false, but a line for "the Sweeper cancels the moment your work is in"
  and one for the tree would describe what students get. Marco's call.

**Notes (no action needed for 3.5.0, record them)**

- N1. `docs/appstore/REVIEW_NOTES.md:378-380` ("Notifications: Local
  only") in the long-form background contradicts the paste block's push
  paragraph. Both become true if the push paragraph is removed (S1).
- N2. `docs/appstore/LISTING.md:338-340` says the label is consistent with
  "the bundled `PrivacyInfo.xcprivacy` files (app and widget)"; there are
  three now (`LHFSweeperCheck/PrivacyInfo.xcprivacy`, 44 lines, present
  and lint-clean).
- N3. `docs/PRIVACY.md:57`: the intro bullet still says "with one opt-in
  exception for the work list ... described under 'Connecting an AI
  assistant'", a feature that section itself opens with "Not in this
  build". Append "(not in this build)" to the bullet. Do not cut the
  section: `AgentConnectionWiringTests` pins fourteen phrases in it and
  passes (12 / 12).
- N4. `docs/PRIVACY.md:519` (Ambassador mode) still lists "a checklist
  tick" among what leaves the phone; the checklist left the app on
  2026-11-12 and the server's `/check` is never called. Delete the three
  words. Left to the ambassador session, which owns that section tonight.
- N5. `docs/PRIVACY.md:337-339` says the cookie copy for the extension is
  "deleted when you disconnect Canvas". It is also deleted whenever the wake
  gates stop passing (`AppState+SweepHandoff.swift:52`: reminders or the
  Sweeper off, flag off, no token), so the promise is conservative and
  true; add "or turn reminders or the Sweeper off" when the section is next
  touched. The manifest file (`sweeper-manifest-v1.json`, assignment titles,
  App Group container) is deleted with the login too
  (`SessionCookieStore.swift:483`) and is not named in the on-device list.
- N6. `docs/PRIVACY.md:126-147` (Automatic Canvas reconnection) does not
  mention the Duo trust renewal: a hidden `force_login=1` sign-in while the
  session is alive, at most once a week, five days before Duo's 30-day
  trust lapses (`AppState.renewDuoTrustIfDue`). Same credential, same
  destination (Penn's login page only), so no new data class; one sentence
  would make the "when" complete. The paste block's STAY SIGNED IN has the
  same gap.
- N7. `docs/appstore/CHECKLIST.md:484` still says "App Privacy: answer 'No,
  we do not collect data'", wrong since the backend landed and contradicted
  by LISTING.md. Old text in the pre-3.0 section; delete the line.
- N8. The AMBASSADOR MODE paragraph of the review notes has a `<code>`
  placeholder: Olisa makes the test code in the founder view and Marco
  pastes it in App Store Connect only. Not a defect, a step.
- N9. Inside the last hour before a Sweeper ring, a cold launch makes two
  planner reads (the launch pass and `settleAfterFetch`'s foreground
  backstop) and a return to the foreground makes two (`.active` and the
  `refresh()` it starts). Intentional (the backstop exists because the
  minute loop once made no read on a device), bounded, and the poll backs
  off on a 403 or a low rate-limit bucket. Recorded so nobody reads the
  doubled `poll` lines in `debugWakeLogV1` as a bug.
- N10. The extension `import`s AlarmKit under `#if canImport` with
  `@available(iOS 26.0, *)` guards and no explicit `-weak_framework`,
  exactly as the widget does; the widget's archive proved weak linking on
  2026-10-20 (`otool -L`). Check the same on the 3.5.0 archive's
  `LHFSweeperCheck.appex` before upload, since a strong link would stop the
  extension loading on iOS 17-25 (the app itself would be unaffected).

## Part 1: merge damage

Method. `git log --merges` on the branch gives ten merge commits since the
`v11`/`v12` base; for each, the files changed on both sides relative to the
merge base were computed (`comm` of the two `git diff --name-only` lists),
and every such Swift file was read in the current tree around every hunk of
both `git diff <merge>^1 <merge>` and `git diff <merge>^2 <merge>`. The
nouns of each side were grepped in the other (Sweeper, poll, planner, Duo,
trust, ambassador, playbook, reply, excerpt, section, pending sync, held
sync). The fast-forwarded lines (`claude/v12-isolate-ab8b22`,
`claude/sweeper-build-0a4dd0`) and the plain commits (the Duo work, the
force-quit check) have no merge commit; they were read for the same
"rule built twice" shape against what they landed on.

| Merge | Both-sides files | Result |
|---|---|---|
| `82bea86` v12 into v11 | `AppState.swift`, `ContentView.swift`, `FeatureFlags.swift`, `NotificationScheduler.swift`, `RootView.swift`, `SettingsPage.swift`, `VisualStructureTests.swift`, PRIVACY, REVIEW_NOTES | clean |
| `f99e5f6` origin/v10 | `AppState.swift`, `AppState+CourseKnowledge.swift`, `CourseKnowledgeHeldSyncTests.swift`, PRIVACY, PROTOCOL | clean |
| `f9712b9` origin/v12 | `AmbassadorPage.swift`, `AmbassadorTests.swift`, PRIVACY | clean; the suite-nesting repair holds |
| `84286e1` force-quit check | CLAUDE.md, ROADMAP.md only | nothing to read |
| `2f14dd1`, `6a2a488`, `13153ef`, `bf58e4a`, `05ee0a8`, `01116e0` | docs only (ROADMAP) or no shared file | nothing to read |

What was checked and found right, per file:

- **`SettingsPage.swift`.** The ambassador section is its own `Section`
  between iCloud sync and feedback, outside every `#if DEBUG`; the agent
  section sits behind `state.canUseAgentConnection` after accounts; the
  degree row lives in `ProfileClassesSection.swift:125` behind its flag.
  Order matches CLAUDE.md's Profile list. The two `#if DEBUG` blocks pair
  with their `#endif`s and hold only the diagnostics rows (the exact fault
  of the 2026-10-20 merge did not recur).
- **`FeatureFlags.swift`.** Nine flags, each declared once:
  `gradeWatcher` false, `profileDiagnostics` false, `canvasAccessTokens`
  false, `edDiscussion` true, `structuredCanvasSources` true,
  `appliedFacts` true, **`agentConnection` false**, **`degreeProgress`
  false**, `sweeperWake` true.
- **`NotificationScheduler.swift` / `BerserkAlarmDelivery.swift`.** One
  `reservedForeignSlots`, one spare rule for the `ambassador:` prefix (with
  the `duo:` prefix beside it, added by the Duo commit), no v12 hunk inside
  `loudAlerts` or `plannedAlarms`.
- **`RootView.swift`.** One `onOpenURL`; `AmbassadorModel.receive` answers
  only `smooth://ambassador`, so `smooth://pair` and `smooth://link` fall
  through; the agent link is gated on `canUseAgentConnection` (false).
- **`ContentView.swift`.** One `.degree` and one `.ambassador` route; the
  passes run once each in `refresh()` and once in the launch task in the
  documented order (`deviceSyncPass`, `agentSnapshotPass`,
  `agentDraftsPass`, `settleAfterFetch`).
- **`AppState.swift`** (v10 side). `CanvasOwnSections` wiring landed in six
  places, each in the right scope (the clear inside the disconnect reset,
  the call inside `refreshCourseIntel` where `cookies` is in scope). One
  reader of the student's section, one held course-material sync
  (`pendingCourseKnowledgeSync`), one writer of
  `lastCourseKnowledgeSyncSummaryV1`. The Sweeper side's `pollPlannerWindow`,
  `LastHourPoller`, `sweeperWakePass`, `submissionCanceller` were not
  touched by that merge.
- **`AppState+CourseKnowledge.swift`.** Equals the release line; differs
  from v10 by the four-line `attachmentPass` call only, and v10 had no hunk
  the release line lacked.
- **`AmbassadorPage.swift`.** Sections in the documented order (job, what
  works, from the founders, today, posters, help us help you, feedback,
  numbers, reminders, messages, account); `.refreshable` once on the
  `Form`; `replyBlock` defined once and used in today and messages; every
  `model.*` call resolves.
- **`AmbassadorTests.swift`.** Fifteen `@Suite` structs, all top-level,
  distinct names; `AmbassadorHeaderTests` once with every test of the
  release line's version still present; filtered run 62 tests / 15 suites
  green.
- **Duo work and force-quit check (plain commits).** One
  `duoTrustExpiry` rule (the `browsertrust` tag), one `shouldRenewDuoTrust`,
  one `DuoWaitNotice`; `postDuoWaitNoticeIfDue` called from the foreground
  pass and the refresh wake only (`PushWakeTests` pins the push wake out).
  The extension and the app's push wake can both cancel the same alarm when
  the app is merely suspended; both paths end in `applyPlannerWindow`'s
  one rule and a double cancel is idempotent. `CanvasSessionRenewer.swift`
  and `LoginNavigationObserver.swift` were read, not edited: the Duo commit
  adds `startURL(for:forceReauthentication:)` and threads one Bool through
  `renewIfNeeded` → `performAttempt`; nothing else in those files moved.

Filtered runs, all green, each with other sessions' `swift test` active on
the Mac (the shared-defaults trap could in principle have bitten; nothing
did): `CourseKnowledgeHeldSyncTests` 3, `VisualStructureTests` 4,
`AmbassadorWiringTests` 5, `AmbassadorTests` (the file) 62 / 15,
`AgentConnectionWiringTests` 12, `BerserkAlarmTests` 38,
`SweeperWakePlistTests` 3. Deno: 1012 passed with `--no-check`; `deno task
check` red on the four known `TS2741` (S3).

## Part 2: build configuration

All pass, read side by side in `project.yml` and
`LowHangingFruit.xcodeproj/project.pbxproj`:

- `LHFSweeperCheck`: bundle id `com.lhf.lowhangingfruit.sweepercheck` in
  both; `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS` point at files that
  exist and lint; `NSExtensionPointIdentifier` is
  `com.apple.usernotifications.service`, principal class
  `$(PRODUCT_MODULE_NAME).NotificationService` (the class exists); the
  entitlements carry `group.com.lhf.lowhangingfruit`, which is also the
  Keychain access group `SweepCookieMirror` uses (an app-group id is a
  valid keychain access group; no separate `keychain-access-groups` key is
  needed); deployment target inherits the project's 17.0; iOS only
  (`SUPPORTED_PLATFORMS = iphoneos iphonesimulator`, `supportedDestinations:
  [iOS]`); links only `LowHangingFruitKit`.
- Embedded: the appex is in the app's `Embed Foundation Extensions` phase
  beside the widget's, both `platformFilter = ios`, with a target
  dependency on the app. No shared scheme exists (none ever did); the
  autogenerated `LowHangingFruit` scheme builds it through the dependency,
  as it does the widget.
- `aps-environment`: absent from every entitlements file and the pbxproj,
  present only in a comment at `project.yml:126`. The one
  `registerForRemoteNotifications` call (`AppState+SweeperWake.swift`) is
  behind `shouldRegister`; `didFailToRegisterForRemoteNotificationsWithError`
  only counts the failure. `UIBackgroundModes` is `fetch` +
  `remote-notification` in both files; the five usage strings and
  `NSSupportsLiveActivities` are byte-identical in both.
- Versions: `MARKETING_VERSION = 3.5.0` and `CURRENT_PROJECT_VERSION = 21`
  in `project.yml` for all three targets and in the pbxproj for all six
  configurations (3 targets × Debug/Release), no other value anywhere.
- Product reference is `Smooth.app` in all three places; `LowHangingFruit.app`
  appears nowhere.
- `plutil -lint` OK on all seven plists and entitlements.
- **Unsigned iOS build, Release configuration:** **BUILD SUCCEEDED** (`xcodebuild -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`, scratch derived data, 17 warnings, 0 errors). `Smooth.app/PlugIns` holds both `LHFWidgetExtension.appex` and `LHFSweeperCheck.appex`, and `otool -L` on the extension's binary lists AlarmKit as `weak`, so N10 is answered for this build: the extension loads on iOS 17-25. This is the first Release compile of the merged tree (the force-quit branch had one on its own base; the master's merged build was Debug).

## Part 3: readiness

**PRIVACY.md.** The agent section opens "Not in this build"; the degree
section opens "Switched off since 2026-11-12"; the Ambassador mode section
covers the code, posted days, feedback text, poster ideas (1280 px / 600 KB,
no metadata), feed stills (16, 1200 px, 200 KB, "the video itself never
leaves the phone"), post results and the local reminder; the Sweeper wake
section matches `SweeperWakePlan` (24 moments, 48 hours), the alert body,
the extension, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and the
disconnect deletion. Open items are N3 to N6 above, all small.

**REVIEW_NOTES.md.** The paste block has no agent or degree paragraph and
has the AMBASSADOR MODE paragraph. B1 and S1 are the problems. Proposed
replacement for the second half of ALARMS AND NOTIFICATIONS (after "three
Time Sensitive notifications"):

> This version holds the code for a server-sent wake-up before an alarm, but
> it is switched off in the shipped build: the app carries no push
> entitlement, registers for nothing, and the server function is not
> deployed. Every notification the student sees is local.

If instead Olisa's steps land before the archive and the wake is to ship
live, use this and add the Device ID label (S2):

> The app also registers for remote notifications. A few minutes before an
> alarm our server sends one content-free push ("checking your next
> deadline", shown quietly, no sound); a notification service extension then
> asks Canvas with the student's own login whether the work is in and, if it
> is, cancels the alarm and rewrites that line to say so. The server holds
> only the device token and the minutes; never the class, assignment or
> submission state. The app clears the lines when opened.

And `REVIEW_NOTES.md:303-305` (long-form, item 7) should say the same as
whichever paragraph is used.

**LISTING.md.** What's New in 3.5.0 names the Sweeper page and button, the
either-way swipe, the scroll fix, "in class" / "off canvas" and the update
screen's list; nothing about the agent, drafts or degree. S2 and S4 above.

**Draft 3.5.0 (21) block for `docs/appstore/CHECKLIST.md`** (a proposal;
the master session writes the real one, filling the archive commit and
times):

```markdown
## 3.5.0 (21) submission, 2026-11-22 (Marco submits)

Marco's "ship tonight" on the release line `claude/ambassador-header`
(`v11` + Olisa's `v12` + the Sweeper accuracy work + `origin/v10` and
`origin/v12` of 2026-11-14..19 + the force-quit check + the Duo trust
renewal). Attach **21**. Archived from `<commit>` and uploaded at `<time>`
("Upload succeeded"), after 4375/441 Swift (`c694ce7`), Deno 1012
(`--no-check`), the unsigned iOS Debug build and the unsigned iOS Release
build (`docs/RELEASE_REVIEW_3.5.0_2026-11-22.md`).

What ships beyond 3.4.1 (20): the Sweeper page and header button, per-class
lead time and sound, the either-way swipe, the card scroll fix, "in class"
/ "off canvas", the update screen's change list, ambassador mode (Profile
→ ambassador; a code, no account), the Sweeper's cancel at observation and
last-hour planner poll, the Duo trust renewal and the missed-push notice,
the tree's per-intent budgets, schedule line and own-section read.
**Switched off and not exposed:** the agent connection
(`FeatureFlags.agentConnection = false`, backend stays deployed) and degree
progress (`degreeProgress = false`). **Built but dormant:** the server wake
and the `LHFSweeperCheck` notification extension (no `aps-environment`
entitlement, `sweeper-wake` not deployed; the cookie copy and manifest are
deleted at every pass while the gates fail). `LISTING.md` → What's New in
3.5.0.

1. **Backend:** nothing to deploy for this release. Do NOT run
   `deploy-sweeper.mjs`; the wake ships dormant. (`deno task check` is red
   on the known `catalog.ts:861` TS2741s; fix before the next `sync`
   deploy.)
2. **Compile**, each the only run on the Mac: `cd LowHangingFruitKit &&
   swift test --no-parallel` (4375/441 at `c694ce7`), the unsigned iOS
   Release build (`xcodebuild ... -configuration Release -destination
   'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`), then the signed
   archive.
3. **On a phone:** not tonight (Marco's rule). Record here that 3.5.0 (21)
   ships with the Sweeper accuracy work, the Duo renewal and the extension
   unseen on a device beyond the Debug installs listed in CLAUDE.md →
   Release state.
4. **TestFlight → Builds:** confirm no build 21 exists. Stamped by hand in
   `project.yml` (three targets) and `project.pbxproj` (six configurations:
   app, widget, `LHFSweeperCheck`); no `xcodegen generate`.
5. **Review notes:** fix B1/S1 (the push paragraph) before pasting; paste
   the ambassador test code from Olisa's founder view into App Store
   Connect only.
6. **Archive and upload** with the two CLAUDE.md → Commands lines. On the
   archived app: `codesign -d --entitlements -` shows no `aps-environment`
   (expected), both `.appex` embedded, and `otool -L` on
   `LHFSweeperCheck.appex` lists AlarmKit as `weak`.
7. **App Store Connect:** new iOS version **3.5.0**, attach build 21, paste
   What's New, the corrected review notes, Add for Review → Submit. App
   Privacy answers unchanged (no Device ID while the wake is dormant; the
   agent connection is off, so no 5.1.2(i) recipient).
8. **After it goes live:** the `update-floor` workflow raises the floor six
   hours later; set `UPDATE_FLOOR_HOLD` only on a launch problem. Update
   `lhf-update.json`'s `changes` list to the 3.5.0 items (the wall shows
   the list set at the last release otherwise).
```

## What was not done

- No file outside `docs/` was changed: every finding is in release text or
  the backend's type check, and no clear local code bug was found to fix.
- The full Swift suite was not run (the master's); the counts above are
  filtered runs on a busy Mac.
- `CanvasSessionRenewer.swift` and `LoginNavigationObserver.swift` were
  read only, per the brief.
- Nothing here has been on a phone, by rule.
