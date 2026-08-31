# App Store submission checklist — LHF 1.0.0 (iOS + macOS)

Status legend: ✅ done in repo · 🟡 needs you (account / hosting / Apple) · ⬜ to do

One app record covers both platforms: the iPhone app and the Mac app share the
bundle ID, version, and listing copy — you upload one iOS build and one macOS
build to the same 1.0.0 version.

## Code & build — ✅ done
- ✅ Canvas-only: all Gradescope code stripped from the binary
- ✅ Version reconciled to **1.0.0 / build 1** (single source: `project.yml`)
- ✅ `PrivacyInfo.xcprivacy` added and **verified bundled** in the app
- ✅ Accessibility labels on card actions
- ✅ `swift test` 13/13 green · iOS **Release** build green
- ✅ No tracking / analytics / third-party SDKs · `ITSAppUsesNonExemptEncryption=false`
- ✅ **macOS App Sandbox** entitlements (`App/LowHangingFruit-macOS.entitlements`:
  sandbox + outgoing network) — required for the Mac App Store
- ✅ **macOS app icon** set (all 10 sizes, native rounded-rect style) in `AppIcon`
- ✅ `LSApplicationCategoryType` (Education) in Info.plist — required for macOS
- ✅ `ExportOptions.plist` added at repo root (shared by both platforms)
- 🟡 **Verify the macOS Release build once in Xcode** (this repo was prepped
  off-Mac; run the LowHangingFruit scheme with My Mac as destination)

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
  (shared by iOS and macOS)
- ⬜ **Add the macOS platform** to the app record (App Store Connect → your app
  → "+" next to the platform list → macOS) and give it the same 1.0.0 version
- ⬜ Category: Education / Productivity · Age rating: 4+
- ⬜ **App Privacy:** answer **"No, we do not collect data"** (see LISTING.md)
- ⬜ Upload **iPhone screenshots** (6.9") → generated in `docs/appstore/screenshots/`
- ⬜ Capture + upload **Mac screenshots** — run the app on your Mac and take
  window screenshots at **2560×1600** (or 1280×800 / 1440×900 / 2880×1800;
  16:10 only). Same 5 shots as the iPhone set work well.
- ⬜ Paste **App Review notes** → from `REVIEW_NOTES.md` (add a contact
  name/email; the notes apply to both platforms)
- ⬜ Attach the **demo video** → record per `DEMO_VIDEO.md`

## Archive & upload — ⬜ (needs Team ID first)

### iOS
```sh
# From repo root, once signing is set:
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/LHF-iOS.xcarchive archive

xcodebuild -exportArchive -archivePath build/LHF-iOS.xcarchive \
  -exportPath build/export-ios -exportOptionsPlist ExportOptions.plist
# then upload build/export-ios/*.ipa via Transporter, or use Xcode Organizer.
```

### macOS
```sh
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/LHF-macOS.xcarchive archive

xcodebuild -exportArchive -archivePath build/LHF-macOS.xcarchive \
  -exportPath build/export-macos -exportOptionsPlist ExportOptions.plist
# then upload build/export-macos/*.pkg via Transporter, or use Xcode Organizer.
```
(Both use the shared `ExportOptions.plist`; on Xcode older than 15.3 change
`app-store-connect` to `app-store` inside it.)

- ⬜ Validate in Organizer → Distribute App → App Store Connect (each archive)
- ⬜ TestFlight smoke test on a real iPhone **and** on your Mac (verify the
     login → dashboard → reminder-permission flow once per platform)
- ⬜ Submit both platforms for review

## Known review risk (your call — you chose reviewer-notes + video)
Reviewers can't pass Penn SSO. The review notes + video address this, but Apple
sometimes still asks for an in-app demo path. If they push back, I can add an
"Explore with sample data" button to onboarding in ~1–2 hrs (the sample data and
the `-LHFDemoData` seam already exist).
