# App Store submission checklist — LHF (iOS)

_Last updated: 2026-09-02 — **2.0.1 (build 6)** from `v3.5`._

---

# 2.0.1 submission (current)

Shipping **2.0.1 / build 6** as the update to the live **2.0.0 / build 5**:
the same code plus two submission-tracking fixes (a reconnect prompt when
the Canvas session lapses; grades fetched for every Canvas site that shares
a course code) and a diagnostics section. Grade Watcher stays hidden.
Repo state: version/build stamped in `project.yml` and the committed pbxproj
(app + widget match); **674 tests / 66 suites green** on the owner's Mac
(2026-09-02); both fixes confirmed on the owner's phone.

Steps: Xcode → Product → Archive ("Any iOS Device (arm64)") → Organizer →
Distribute App → App Store Connect. In ASC: create version 2.0.1, attach
build 6 once processed, paste the 2.0.1 What's New from `LISTING.md`
(description/keywords/screenshots unchanged from 2.0.0), submit.

---

# 2.0.0 submission (shipped 2026-08, kept for reference)

Shipping **2.0.0 / build 5** as the update to the live **1.1.2 / build 4**.
Repo state: version/build already stamped in `project.yml` and the committed
pbxproj (app + widget match); **644 tests / 63 suites green** on the owner's
Mac; owner + Marco sign-off recorded 2026-08-27.

## Done in repo — ✅

- ✅ Version 2.0.0 / build 5 on both targets (exceeds shipped 1.1.2/4).
- ✅ **Grade Watcher is hidden this release** (`FeatureFlags.gradeWatcher =
  false`) and the whole submission package is scrubbed to match: LISTING.md
  rewritten (no grades/syllabus claims), REVIEW_NOTES.md walkthrough no longer
  visits Grades, the two grades screenshots are deleted, and
  `capture-screenshots.sh` no longer captures them (the DEBUG seams would
  render the hidden screens; a screenshot of an unexposed feature is a 2.3.1
  rejection).
- ✅ What's New for 2.0.0 drafted in LISTING.md — paste, don't rewrite from
  memory.
- ✅ Privacy: nothing new is collected; the new preference/cache keys are
  UserDefaults, already covered by the CA92.1 declaration in both
  `PrivacyInfo.xcprivacy` files. The nutrition-label answer stays
  "No, we do not collect data."
- ✅ Preview mode covers the 2.0 surfaces (dashboard incl. nothing-to-submit
  tags, Profile class list, Settings) — regression-tested in
  `PreviewModeTests`/`ProfileTabTests`.

## Needs you, in order — 🟡

1. 🟡 **Regenerate screenshots** — the live listing's shots show the pre-v4 UI
   and the old icon. `bash docs/appstore/capture-screenshots.sh`, then by hand:
   a dark-mode retake of the dashboard, the widget, and (optional, no seam yet)
   the Profile screen. Upload the new 6.9" set to ASC; delete the old grades
   shots from the listing there too.
2. 🟡 **Distribution profiles carry App Groups on BOTH App IDs** (app +
   widget) — without it the shipped widget's container URL is nil and the
   widget is empty in production only. Automatic signing usually handles it;
   verify in the archive's entitlements before uploading (Organizer → the
   archive → Validate shows them).
