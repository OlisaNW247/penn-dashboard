# App Store submission checklist — LHF 1.0.0 (iOS)

Status legend: ✅ done in repo · 🟡 needs you (account / hosting / Apple) · ⬜ to do

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

## Review access — solved with an in-app preview
Reviewers can't pass Penn SSO, so onboarding now has a **"Preview with sample
data"** link (first screen) that loads a populated demo — sample courses across
This week / All / Done, progress ring, working completion + reminders — with no
login and no network. This is the primary review path; the demo video is
supporting evidence. Instructions are in `REVIEW_NOTES.md`. Ships in Release
(the fixtures are no longer DEBUG-gated).
