# Demo / App-Review video — script + how to record

This is the screen recording you'll attach to App Review (and can trim into an
App Preview later). Target length **40–75 seconds**. Record on the **iPhone 17
Pro Max** simulator (6.9", the size the App Store requires) for a clean frame.

## Why a video
App Review can't sign in (Penn SSO — see REVIEW_NOTES.md), so this recording is
how they see full functionality. Show the real login screen briefly to prove
the flow, then the populated app.

---

## Shot list (scene · ~seconds · what to show · on-screen caption)

1. **Launch / onboarding** · 0:00–0:07
   App opens to the welcome screen. Type a first name, tap **Connect Canvas**.
   *Caption: "Sign in once with your school Canvas."*

2. **Canvas login (real)** · 0:07–0:14
   Penn's Canvas login page loads in the app. Enter credentials and submit.
   *(Blur/scrub the password field in post.)*
   *Caption: "We never see your password."*

3. **Dashboard fills in — This Week** · 0:14–0:26
   The list populates, sorted by urgency. Slowly scroll. Point out the colored
   spines (red overdue → amber today → blue soon → green later) and due times.
   *Caption: "Everything due, sorted by what's next."*

4. **Complete an item** · 0:26–0:33
   Tap a card. It animates out and the weekly **progress ring** fills.
   *Caption: "Tap to check it off."*

5. **All / Done tabs** · 0:33–0:42
   Tap **All** (shows later items too), then **Done** (completed, grouped by day).
   *Caption: "This Week · All · Done."*

6. **Add your own task** · 0:42–0:50
   Tap the **+** button, add a one-off task with a due date (mention "Repeats
   weekly" toggle), Add. It appears in the list.
   *Caption: "Add your own tasks too."*

7. **Reminders** · 0:50–0:62
   Open the gear → **Settings**. Toggle **Due-date reminders** on, show the
   lead-time options and the daily digest.
   *Caption: "Optional local reminders — all on-device."*

8. **Close** · 0:62–0:70
   Back to the dashboard. End on the clean list (or the "Touch Grass" all-clear
   state if you complete everything).
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

# 3b. For the populated app (scenes 3–8): relaunch with demo data
xcrun simctl terminate booted com.lhf.lowhangingfruit
xcrun simctl launch booted com.lhf.lowhangingfruit -LHFDemoData

# 4. Record (Cmd-R in Simulator, or:)
xcrun simctl io booted recordVideo --codec h264 demo.mov
#   …perform the interactions…  Ctrl-C to stop.
```

> The `-LHFDemoData` flag (DEBUG builds only) skips onboarding and loads a full
> set of sample assignments so every screen looks alive without needing a real
> login. It is compiled out of release builds.

## Tips
- Record at 1x scale, device bezel off, for a clean App Store frame.
- Keep cursor movements slow and deliberate; pause ~1s on each screen.
- If you want a fully hands-off recording, I can add a UI-test that drives the
  whole flow automatically and records it — ask and I'll wire it up.
