# App Store listing — copy & metadata

_Last updated: 2026-09-15. Rewritten for **3.0.0**: the product is now named
**Smooth** (display name and copy only — the bundle id stays
`com.lhf.lowhangingfruit`, and internal names such as module names,
app-group names, and defaults keys keep their LHF spelling). **Grade Watcher
is visible again** (`FeatureFlags.gradeWatcher = true`), so the grades copy
scrubbed out for 2.0.0 is restored below. The version jumps straight to
**3.0.0** to end the 2.x confusion: every 2.0.0/2.0.1 build was uploaded to
App Store Connect but never released, so the live App Store listing is still
**1.2.1** and still carries copy for the old name and the old feature set —
**every section below has to be re-pasted, not just What's New.**_

Fill these into App Store Connect. Character limits noted; all copy below is
within limits.

## Identity

- **App name** (≤30): `Smooth`
- **Subtitle** (≤30): `Your next deadline, first`
- **Bundle ID:** `com.lhf.lowhangingfruit`
- **Primary category:** Education
- **Secondary category:** Productivity
- **Age rating:** 4+

## Promotional text (≤170, editable anytime)

Every Canvas deadline in one calm list, soonest first — now with your real
grades, answers to questions about your classes, and a dark mode worth
staying up for. (159)

## Description

There's more to life than school. Smooth is for the rest of it.

Every deadline your classes throw at you — assignments, readings, quizzes,
labs, the lecture you keep forgetting — lands in one calm list, soonest
first. You open it, you see what's next, you close it. That's the whole idea.

Connect Canvas once and Smooth fills itself in: what's due, when, for which
class, colored so a glance is enough. Swipe to check something off. Anything
you've already submitted on Canvas files itself away without you touching it.

NOT JUST PROBLEM SETS
A week of school isn't only things you upload. Smooth picks up readings, class
sessions, and everything else on your Canvas calendar — including readings a
professor buries in the Modules page — and tags anything you don't hand in
with a plain "nothing to submit," so you always know whether a deadline wants
a file or just you. Those never turn red for being late. They just pass.

YOUR CLASSES, YOUR RULES
Rename a class, hide one, give each its own reminder times, or silence the
readings while keeping the reminders that matter. When the term ends, archive
it in a tap — nothing is deleted, and Done keeps the whole record of what you
got through.

KNOW WHERE YOU STAND
Grade Watcher reads your Canvas grades and regroups them into your syllabus's
own categories, not whatever the assignment groups happen to be called — and
you can fix the map if it guesses wrong. It also tells you how much of your
grade is actually decided so far, which is usually the number you wanted: it's
the difference between a bad week and a bad semester.

JUST ASK
"When's my next exam?" "What's the late policy in 2400?" Ask in plain English
on the tree and get an answer out of your own course material — syllabus,
pages, assignment instructions, announcements. An AI model writes the answer;
offline or over the daily limit, Smooth answers from what's already on your
phone instead.

FEATURES
• One chronological list of everything due, sorted by what's next
• Urgency colors at a glance — overdue, today, this week, later
• This Week / All / Done views
• Readings and class sessions from Canvas — calendar and Modules — with a clear
  "nothing to submit" label
• Swipe to complete; tap a card for details
• Home Screen and Lock Screen widget showing what's due next
• Per-class notification controls: reminder times, mute, and an
  "items with nothing to submit" switch
• Add your own one-off or weekly-recurring tasks
• Optional local reminders before each due date
• Grade Watcher: grades regrouped by your syllabus's categories, with what
  share of your grade is decided so far
• Ask questions about your classes in plain English on "the tree"
• Announcement Watcher: turns a Canvas announcement into a task, with an
  optional AI assist (on by default, switch it off anytime in Settings)
• Semester rollover: archive last term's classes without losing your history
• Light and dark appearance, including a full after-sunset dark mode
• Adjust any due date by hand when your professor moves it

PRIVATE BY DESIGN
Your grades, your work, your name, and your Canvas and Gradescope logins stay
on your phone. Smooth talks to your school's Canvas, to Gradescope if you
connect it, and to one small server of ours. That server does two things:
it pools the course material everyone in a class can already see — syllabi,
pages, assignment instructions, announcements — so a classmate who installs
tomorrow gets the class instantly, and it answers what you ask on the tree.
Nothing personal goes into that pool. Questions and answers aren't kept. No
tracking, no ads, no third-party SDKs, and a button in Settings that deletes
your account from our server whenever you want.

Smooth is an independent app and is not affiliated with or endorsed by
Instructure (Canvas), Turnitin (Gradescope), or any university.

