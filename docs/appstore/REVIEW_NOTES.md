# App Review notes — paste into App Store Connect → App Review Information → Notes

_Last updated: 2026-09-15 (3.0.0, build 8). Add a contact name and email before
pasting._

_The product's user-facing name is now **Smooth** (it was **Low Hanging
Fruit** / **LHF**, and before that **Locust**) — display name and copy only;
the bundle id is still `com.lhf.lowhangingfruit` and internal names keep
their LHF spelling. **Grade Watcher is visible in this build**
(`FeatureFlags.gradeWatcher = true`), unlike the 2.0.0 submission, where it
was hidden and this file said nothing about a grades screen. The walkthrough
below now points a reviewer at it._

**App:** Smooth (bundle id `com.lhf.lowhangingfruit`)
**What it is:** A personal academic dashboard for university students. It reads
the student's own Canvas deadlines — assignments, readings, and class
sessions — and shows them as one chronological "what's due next" list, with
local reminders and per-class notification settings. It also tracks each
class's grades (Grade Watcher) and lets the student ask questions about their
classes in plain English ("the tree"). Grades, completions, and the
student's own work stay on the device. A small backend of ours pools shared,
non-personal course material (syllabi, pages, assignment descriptions,
announcements) per Canvas course and answers optional AI questions; see
"Backend" below.

## Backend

On first launch the app creates an anonymous account with our backend
(Supabase — Postgres plus a few serverless functions): no email, password, or
name, just an id used to scope enrollment and quota. After the student
connects Canvas, the app fetches that class's syllabus, pages, modules,
assignment descriptions, and announcements with the student's own logged-in
session — as it always has — and uploads the extracted text, keyed by Canvas's
own course id, so every student in the same course site shares one copy
instead of each fetching and storing it independently; a new student gets the
course's material instantly. This sync is automatic (after Canvas connect,
then on the existing hourly refresh) — there is no manual sync button and
nothing for the student to type in. Grades, completions, submission state, the
work list, the student's name, and login cookies are never uploaded.
Questions asked in "the tree" (the in-app ask screen) are sent to the backend
along with on-device dashboard context and matched course-material excerpts,
answered by an AI model reached through OpenRouter with its data-collection
denied, and neither the question nor the answer is stored — only a per-user
daily request count and a token total, to enforce a fair-use limit. The
Announcement Watcher, which reads Canvas course announcements and can offer to
turn one into a task, has an equivalent "AI assist" that sends the
announcement's text through the same backend/AI path to help judge whether it
describes a task; it is **on by default**, and the student can turn it off in
Settings, after which the Announcement Watcher falls back to an on-device-only
check. Offline, over the daily limit, or if the backend is unreachable, both
"the tree" and the Announcement Watcher's assist answer from what the app
already has on-device, exactly as before. Settings has a button to delete
the student's enrollment records, usage counters, and anonymous account from
the server at any time; the shared course material itself is not deleted,
because it isn't the deleting student's data — it's the same course content
every enrolled student already sees on Canvas. This also means App Privacy
("nutrition label") answers change from "we do not collect data" to: **Data
linked to user** — User ID (app functionality), and **User Content: other user
content** — the pooled course materials (app functionality). None of it is
used for tracking. In short, for a reviewer checking this at a glance: there
is a server; an AI model (not us) answers questions asked in "the tree" and
assists the Announcement Watcher; and grades, credentials, and any other
personal data never leave the device.

---

## Sign-in and review access

Sign-in uses the **University of Pennsylvania's own Canvas login (PennKey single
sign-on)**. We cannot issue test/demo credentials for this: PennKey accounts
are institutional, issued only by the university to its own students, staff,
and faculty, and there is no mechanism for a third party (including us) to
create one for a reviewer.

**There is no sample-data or preview mode in this build.** An earlier build
of this app had an in-app "preview with sample data" path that let someone
explore a populated demo without signing in; it has been removed at the
product owner's instruction, and every screen in the app now requires a real
Canvas sign-in to show anything. We are aware this means App Review has no
way to authenticate into the app and may not be able to complete a full
functional review under Guideline 2.1 as a result. We do not have a
workaround to offer beyond what's described below.

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
6. **Grades (optional):** Grade Watcher reads the student's own Canvas grades
   through the same session and regroups them into syllabus categories, which
   the student can edit.
7. **Reminders (optional):** local notifications before each due date, with
   per-class settings. No remote/push notifications.

## Data, privacy, and networking

- **The app talks to the user's school Canvas** (`canvas.upenn.edu`), to
  `gradescope.com` if the user connects it, and to our own small backend
  (Supabase) for course-material pooling and the optional AI-answered
  questions described above. See "Backend."
- **Grades, completions, work list, and identity stay on-device.**
  Assignments, completions, grade observations, reminder settings,
  self-created tasks, and the student's name live in local storage and are
  never uploaded. Login session cookies are stored in the **iOS Keychain**,
  encrypted at rest and marked this-device-only, and are also never uploaded.
- **No analytics, tracking, ads, or third-party SDKs.** Privacy manifests are
  bundled in both the app and the widget; the backend does not add tracking —
  see the updated data-type answers under "Backend" above.
- **Sign-out:** Settings → Account has **Disconnect Canvas** and **Disconnect
  Gradescope**, which erase the stored session for that service. Settings also
  has **Delete my class data from Smooth's server**, which removes the
  backend's anonymous account and its enrollment/usage rows.

## Third-party services (Guideline 5.2.2)

Smooth is a client for services the **user already has an account with**, using
the **user's own credentials**, to display the **user's own data**:

- The user authenticates directly with Canvas and Gradescope through those
  services' own login pages, rendered in a web view. Smooth never handles or
  stores passwords.
- The app reads only data belonging to the signed-in student — their own
  deadlines, their own readings, their own submission status, their own
  grades. It cannot access any other user's content.
- All processing happens on the device, other than the pooled course
  material and optional AI answers described in "Backend" — neither of which
  contains anything personal to the student. Nothing is re-hosted,
  republished, redistributed, or shown to anyone but the student whose
  account it is (and, for pooled course material, classmates already
  enrolled in that same Canvas course).
- Canvas's developer API program is not open to us at this institution, so
  assignment data comes from the student's own personal calendar feed URL, a
  standard iCalendar link Canvas generates for each user to consume in outside
  apps. Readings, submission status, and grades use the student's own
  authenticated session.
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
