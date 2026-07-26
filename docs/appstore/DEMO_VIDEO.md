# Demo / App-Review video — script + how to record

_Last updated: 2026-07-26 (v2.5). The 1.0 script is superseded — it showed a
weekly progress ring that no longer exists on the dashboard._

This is the screen recording you'll attach to App Review (and can trim into an
App Preview later). Target length **50–85 seconds**. Record on the **iPhone 17
Pro Max** simulator (6.9", the size the App Store requires) for a clean frame.

## Why a video

App Review can't sign in (Penn SSO — see REVIEW_NOTES.md). The **in-app preview
mode is the primary review path**; this recording is supporting evidence that
shows the real login working end to end.

---

## Shot list (scene · ~seconds · what to show · on-screen caption)

1. **Launch / onboarding** · 0:00–0:07
   App opens to the welcome screen. Type a first name, tap **Connect Canvas**.
   *Caption: "Sign in once with your school Canvas."*

2. **Canvas login (real)** · 0:07–0:14
   The school's Canvas login page loads in the app. Enter credentials and submit.
   *(Blur/scrub the password field in post.)*
   *Caption: "We never see your password."*

3. **Dashboard fills in — This Week** · 0:14–0:24
   The list populates, sorted by urgency. Slowly scroll. Point out the colored
   spines (red overdue → amber today → blue soon → green later).
   *Caption: "Everything due, sorted by what's next."*

4. **Complete an item** · 0:24–0:30
   Tap a card. It animates out into Done.
   *Caption: "Tap to check it off — or let Canvas submissions file themselves."*

5. **All / Done tabs** · 0:30–0:37
   Tap **All** (shows later items too), then **Done** (completed, grouped by day).
   *Caption: "This Week · All · Done."*

6. **Grades** · 0:37–0:48
   Tap the chart icon in the header. Show the estimated term GPA, then a class
   card: current grade, the "% of your grade is decided" bar, the week delta and
   sparkline. Expand one card's category breakdown.
   *Caption: "Your real grade — and how much of it is already decided."*

7. **The full report** · 0:48–1:00
   Tap **Full report** on a class. Show floor / at-this-pace / best case, then
   move the target picker and read the "what you'd need" number aloud in the
   caption.
   *Caption: "What you'd need on the rest to land the grade you want."*

8. **Widget + appearance** · 1:00–1:10
   Back out, show the Home Screen widget, then Settings → Appearance → Dark.
   *Caption: "Next due on your Home Screen. Light or dark."*

9. **Reminders** · 1:10–1:20
   Settings → toggle **Due-date reminders**, show lead times and the daily digest.
   *Caption: "Optional local reminders — all on-device."*

10. **Close** · 1:20–1:25
    End on the clean dashboard (or the "Touch Grass" all-clear state).
    *Caption: "Low Hanging Fruit."*

---

## How to record (simulator)

```sh
# 1. Boot the 6.9" device and clean up the status bar (9:41, full battery/signal)
xcrun simctl boot "iPhone 17 Pro Max"
open -a Simulator
xcrun simctl status_bar "iPhone 17 Pro Max" override \
  --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

# 2. Install the DEBUG build (built to build/screenshots — see capture-screenshots.sh)
xcrun simctl install booted \
  build/screenshots/Build/Products/Debug-iphonesimulator/LowHangingFruit.app

# 3a. For the REAL login shots (scenes 1–2): launch with no flags (fresh onboarding)
xcrun simctl launch booted com.lhf.lowhangingfruit

# 3b. For the populated app (scenes 3–10): relaunch with demo data
xcrun simctl terminate booted com.lhf.lowhangingfruit
xcrun simctl launch booted com.lhf.lowhangingfruit -LHFDemoData

# 4. Record (Cmd-R in Simulator, or:)
xcrun simctl io booted recordVideo --codec h264 demo.mov
#   …perform the interactions…  Ctrl-C to stop.
```

> DEBUG launch flags: `-LHFDemoData`, `-LHFTabAll`, `-LHFTabDone`,
> `-LHFShowSettings`, `-LHFShowGrades`, `-LHFShowReport`. These are compiled out
> of release builds — the **reviewer-facing** demo is preview mode, which ships
> in Release and needs no flags.

## Tips

- Record at 1x scale, device bezel off, for a clean App Store frame.
- Keep cursor movements slow and deliberate; pause ~1s on each screen.
- Scene 7 is the one that sells the app — don't rush the target picker.
