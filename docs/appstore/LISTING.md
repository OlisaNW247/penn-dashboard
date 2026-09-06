# App Store listing — copy & metadata

_Last updated: 2026-08-27. Rewritten for **2.0.0**: the v4 redesign, per-class
notification controls, readings/nothing-to-submit handling — and **Grade
Watcher scrubbed out**, because it is hidden in this release
(`FeatureFlags.gradeWatcher = false`, owner's call 2026-08-26) and metadata
that advertises a feature the app doesn't show is an App Review rejection
(Guideline 2.3.1), not a preview of things to come. When the flag flips back
on, the v2.5-era grades copy lives in this file's git history._

Fill these into App Store Connect. Character limits noted; all copy below is
within limits. **The existing 1.1.2 listing on ASC still carries the old copy —
every section below has to be re-pasted, not just What's New.**

## Identity

- **App name** (≤30): `Low Hanging Fruit`
- **Subtitle** (≤30): `Your next deadline, first`
- **Bundle ID:** `com.lhf.lowhangingfruit`
- **Primary category:** Education
- **Secondary category:** Productivity
- **Age rating:** 4+

## Promotional text (≤170, editable anytime)

Every Canvas deadline in one calm list, sorted so the next thing you should do
is always on top — now with readings, class sessions, and per-class control
over what reminds you.

## Description

Low Hanging Fruit (LHF) turns your Canvas deadlines into one clear, calm list —
sorted so the most urgent thing is always on top. No more digging through course
pages to figure out what's actually due next.

Log in once with your school Canvas account and LHF pulls your deadlines
straight from your personal Canvas calendar. Each item shows when it's due,
color-coded by urgency. Swipe to check it off — and work you've already
submitted on Canvas files itself away automatically.

MORE THAN ASSIGNMENTS
Your classes aren't just problem sets. LHF also picks up readings, class
sessions, and other calendar items — including readings a professor posts only
to the Modules page — and labels anything with nothing to turn in with a plain
"nothing to submit" tag, so you always know whether a deadline needs a file or
just you. Items with nothing to submit never show up as "late": once their
moment passes, they file themselves away.

YOUR CLASSES, YOUR RULES
Every class gets its own row in Profile: rename it, hide it, choose its own
reminder times, or switch off reminders for readings and attend-only work while
keeping the ones for real assignments. When the semester turns over, LHF offers
to archive last term's classes in one tap — nothing is deleted, and Done keeps
your whole record.

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
• Optional local reminders before each due date, plus a daily digest
• Semester rollover: archive last term's classes without losing your history
• Light and dark appearance
• Adjust any due date by hand when your professor moves it

PRIVATE BY DESIGN
Everything stays on your device. LHF has no account system and no server — it
talks only to your school's Canvas (and Gradescope, if you connect it). We
don't collect, track, or share anything.

LHF is an independent app and is not affiliated with or endorsed by Instructure
(Canvas), Turnitin (Gradescope), or any university.

## What's New in 2.0.1 (release notes, ≤4000)

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

canvas,assignments,deadlines,homework,planner,student,college,readings,reminders,semester

## URLs

- **Support URL:** [REQUIRED — e.g. a simple GitHub Pages or Notion page]
- **Marketing URL:** [optional]
- **Privacy Policy URL:** [REQUIRED — host docs/PRIVACY.md publicly; see CHECKLIST.md]

## App Privacy ("nutrition label") answers

When prompted in App Store Connect → App Privacy:

- **Do you collect data from this app?** → **No, we do not collect data.**

That single answer is the whole label, and it stays correct: schedules,
sessions, and preferences are all processed and stored on-device only, and the
developer receives nothing. It is consistent with the bundled
`PrivacyInfo.xcprivacy` files (app and widget) and with `docs/PRIVACY.md`. Do
not add any data types.

## Content rights

The app displays the user's own content from third-party services (Canvas,
optionally Gradescope), accessed with the user's own credentials. See
`REVIEW_NOTES.md` for the position on Guideline 5.2.2.

## Export compliance

- Uses non-exempt encryption? → **No** (already declared via
  `ITSAppUsesNonExemptEncryption = false` in Info.plist; no extra step needed).

## Build / version

- Marketing version: **2.0.1**
- Build: **6** (must exceed the live 2.0.0 / build 5 — it does)
- The widget target's `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` must match
  the app's or validation fails. Both are stamped from `project.yml` and are
  already 2.0.1 / 6 in the committed project.