3. 🟡 **Archive + upload** (Xcode → Product → Archive on "Any iOS Device
   (arm64)", Organizer → Distribute App → App Store Connect).
4. 🟡 **ASC version setup**: create version 2.0.0 on the app page, attach
   build 5 once processing finishes, paste the What's New, the rewritten
   description/promo text/keywords from LISTING.md, and the rewritten
   REVIEW_NOTES.md (add contact name/email). Screenshots from step 1.
5. 🟡 **Submit for review.** Phased release: your call; harmless either way
   for an app this size.

## Watch-outs carried from the last submission

- The demo/screen-recording attachment in App Review Information showed the
  1.x flow — re-record or drop it (REVIEW_NOTES no longer depends on it, but a
  stale video showing Grade Watcher invites questions about a hidden feature).
- The support + privacy-policy URLs must still resolve; they're account-side,
  nothing in-repo to do.

---

# 1.0.0 submission (historical — v2.5 era below, kept for reference)

_Last updated: 2026-07-26 (branch `v2.5`)_

Status legend: ✅ done in repo · 🟡 needs you (account / hosting / Apple / device) · ⬜ to do

**Version decision:** shipping as **1.0.0 / build 1**. "v2.5" is the internal
milestone name; nothing has ever been on the App Store, and submitting a
first-ever release as 2.5.0 invites "where are 1.0 through 2.4?" from review.
If you'd rather ship as 2.5.0, change `MARKETING_VERSION` in `project.yml` —
one line, and the widget's copy must match.

---

## Code & build — ✅ done

- ✅ **Widget defects fixed.** The `platforms: [iOS]` dependency filter (which
  xcodegen 2.45.4 silently turns into "discard the dependency entirely") is
  replaced with **`platformFilter: iOS`** — case-sensitive; lowercase `ios` and
  the plural `platformFilters` are both ignored without warning. That keeps the
  dependency on iOS *and* stops the macOS destination from trying to embed an
  iOS-only appex. The `NSExtension` / `NSExtensionPointIdentifier` keys now live
  in `project.yml`'s `info.properties`, so `xcodegen generate` can no longer
  delete them. Verified: target dependencies 0 → 5, copy-files phases 0 → 3, and
  a Release build produces `LowHangingFruit.app/PlugIns/LHFWidgetExtension.appex`
  with the right extension point. **`git checkout -- LHFWidget/Info.plist` after
  regenerating is no longer needed.**
- ✅ **`UIUserInterfaceStyle: Light` removed** from the app's Info.plist. It
  pinned the interface style at the system level, which meant the in-app
  Light/Dark setting could never actually take effect. The app applies its own
  scheme via `.preferredColorScheme(state.appearanceMode.colorScheme)`.
- ✅ **Preview mode covers the whole app** (see "Review access" below).
- ✅ **Disconnect Canvas / Disconnect Gradescope** in Settings → Account, wired
  to `SessionCookieStore`. Previously the Keychain-stored logins had no UI to
  remove them at all; deleting the app was the only way out.
- ✅ Privacy manifests updated: the app's now declares App Group file access
  alongside UserDefaults, and **the widget target has one for the first time**
  (`LHFWidget/PrivacyInfo.xcprivacy`).
- ✅ `swift test` — **239 tests / 20 suites green.**
- ✅ iOS **Release** build green · macOS build green (both re-verified after the
  widget change)
- ✅ No tracking / analytics / third-party SDKs · `ITSAppUsesNonExemptEncryption=false`

## Review access — ✅ solved in-app

Reviewers can't pass Penn SSO, so onboarding's first screen has
**"Just exploring? Preview with sample data."** In v2.5 that demo now covers
every screen, not just the dashboard:

- Settings → Classes lists the sample courses (was empty).
- The full grade report, projections, and target planner all work.
- **Grade Watcher shows real grade cards** computed by the real engine from
  bundled fixture snapshots — weighted and points-mode courses, drop rules,
  extra credit, pending grading, and the estimated-GPA term summary.
- The demo no longer offers "Reconnect Canvas," which used to eject a reviewer
  out of preview mode and into the SSO wall they cannot pass.

Regression-tested in `PreviewModeTests` (6 tests), including the bug where
entering preview mode only seeded on the *next* launch.

## Before you can upload — 🟡 you

- 🟡 **Confirm who publishes.** Signing uses **Team `24A3TDB277`** (Olisa's).
  The App Store Connect app record has to be created under that same team, so
  agree explicitly whose account owns the listing.
- 🟡 **Register in App Store Connect → Identifiers**, all under that team:
  - `com.lhf.lowhangingfruit` (app)
  - `com.lhf.lowhangingfruit.widget` (widget)
  - App Group `group.com.lhf.lowhangingfruit`, **with the App Groups capability
    enabled on both App IDs** — if the distribution profile lacks it, the
    widget's container URL is nil in the shipped build and the widget shows its
    empty state forever.
- 🟡 **Host the privacy policy** publicly and paste the URL into App Store
  Connect. `docs/PRIVACY.md` is rewritten (grades, Keychain sessions, syllabus
  reading, the widget, Gradescope). **Fill in the contact email at the bottom
  before publishing.**
- 🟡 **Support URL** — any public page (can be the same site).
- 🟡 **Verify grades on a real device.** Reconnect Canvas on your iPhone and
  confirm Grade Watcher and submission auto-detection against real data. This
  is the one thing in this list that can't be checked from the repo, and it
  covers the headline feature.
- 🟡 **Verify dark mode on device** now that the Info.plist pin is gone.
- 🟡 **Verify the widget on device** now that it actually builds in.

## App Store Connect metadata — ⬜ (copy is written in LISTING.md)

- ⬜ Name, subtitle, description, keywords, promo text → from `LISTING.md`
- ⬜ Category: Education / Productivity · Age rating: 4+
- ⬜ **App Privacy:** answer **"No, we do not collect data"** (see LISTING.md)
- ⬜ **Content rights:** the app displays third-party content (your own Canvas
  and Gradescope data) — answer yes and see the Gradescope note in
  `REVIEW_NOTES.md`
- ⬜ Upload the **screenshots** (6.9") from `screenshots/` — regenerated
  2026-07-26 against the current UI, now 7 shots including **Grades** and the
  **full grade report**. Two still need capturing by hand (the script prints a
  reminder): a **dark mode** shot and the **widget** on the Home Screen.
- ⬜ Paste **App Review notes** → from `REVIEW_NOTES.md` (add a contact name/email)
- ⬜ Re-record and attach the **demo video** → `DEMO_VIDEO.md` (the old script is
  1.0-era and shows a progress ring that no longer exists)

## Archive & upload — ⬜

```sh
xcodegen generate
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/LHF.xcarchive -allowProvisioningUpdates archive

xcodebuild -exportArchive -archivePath build/LHF.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist
```

- ⬜ Validate in Organizer → Distribute App → App Store Connect
- ⬜ TestFlight smoke test on a real device: onboarding → login → dashboard →
  grades → widget → reminders
- ⬜ Submit for review

## Open decision — Gradescope

v2.5 ships Gradescope scraping with replayed login cookies, and Gradescope
(Turnitin) has no student API. Guideline **5.2.2** asks for authorization to use
a third party's service. The prepared position is in `REVIEW_NOTES.md`: the user
signs in with their own credentials to their own account, everything is
processed on-device, nothing is republished, and no other user's content is
touched.

If you'd rather not spend a review cycle on that argument, the alternative is to
cut Gradescope from this submission and ship it in the next one — the codebase
already treats it as an optional overlay, so it's a UI-gating change, not a
rewrite.
