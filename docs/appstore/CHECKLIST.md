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

## Known review risk (your call — you chose reviewer-notes + video)
Reviewers can't pass Penn SSO. The review notes + video address this, but Apple
sometimes still asks for an in-app demo path. If they push back, I can add an
"Explore with sample data" button to onboarding in ~1–2 hrs (the sample data and
the `-LHFDemoData` seam already exist).