## What's New in 3.0.0 (release notes, ≤4000)

Smooth is the new name for this app (it was Low Hanging Fruit) — and this is
the biggest update yet.

• New name, new look: the whole app has been redesigned, including a full
  after-sunset dark mode
• Grade Watcher is back: see each class's grade regrouped into your
  syllabus's own categories, and how much of your grade is decided so far
  this semester
• Ask questions about your classes in plain English on the new "the tree"
  screen and get answers pulled from your own synced course material
• Announcement Watcher can now use AI to help decide whether a Canvas
  announcement is actually a task — on by default, with an off switch in
  Settings
• Course material (syllabi, pages, assignment descriptions, announcements) is
  now shared automatically among classmates in the same Canvas course, so a
  new student gets it instantly instead of waiting on their own first fetch
• A rebuilt first-run intro
• Grades, completions, and your Canvas/Gradescope logins still never leave
  your device — see "Private by design" above

## What's New in 2.0.1 (never released — kept for reference only)

**Do not paste this or the 2.0.0 notes below.** Both versions were uploaded to
App Store Connect and neither was ever released, so no student has seen either
set of notes. 3.0.0 lands on top of the live 1.2.1 and its notes above are the
only ones to paste.

Two fixes for work you've already turned in:

• If your Canvas login lapses, LHF now tells you and offers a one-tap
  reconnect — before, submitted work could silently stop filing itself away
• Classes with more than one Canvas site (a lecture site plus a section
  site) are now checked in full, so submissions in either site file
  themselves under Done
• "Nothing to submit" labels and auto-filing recover as soon as you
  reconnect

## What's New in 2.0.0 (release notes, ≤4000)

LHF 2.0 is a big one — a redesigned app that finally treats your whole course
load, not just the assignments.

• Redesigned cards: swipe to complete, tap for details
• Readings and class sessions now show alongside assignments — including
  readings your professor posts only to the Modules page
• A clear "nothing to submit" label on anything that doesn't need a file —
  and those items never show up as "late"
• New Profile screen: every class in one place — rename, hide, or archive
• Per-class notification controls: pick reminder times per class, mute a
  class, or silence just its readings and attend-only work
• Semester rollover: when a term ends, archive it in one tap and keep your
  history in Done
• Quiet classes that post nothing to the calendar now show up properly
• Countless fixes to keep completed and submitted work exactly where it
  belongs

## Keywords (≤100, comma-separated, no spaces)

canvas,assignments,deadlines,homework,grades,planner,student,college,readings,reminders,assistant

<!-- 97 characters, within the 100-char limit. -->

## URLs

- **Support URL:** [REQUIRED — e.g. a simple GitHub Pages or Notion page]
- **Marketing URL:** [optional]
- **Privacy Policy URL:** [REQUIRED — host docs/PRIVACY.md publicly; see CHECKLIST.md]

## App Privacy ("nutrition label") answers

When prompted in App Store Connect → App Privacy, this app now collects data:

- **User ID** — linked to the user, used for App Functionality (the anonymous
  backend account that scopes enrollment and quota; not used for tracking).
- **Other User Content** — linked to the user, used for App Functionality
  (pooled Canvas course material — syllabi, pages, assignment descriptions,
  announcements — uploaded from the student's own Canvas session; not used for
  tracking).

No data type is used for tracking, and there is no third-party advertising or
analytics SDK. Grades, completions, the work list, the student's name, and
login credentials are not collected — they never leave the device. This is
consistent with the bundled `PrivacyInfo.xcprivacy` files (app and widget) and
with `docs/PRIVACY.md`. See `REVIEW_NOTES.md` → "Backend" for the full
description.

## Content rights

The app displays the user's own content from third-party services (Canvas,
optionally Gradescope), accessed with the user's own credentials. See
`REVIEW_NOTES.md` for the position on Guideline 5.2.2.

## Export compliance

- Uses non-exempt encryption? → **No** (already declared via
  `ITSAppUsesNonExemptEncryption = false` in Info.plist; no extra step needed).

## Build / version

- Marketing version: **3.0.0**
- Build: **8** (must exceed the live **1.2.1** — it does; every 2.0.0/2.0.1
  build was uploaded but never released, so 1.2.1 is still the version App
  Review and App Store Connect compare against. It is 8 rather than 7
  because a build 7 already went up to App Store Connect: ASC refuses a
  build number it has seen before, whatever became of that upload.)
- The widget target's `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` must match
  the app's or validation fails. Both are stamped from `project.yml` and are
  already 3.0.0 / 7 in the committed project.
