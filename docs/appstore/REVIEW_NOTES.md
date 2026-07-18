# App Review notes — paste into App Store Connect → App Review Information → Notes

**App:** Low Hanging Fruit (LHF)
**What it is:** A personal academic dashboard for University of Pennsylvania
students. It reads the student's own Canvas assignment deadlines and shows them
as one chronological "what's due next" list, with local reminders.

---

## ✅ How to review without a Penn login — tap "Preview with sample data"

Sign-in uses the **University of Pennsylvania's own Canvas login (PennKey single
sign-on)**, so we cannot issue test credentials — PennKey accounts are
institutional and only the university can create them. **You do not need one to
review the app.**

On the **first screen**, tap **"Just exploring? Preview with sample data"**
(the link just below the "Connect Canvas" card). This loads a fully-populated
demo — sample courses and assignments across the **This week / All / Done**
tabs, the weekly progress ring, plus working task-completion and reminders — so
you can exercise the entire app with no account and no network.

The attached screen recording additionally shows the real Canvas login flow
end-to-end (onboarding → PennKey login → populated dashboard → reminders).

## What the app does, step by step
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
