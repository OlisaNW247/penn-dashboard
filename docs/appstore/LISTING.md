# App Store listing — copy & metadata

_Last updated: 2026-07-26. Rewritten for the 1.0 submission: widget, dark mode,
automatic submission filing. Grade Watcher is gated off in this build — see
FeatureFlags.swift — so no grade copy appears here._

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
always on top. Work you've already turned in files itself away.

## Description

Low Hanging Fruit (LHF) turns your Canvas deadlines into one clear, calm list —
sorted so the most urgent thing is always on top. No more digging through course
pages to figure out what's actually due next.

Log in once with your school Canvas account and LHF pulls your assignment
deadlines straight from your personal Canvas calendar. Each item shows when it's
due, color-coded by urgency. Tap to check it off — and work you've already
submitted on Canvas files itself away automatically.

FEATURES
• One chronological list of everything due, sorted by what's next
• Urgency colors at a glance — overdue, today, this week, later
• This Week / All / Done views
• Home Screen and Lock Screen widget showing what's due next
• Work you've already submitted on Canvas files itself under Done
• Add your own one-off or weekly-recurring tasks
• Optional local reminders before each due date, plus a daily digest
• Light and dark appearance
• Adjust any due date by hand when your professor moves it

PRIVATE BY DESIGN
Everything stays on your device. LHF has no account system and no server — it
talks only to your school's Canvas (and Gradescope, if you connect it). We don't
collect, track, or share anything.

LHF is an independent app and is not affiliated with or endorsed by Instructure
(Canvas), Turnitin (Gradescope), or any university.

## Keywords (≤100, comma-separated, no spaces)

canvas,assignments,deadlines,homework,planner,student,college,due dates,reminders,school

## URLs

- **Support URL:** [REQUIRED — e.g. a simple GitHub Pages or Notion page]
- **Marketing URL:** [optional]
- **Privacy Policy URL:** [REQUIRED — host docs/PRIVACY.md publicly; see CHECKLIST.md]

## App Privacy ("nutrition label") answers

When prompted in App Store Connect → App Privacy:

- **Do you collect data from this app?** → **No, we do not collect data.**

That single answer is the whole label, and it stays correct: everything the app
reads from Canvas — including the submission data behind automatic filing — is
processed and stored on-device only, and the developer receives nothing. It is consistent with the bundled
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
