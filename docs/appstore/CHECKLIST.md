# App Store submission checklist — LHF 1.0.0 (iOS)

Status legend: ✅ done in repo · 🟡 needs you (account / hosting / Apple) · ⬜ to do

## Code & build — ✅ done
- ✅ Canvas-only: all Gradescope code stripped from the binary
- ✅ Version reconciled to **1.0.0 / build 1** (single source: `project.yml`)
- ✅ `PrivacyInfo.xcprivacy` added and **verified bundled** in the app
- ✅ Accessibility labels on card actions
- ✅ **"Explore with sample data"** demo path in onboarding (see review risk below)
- ✅ No tracking / analytics / third-party SDKs · `ITSAppUsesNonExemptEncryption=false`
- 🟡 Re-run on a Mac after the demo-path change: `cd LowHangingFruitKit && swift test`
  (13 prior tests + 8 new `DemoModeTests`) and an iOS **Release** build. Both were
  green before the change; it was authored on Linux, where no Swift toolchain runs.

## Screenshots — 🟡 one to regenerate
`1-onboarding.png` predates the "Explore with sample data" button, so the first
screenshot no longer matches the app. Regenerate it (the dashboard shots are
unaffected — the demo banner is suppressed under the `-LHFDemoData` seam):

```sh
bash docs/appstore/capture-screenshots.sh
```

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

## Known review risk — ✅ addressed
Reviewers can't pass Penn SSO. Onboarding now ships an **"Explore with sample
data"** button that opens the full dashboard on bundled examples — no login, no
network, nothing persisted — so App Review has a working in-app path without a
PennKey. The review notes lead with it. The demo is in-memory only: quitting
returns to the connect screen, and no demo item, completion, or reminder is ever
written to disk.
