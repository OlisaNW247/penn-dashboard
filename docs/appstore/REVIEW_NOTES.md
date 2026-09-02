# App Review notes — paste into App Store Connect → App Review Information → Notes

_Last updated: 2026-08-27 (2.0.0). Add a contact name and email before pasting._

_Grade Watcher and syllabus import are **hidden in this release**
(`FeatureFlags.gradeWatcher = false`), so unlike the v2.5-era version of this
file, nothing below points a reviewer at a grades screen. If the flag comes
back on, the old walkthrough is in git history._

**App:** Low Hanging Fruit (LHF)
**What it is:** A personal academic dashboard for university students. It reads
the student's own Canvas deadlines — assignments, readings, and class
sessions — and shows them as one chronological "what's due next" list, with
local reminders and per-class notification settings. Everything runs on the
device; we operate no server.

---

## ✅ How to review without a school login — tap "Preview with sample data"

Sign-in uses the **University of Pennsylvania's own Canvas login (PennKey single
sign-on)**, so we cannot issue test credentials — PennKey accounts are
institutional and only the university can create them. **You do not need one to
review the app.**

On the **first screen**, tap **"Just exploring? Preview with sample data"** (the
link just below the "Connect Canvas" card). This loads a fully-populated demo
with no account and no network access.

**Everything in the app is reachable from the demo:**

1. **Dashboard** — sample items across **This week / All / Done**, colored by
   urgency. Swipe a card to complete it; tap it for details. Items with
   nothing to turn in (readings, class sessions, attend-only assignments)
   carry a "nothing to submit" label.
2. **Profile** — the person icon in the header: the class list (rename, hide,
   or archive a class) and per-class notification settings (reminder times,
   mute, and the "items with nothing to submit" switch).
3. **Settings** — the gear icon: appearance (light/dark), reminders and the
   daily digest, storage, and account connections.
4. **Widget** — add the "Next Due" widget to the Home or Lock Screen.

The attached screen recording additionally shows the real Canvas login flow
end-to-end.

## What the app does, step by step

1. **Onboarding:** the user enters a first name and taps "Connect Canvas."
2. **Canvas login:** the school's real Canvas login page loads in a web view. The
   user signs in with their own credentials. The app never sees or stores the
   password.
3. **Feed capture:** after login the app reads the user's personal Canvas
   *calendar feed* URL (an iCalendar/.ics link Canvas generates per user) and
   fetches their deadlines from it.
4. **Readings (optional):** for a class that posts readings only to its Canvas
   Modules page, the app fetches those readings using the user's own logged-in
   session, so they appear in the same list.
5. **Dashboard:** deadlines sorted by urgency. Swiping a card marks it done.
   Work already submitted on Canvas is filed automatically — the app checks the
   user's own submission status through their own session.
6. **Reminders (optional):** local notifications before each due date, with
   per-class settings. No remote/push notifications.

## Data, privacy, and networking

- **No backend of ours.** The app talks only to the user's school Canvas
  (`canvas.upenn.edu`) and, if the user connects it, `gradescope.com`. We operate
  no server and receive no user data.
- **Everything is stored on-device.** Assignments, completions, reminder
  settings, and self-created tasks live in local storage. Login session cookies
  are stored in the **iOS Keychain**, encrypted at rest and marked
  this-device-only.
- **No analytics, tracking, ads, or third-party SDKs.** Privacy manifests are
  bundled in both the app and the widget declaring no tracking and no collected
  data.
- **Sign-out:** Settings → Account has **Disconnect Canvas** and **Disconnect
  Gradescope**, which erase the stored session for that service. There is no
  account to delete — the app never creates one.

## Third-party services (Guideline 5.2.2)

LHF is a client for services the **user already has an account with**, using the
**user's own credentials**, to display the **user's own data**:

- The user authenticates directly with Canvas and Gradescope through those
  services' own login pages, rendered in a web view. LHF never handles or stores
  passwords.
- The app reads only data belonging to the signed-in student — their own
  deadlines, their own readings, their own submission status. It cannot access
  any other user's content.
- All processing happens on the device. Nothing is re-hosted, republished,
  redistributed, or shown to anyone but the student whose account it is.
- Canvas's developer API program is not open to us at this institution, so
  assignment data comes from the student's own personal calendar feed URL, a
  standard iCalendar link Canvas generates for each user to consume in outside
  apps. Readings and submission status use the student's own authenticated
  session.
- No third-party branding is used, and the app states in its description and in
  this submission that it is independent and unaffiliated with Instructure
  (Canvas), Turnitin (Gradescope), or any university.

Happy to answer any questions or make changes here — contact below.

## Notifications

Local only (`UNUserNotificationCenter`). The permission prompt appears only when
the user turns reminders on in Settings — not at launch.

## Technical notes

- SwiftUI; iPhone; iOS 17+; includes a WidgetKit extension and an App Group used
  to pass the "next due" snapshot and shared preferences to the widget.
- `WKWebView` is used solely to present Canvas's and Gradescope's own login pages.
- No use of non-exempt encryption (`ITSAppUsesNonExemptEncryption = false`).

**Contact:** _<add name and email>_
