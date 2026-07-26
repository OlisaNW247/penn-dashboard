# App Store listing — copy & metadata

_Last updated: 2026-07-26. Rewritten for v2.5: grades, widget, dark mode._

Fill these into App Store Connect. Character limits noted; all copy below is
within limits.

## Identity

- **App name** (≤30): `Low Hanging Fruit`
- **Subtitle** (≤30): `Your next deadline, first`
- **Bundle ID:** `com.lhf.lowhangingfruit`
- **Primary category:** Education
- **Secondary category:** Productivity
- **Age rating:** 4+

## Promotional text (≤170, editable anytime)

Every Canvas deadline in one calm list, sorted so the next thing you should do is
always on top — plus your real grade in every class.

## Description

Low Hanging Fruit (LHF) turns your Canvas deadlines into one clear, calm list —
sorted so the most urgent thing is always on top. No more digging through course
pages to figure out what's actually due next.

Log in once with your school Canvas account and LHF pulls your assignment
deadlines straight from your personal Canvas calendar. Each item shows when it's
due, color-coded by urgency. Tap to check it off — and work you've already
submitted on Canvas files itself away automatically.

KNOW WHERE YOU STAND
Grade Watcher computes your current grade in each class from what's actually
been scored, and shows how much of your final grade is already decided — so a
big number off two quizzes reads as provisional, not final.

FEATURES
• One chronological list of everything due, sorted by what's next
• Urgency colors at a glance — overdue, today, this week, later
• This Week / All / Done views
• Home Screen and Lock Screen widget showing what's due next
• Grade Watcher: current grade, how much is decided, and grade trends
• Add your own one-off or weekly-recurring tasks
• Optional local reminders before each due date, plus a daily digest
• Light and dark appearance
• Adjust any due date by hand when your professor moves it

PRIVATE BY DESIGN
Everything stays on your device. LHF has no account system and no server — it
talks only to your school's Canvas (and Gradescope, if you connect it). We don't
collect, track, or share anything.

Grades shown in LHF are estimates computed from what Canvas exposes. Professors
apply curves, late policies, and cutoffs the app can't see — your official grade
is always the one your school publishes.

LHF is an independent app and is not affiliated with or endorsed by Instructure
(Canvas), Turnitin (Gradescope), or any university.

## Keywords (≤100, comma-separated, no spaces)

canvas,assignments,deadlines,homework,planner,student,college,grades,gpa,due dates

## URLs

- **Support URL:** [REQUIRED — e.g. a simple GitHub Pages or Notion page]
- **Marketing URL:** [optional]
- **Privacy Policy URL:** [REQUIRED — host docs/PRIVACY.md publicly; see CHECKLIST.md]

## App Privacy ("nutrition label") answers

When prompted in App Store Connect → App Privacy:

- **Do you collect data from this app?** → **No, we do not collect data.**

That single answer is the whole label, and it stays correct in v2.5: grades and
sessions are processed and stored on-device only, and the developer receives
nothing. It is consistent with the bundled
`PrivacyInfo.xcprivacy` files (app and widget) and with `docs/PRIVACY.md`. Do not
add any data types.

## Content rights

The app displays the user's own content from third-party services (Canvas,
optionally Gradescope), accessed with the user's own credentials. See
`REVIEW_NOTES.md` for the position on Guideline 5.2.2.

## Export compliance

- Uses non-exempt encryption? → **No** (already declared via
  `ITSAppUsesNonExemptEncryption = false` in Info.plist; no extra step needed).

## Build / version

- Marketing version: **1.0.0**
- Build: **1**
- The widget target's `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` must match
  the app's or validation fails.
