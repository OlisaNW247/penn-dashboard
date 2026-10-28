# App Store listing — copy & metadata

_Last updated: 2026-10-20. Rewritten for **3.1.0** (build 13), going straight
to App Review from `v8`. The product is **Smooth** (display name and copy
only — the bundle id stays `com.lhf.lowhangingfruit`, and internal names such
as module names, app-group names, and defaults keys keep their LHF spelling).
**Grade Watcher is hidden again** (`FeatureFlags.gradeWatcher = false`, since
2026-10-18): there is no grades button and no grades screen, so every grades
claim in the Promotional text, Description and FEATURES has been scrubbed. A
claim or a screenshot of an unexposed feature is a Guideline 2.3.1 rejection,
so check the screenshots in App Store Connect for any grades screen too.
Live on the store is **3.0.0 (11)**, whose copy still carries the grades
claims, so **every section below has to be re-pasted, not just What's New.**_

Fill these into App Store Connect. Character limits noted; all copy below is
within limits.

## Identity

- **App name** (≤30): `Smooth for Students` (19)
- **Subtitle** (≤30): `Your next deadline, first` (25)

> **The store name and the name on the device are different on purpose.**
> This field is the App Store listing only. Three separate settings decide
> what a student actually sees, all of them **`Smooth`** in `project.yml`
> (app and widget), and all of them must stay that way:
> `CFBundleDisplayName` (the iPhone Home Screen, notification banners,
> Settings, the app switcher), `CFBundleName` (the Mac's application menu,
> About box and alerts), and `PRODUCT_NAME` (the .app bundle's file name,
> which is what labels the icon in Finder, Launchpad and the Dock on the
> Mac). Do not "fix" the mismatch with the listing: the longer name exists
> so the listing is findable and unambiguous among other apps called Smooth,
> while the device keeps the short brand. iOS would truncate anything much
> longer than ~12 characters under the icon anyway.
- **Bundle ID:** `com.lhf.lowhangingfruit`
- **Primary category:** Education
- **Secondary category:** Productivity
- **Age rating:** 4+

## Promotional text (≤170, editable anytime)

Every Canvas deadline in one calm list, soonest first — now with an alarm for anything you haven't turned in, and answers to questions about your classes. (154)

## Description

There's more to life than school. Smooth is for the rest of it.

Every deadline your classes throw at you — assignments, readings, quizzes,
labs, the lecture you keep forgetting — lands in one calm list, soonest
first. You open it, you see what's next, you close it. That's the whole idea.

Connect Canvas once and Smooth fills itself in: what's due, when, for which
class, colored so a glance is enough. Swipe to check something off. Anything
you've already submitted on Canvas files itself away without you touching it.

THE SMOOTH SWEEPER
Ten minutes before anything you haven't turned in, Smooth rings. On iOS 26 it's
a real alarm: full screen on the lock screen, through silent mode and Focus,
with "turned in" and Stop buttons, and a live countdown in the Dynamic Island.
Open the app while it rings and Smooth takes the whole screen: "turned in,"
"open in canvas," or "not yet." On older iPhones it's three loud Time
Sensitive notifications with "turned in" and "open in canvas" buttons. It's on
by default, with a switch in Profile.

NOT JUST PROBLEM SETS
A week of school isn't only things you upload. Smooth picks up readings, class
sessions, and everything else on your Canvas calendar — including readings a
professor buries in the Modules page — and tags anything you don't hand in
with a plain "nothing to submit," so you always know whether a deadline wants
a file or just you. Those never turn red for being late. They just pass.

THE MEGAPHONE
Tap it for the past week of announcements from Canvas and Ed Discussion, and
the tasks hiding inside them. Those tasks land on your list as cards too, for
any class where you leave that switched on. Exams named in a syllabus or an
announcement get one black card each, never duplicated.

JUST ASK
"When's my next exam?" "What's the late policy in 2400?" "Anything new on Ed
this week?" Ask in plain English on the tree and get an answer out of your own
course material, with tappable links to its sources. Follow-ups work, and at
Penn it knows where and when each section meets. An AI model writes the
answer; offline or over the daily limit, Smooth answers from what's already on
your phone instead.

FEATURES
• One chronological list of everything due, soonest first
• todo / all / prev views, and a filter by class
• Swipe to complete; tap a card for details, or to open it in Canvas or
  Gradescope
• Add your own one-off or weekly tasks; delete them or stop repeating
• Adjust any due date by hand when your professor moves it
• Per-class reminder times and switches
• Home Screen and Lock Screen widget showing what's due next
• Ed Discussion (Penn): announcements, pinned threads and staff posts feed the
  tree and the megaphone
• Announcement Watcher with an optional AI assist (on by default, off anytime
  in Profile)
• Stays signed in to Canvas at Penn
• Light and dark appearance, including a full after-sunset dark mode

PRIVATE BY DESIGN
Your work, your completions, your name, and your Canvas and Gradescope logins
stay on your phone, and the alarm runs entirely on it. Smooth talks to your
school's Canvas, to Gradescope if you connect it, and to one small server of
ours. That server does two things: it pools the course material everyone in a
class can already see — syllabi, pages, assignment instructions,
announcements, staff posts on Ed Discussion — so a classmate who installs
tomorrow gets the class instantly, and it answers what you ask on the tree.
Nothing personal goes into that pool. Questions and answers aren't kept. No
tracking, no ads, no third-party SDKs, and when you disconnect Canvas, Smooth
deletes your account and its data from our server.

