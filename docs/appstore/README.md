# App Store submission package — LHF 1.0.0 (iOS)

Everything needed to submit Low Hanging Fruit to the App Store.

| File | What it's for |
|------|---------------|
| [CHECKLIST.md](CHECKLIST.md) | The end-to-end submission checklist — start here |
| [LISTING.md](LISTING.md) | Name, subtitle, description, keywords, privacy-label answers |
| [REVIEW_NOTES.md](REVIEW_NOTES.md) | Paste into App Store Connect → App Review Information |
| [DEMO_VIDEO.md](DEMO_VIDEO.md) | Shot-by-shot demo/review video script + how to record |
| [screenshots/](screenshots/) | 6.9" iPhone screenshots, ready to upload |

## Screenshots (iPhone 17 Pro Max · 6.9" · 1320×2868)
Generated from the app via the DEBUG `-LHFDemoData` seam (compiled out of release):
1. `1-onboarding.png` — welcome / Connect Canvas
2. `2-dashboard-thisweek.png` — the hero shot: urgency-sorted list + progress ring
3. `3-dashboard-all.png` — All view (includes later items)
4. `4-dashboard-done.png` — Done view, grouped by day
5. `5-settings-reminders.png` — reminders / daily digest

Regenerate anytime: `bash docs/appstore/capture-screenshots.sh`

## Two things only you can finish
1. **Signing** — add your Apple Team ID (see CHECKLIST.md).
2. **Privacy policy URL + contact email** — host `docs/PRIVACY.md` and fill the
   email placeholder.
