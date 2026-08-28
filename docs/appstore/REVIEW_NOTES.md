# App Review notes — paste into App Store Connect → App Review Information → Notes

**App:** Low Hanging Fruit (LHF)
**What it is:** A personal academic dashboard for University of Pennsylvania
students. It reads the student's own Canvas assignment deadlines and shows them
as one chronological "what's due next" list, with local reminders.

---

## ✅ How to review the app without an account

**On the first screen, tap "Explore with sample data."** That opens the full
dashboard on built-in example assignments — no login, no account, no network.
Everything is reviewable from there: the urgency-sorted list, This week / All /
Done, tapping a card to complete it, the weekly progress ring, adjusting a due
date, adding your own task with "+", and the Settings screen. A banner at the
top of the dashboard marks it as sample data, and "Connect" in that banner
returns to the sign-in screen. Nothing in the demo is saved to the device.

**Why there is no test account:** sign-in is handled entirely by the
**University of Pennsylvania's own Canvas login page** (Penn single sign-on /
PennKey), shown inside the app in a web view. We do **not** run an
authentication system and **cannot issue test credentials** — PennKey accounts
are institutional and only the university can create them. There is no
email/password we can give you.

The attached screen recording additionally shows the real end-to-end flow
(onboarding → Canvas login → populated dashboard → completing items →
reminders → adding tasks) with a real student account.

## What the app does, step by step
0. **Optional demo:** "Explore with sample data" on the first screen opens the
   dashboard on bundled examples, with no account and no network access.
1. **Onboarding:** the user enters a first name and taps "Connect Canvas."
2. **Canvas login:** Penn's real Canvas login page loads in a web view. The user
   signs in with their own PennKey. The app never sees or stores the password.
3. **Feed capture:** after login, the app reads the user's personal Canvas
   *calendar feed* URL (an iCalendar/.ics link Canvas generates per user) and
   fetches their assignment deadlines from it.
4. **Dashboard:** deadlines are shown sorted by urgency. Tapping a card marks it
   done; a weekly progress ring fills. Users can also add their own one-off or
   weekly-recurring tasks.
5. **Reminders (optional):** if enabled, the app schedules **local**
   notifications before each due date. No remote/push notifications.

## Data, privacy, and networking
- **No backend of ours.** The app talks only to `canvas.upenn.edu`. We operate
  no server and receive no user data.
- **Everything is stored on-device** (the user's name, the captured calendar-feed
  URL, completed/edited items, reminder settings, and self-created tasks live in
  local storage only).
- **No analytics, tracking, ads, or third-party SDKs.** A Privacy Manifest
  (`PrivacyInfo.xcprivacy`) is included declaring no tracking and no data
  collection; the only required-reason API used is `UserDefaults` (reason CA92.1).
- **Account deletion:** there is no account. Deleting the app removes all data.

## Notifications
Local only (`UNUserNotificationCenter`). The permission prompt appears only when
the user turns reminders on in Settings — not at launch.

## Technical notes
- SwiftUI; iPhone; iOS 17+.
- `WKWebView` is used solely to present Canvas's own login web page.
- No use of non-exempt encryption (`ITSAppUsesNonExemptEncryption = false`).

## Contact
[ADD YOUR REVIEWER-CONTACT NAME / EMAIL / PHONE HERE]