Smooth is an independent app and is not affiliated with or endorsed by
Instructure (Canvas), Turnitin (Gradescope), Ed Discussion, or any university.

_Description: 3,793 characters including line breaks, within the 4,000 limit. The 3.0.0 text said a grades feature and "archive it in a tap" semester rollover; neither is in this build, so both are gone._

## What's New in 3.3.0 (release notes, ≤4000)

Tell us how Smooth is going.

• A short feedback form, one tap from the dashboard or from Profile
• The tree knows what day it is where you are, so "tomorrow" and late-night
  deadlines land on the right day
• The tree reads grading tables in your class pages as tables

## What's New in 3.2.1 (release notes, ≤4000)

The Smooth Sweeper, your way.

• Pick when the Sweeper rings: 5, 10, 15, 20, 30 or 60 minutes before
  anything you haven't turned in
• Pick its sound, and hear it first
• Choose which classes it rings for

## What's New in 3.2.0 (release notes, ≤4000)

Every class in the megaphone, Ed posts that stay put, and a Canvas sign-in
that takes care of itself.

• The megaphone shows every class: the past week plus each class's latest
  post, so a class that posts rarely never disappears
• Class bubbles at the top: tap one class, or a few, to see just their
  announcements and tasks together in one list
• A task found in an announcement leaves once you've turned the real
  assignment in, and a post leaves once what it was about is over
• Ed Discussion (Penn): a class's posts no longer vanish when a sync is
  interrupted
• Canvas sign-in: sign in once and Smooth keeps your Penn login on this
  phone and reconnects by itself; disconnect any time in Profile
• Smooth refreshes Canvas the moment it opens, not minutes later
• "Turned in" is read more carefully, for Gradescope and for assignments
  that share a name

## What's New in 3.1.0 (release notes, ≤4000)

Meet the Smooth Sweeper, and a lot of smaller things that make the list
smarter.

• The Smooth Sweeper: 10 minutes before anything you haven't turned in, Smooth
  rings. On iOS 26 it's a real alarm, full screen on the lock screen and
  through silent mode and Focus, with "turned in" and Stop buttons and a live
  countdown in the Dynamic Island. Open Smooth while it rings and you get a
  full-screen choice: "turned in," "open in canvas," or "not yet." On older
  iPhones it's three loud Time Sensitive notifications with "turned in" and
  "open in canvas" buttons. On by default; the switch is in Profile →
  reminders and on the reminders page of setup
• Exam cards: exams named in a syllabus or an announcement show up as black
  cards, one per exam, never duplicated
• The megaphone moved to the header: Canvas and Ed Discussion announcements
  from the past week, plus the tasks found in them, which also appear as cards
  on your list for classes where that's switched on
• Ed Discussion (Penn): announcements, pinned threads and staff posts from a
  class's Ed board now feed the tree and the megaphone
• The tree is better at finding things: improved search over your course
  material, follow-up questions, tappable source links under answers, "what's
  new" questions, and where and when each section meets (Penn)
• Cards now say "open in canvas" or "open in gradescope"; a due date you edit
  stays edited; delete your own tasks, or stop repeating a weekly one
• Smooth stays signed in to Canvas at Penn more reliably, and the saved-PennKey
  sheet is now "the vault"
• Grade Watcher is taking a break this release
• Your work, completions, name and logins still never leave your device — see
  "Private by design" above

_What's New: about 1,740 characters, within the 4,000 limit._

## What's New in 3.0.0 (live now; kept as history)

The Grade Watcher bullet below is no longer true of the shipping build. Do
not paste this.

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
set of notes. 3.0.0 landed on top of the live 1.2.1; the 3.1.0 notes
above are the only ones to paste now.

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

canvas,assignments,deadlines,homework,alarm,planner,college,syllabus,readings,reminders,exams,due

<!-- 93 of 100. "student" was dropped when the app name became "Smooth for
     Students": Apple already indexes the name, so spending a keyword slot on
     a word that is in it is waste. "syllabus", "gpa" and "due" took the
     freed room. "smooth" is likewise absent on purpose — the name covers
     it. -->

<!-- 97 characters, within the 100-char limit. For 3.1.0 "grades" and
     "gpa" became "alarm" and "exams": Grade Watcher is hidden in this
     build, and a keyword for a feature the app does not show is the same
     2.3.1 metadata risk as a description that claims it. -->

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

The feedback form (3.3.0) does not change these answers: it is a Google
Form opened in Safari, outside the app, and the app sends it nothing.

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

The Smooth Sweeper alarm (new in 3.1.0) plays a bundled recording as its
sound. It is a licensed recording and the owner holds the licence for it. If
App Store Connect's content-rights questions ask about third-party audio,
answer accordingly. (`CLAUDE.md` says the file must come out of any archive
unless it is licensed: confirm the licence is in hand before uploading.)

## Export compliance

- Uses non-exempt encryption? → **No** (already declared via
  `ITSAppUsesNonExemptEncryption = false` in Info.plist; no extra step needed).

## Build / version

- Marketing version: **3.3.0** (2026-10-27; before it 3.2.1 (15), 3.2.0
  (14), 3.1.0 (13))
- Build: **16** (must exceed every build App Store Connect has seen; the
  last uploaded was 15. **Before archiving, confirm in App Store Connect →
  TestFlight → Builds that no build 16 exists**, and pick the next number if
  one does.)
- The widget target's `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` must match
  the app's or validation fails. Both are stamped from `project.yml` and are
  3.3.0 / 16 in `project.yml` and the committed project.
