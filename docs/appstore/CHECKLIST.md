# App Store submission checklist — LHF 1.0.0 (iOS + macOS)

Status legend: ✅ done in repo · 🟡 needs you (account / hosting / Apple) · ⬜ to do

> The iOS submission steps are unchanged and below. The **macOS (native Mac
> App Store) app** is a separate section at the bottom — it ships from the same
> project and shares the bundle id, and all of its build changes are scoped to
> the macOS SDK so **the iPhone app is not altered in any way**.

## Code & build — ✅ done
- ✅ Canvas-only: all Gradescope code stripped from the binary
- ✅ Version reconciled to **1.0.0 / build 1** (single source: `project.yml`)
- ✅ `PrivacyInfo.xcprivacy` added and **verified bundled** in the app
- ✅ Accessibility labels on card actions
- ✅ `swift test` 13/13 green · iOS **Release** build green
- ✅ No tracking / analytics / third-party SDKs · `ITSAppUsesNonExemptEncryption=false`

## Before you can upload — 🟡 you
- 🟡 **Set your Apple Developer Team** in signing.
  Give me your 10-char Team ID and I'll add `DEVELOPMENT_TEAM` to `project.yml`,
  or set it in Xcode → target → Signing & Capabilities (Automatic).
- 🟡 **Register the bundle ID** `com.lhf.lowhangingfruit` (App Store Connect →
  Identifiers) and **create the app record**.
- 🟡 **Host the privacy policy** publicly and paste the URL into App Store Connect.
  `docs/PRIVACY.md` is ready — drop it on GitHub Pages / Notion / any static host.
  Also fill the **contact email** placeholder at the bottom of `docs/PRIVACY.md`.
- 🟡 **Support URL** — any public page (can be the same site as the policy).

## App Store Connect metadata — ⬜ (copy is written in LISTING.md)
- ⬜ Name, subtitle, description, keywords, promo text → from `LISTING.md`
- ⬜ Category: Education / Productivity · Age rating: 4+
- ⬜ **App Privacy:** answer **"No, we do not collect data"** (see LISTING.md)
- ⬜ Upload **screenshots** (6.9") → generated in `docs/appstore/screenshots/`
- ⬜ Paste **App Review notes** → from `REVIEW_NOTES.md` (add a contact name/email)
- ⬜ Attach the **demo video** → record per `DEMO_VIDEO.md`

## Archive & upload — ⬜ (needs Team ID first)
```sh
# From repo root, once signing is set:
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/LHF.xcarchive archive

xcodebuild -exportArchive -archivePath build/LHF.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist
# then upload build/export/*.ipa via Transporter, or use Xcode Organizer.
```
- ⬜ Validate in Organizer → Distribute App → App Store Connect
- ⬜ TestFlight smoke test on a real device (verify the login → dashboard →
     reminder-permission flow once on device)
- ⬜ Submit for review

## macOS (native Mac App Store app)

The macOS build already exists — the UI was written for Mac first, and the app
still targets macOS (`supportedDestinations: [iOS, macOS]`, deployment target
14.0). These are the only things needed to ship it, and **none of them change
the iPhone app** (the entitlements change is scoped to `[sdk=macosx*]`).

### Code & build — ✅ done in repo
- ✅ **App Sandbox** for the Mac App Store: `App/LHFApp-macOS.entitlements`
  (sandbox + `network.client` only — no file/camera/location access), wired in
  `project.yml` as `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`. The iOS entitlements
  (`App/LHFApp.entitlements`) are untouched.
- ✅ The widget stays iOS-only (`platforms: [iOS]`), so the Mac build simply
  omits it — nothing to configure there.

### Before you can upload — 🟡 you
- 🟡 **macOS app icon.** The asset catalog currently has only the 1024px icon
  (iOS). Generate the macOS sizes **on your Mac** (has `sips` built in) — this
  touches only the icon set, not the iPhone icon config:
  ```sh
  cd App/Assets.xcassets/AppIcon.appiconset
  for s in 16 32 64 128 256 512; do
    sips -z $s $s   icon-1024.png --out mac-$s.png
    sips -z $((s*2)) $((s*2)) icon-1024.png --out mac-${s}@2x.png
  done
  ```
  Then in Xcode's asset catalog, drag each into the matching **Mac** icon slot
  (16pt…512pt, 1x/2x). Alternatively add a separate `AppIcon-macOS` set and set
  `ASSETCATALOG_COMPILER_APPICON_NAME[sdk=macosx*]` — either keeps the iOS icon
  as-is.
- 🟡 **Add macOS to the app record.** In App Store Connect, the existing
  `com.lhf.lowhangingfruit` app can offer a **macOS** version under the same
  record (same bundle id) — enable the macOS platform there.
- 🟡 **App Category** (Mac App Store shows one): set it on the macOS target in
  Xcode → General → App Category (Productivity or Education), or in App Store
  Connect. Left out of the shared Info.plist on purpose so the iPhone plist
  isn't touched.
- 🟡 Same **Team ID** and privacy-policy / support URLs as iOS (shared).

### Archive & upload — ⬜ (needs Team ID + icon first)
```sh
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/LHF-mac.xcarchive archive
# Then Xcode Organizer → Distribute App → App Store Connect (Mac App Store).
```
- ⬜ Validate + upload the macOS archive in Organizer
- ⬜ Verify the login → dashboard → reminders flow once on a Mac (the sandbox
     allows outbound network + the WebView logins; nothing else is needed)
- ⬜ The **Preview with sample data** review path works on Mac too (same code)

## Review access — solved with an in-app preview
Reviewers can't pass Penn SSO, so onboarding now has a **"Preview with sample
data"** link (first screen) that loads a populated demo — sample courses across
This week / All / Done, progress ring, working completion + reminders — with no
login and no network. This is the primary review path; the demo video is
supporting evidence. Instructions are in `REVIEW_NOTES.md`. Ships in Release
(the fixtures are no longer DEBUG-gated).
