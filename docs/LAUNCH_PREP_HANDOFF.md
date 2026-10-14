# Launch-prep handoff

Written 2026-10-14 for whoever picks this up next: a new session, Olisa,
or Marco. It covers the launch-prep work of 2026-10-09/10 and what it
left open. `CLAUDE.md` and `ROADMAP.md` stay the project's memory and
hold the detail; this page is the short version, with the order to do
things in. Read it, then `ROADMAP.md` → Now.

## Where things stand (checked 2026-10-14)

- **`v8` is the line, and it holds the launch-prep work.** Pull request 9
  (`v8-launch-prep` → `v8`) was merged on 2026-10-10 on Marco's say; `v8`
  is at `beed156` and nothing has landed since. The tree is the one that
  passed **1975 tests in 189 suites** (`swift test --no-parallel`, run
  alone) and compiled for iOS in Debug and Release, widget included.
  Only notes changed after that run.
- **Live on the App Store: 3.0.0 (11)**, released 2026-09-28 (iTunes
  lookup). The `update-manifest` floor is still 1.2.1. `v8` is stamped
  3.0.1 (12) and nothing has been uploaded from it.
- **Marco's phone** last took a build of the merged `v8` on 2026-10-10 at
  14:07 (a DEBUG build installed over the store copy). It was unplugged
  afterwards.
- **Nothing in sign-in or the sync was changed.** `sync()`,
  `syncGradescope` and `connectCanvas` are byte-identical to Olisa's
  `e2672eb`. Marco asked for that explicitly ("Don't touch the sync from
  Olisa's version"), and it is why several fixes below are written up
  instead of merged.

## What landed

| Area | Change | Commits |
|---|---|---|
| Cards | "open in canvas" / "open in gradescope"; an edited due date is saved (it was lost on relaunch); "delete" on your own one-off task, "stop repeating" on a recurring one | `a0e7e04`, `2bafd94`, `83865fc`, `e5031ec` |
| Reminders | opt-in "10 minutes before"; body names the assignment ("Problem Set 4. Due in 1 hour"); renamed class as title; an empty selection is no longer read back as the defaults | `a99c9f3`, `13b2acb`, `9e1ccae` |
| Sign-up | a new student does not see unfinished work that was 7+ days overdue when they joined; "N older hidden · show" on prev; existing installs see no change | `85a0c2b`, `01afe8e` |
| Announcements | the megaphone lists every Canvas announcement from 60 days, plus Ed announcements and pinned posts; extracted tasks on top | `67d5957`, `b5ed8a1`, `2ef85cc` |
| ask | search fixed; 8 whole passages instead of 4 cut at 700 characters; follow-ups keep their class; Ed posts dated; short canned text; source chips link | `ac45b9b`, `24c4349`, `1acde04`, `33d83b5`, `0a47762` |
| Less text | no sign-in prose on Profile → accounts (one collapsed DEBUG-only disclosure); banners, sheets, onboarding, Grade Watcher, widget cut down | `9058d0a`, `46657ce` |
| Small fixes | "8m" under an hour, 44pt targets, todo empty state, VoiceOver on due times, "not saving on this phone" banner, widget trusts an empty snapshot | `9e1ccae`, `31336d5` |

## What has been checked on a phone, and what has not

Checked on Marco's phone, by reading what the app wrote:
- the sign-up rule records "hide nothing" on his existing install
  (`signupBacklogCutoffV1 = 0` read off the phone);
- the announcements list after the date-window fix: 15 announcements
  across 2 classes, 4 to 47 days old, read from `announcement-log.json`
  on the phone (the build before the fix held 2, both over a month old).

Installed but not reported on: the links, the 10-minute option and the
reminder wording went onto the phone on 2026-10-09; nobody has said how
they look.

Not yet looked at on a screen, in the order worth doing it:
1. The megaphone: Canvas and Ed rows, the one-line preview, the layout.
2. Profile → accounts with no Canvas text, and the collapsed "sign-in
   diagnostics" in the DEBUG testing section.
3. An opened card: "open in canvas" opens without collapsing the card;
   an edited date survives a force-quit; "delete" and "stop repeating".
4. A reminder that fires: class title, renamed class, assignment name.
5. ask: a follow-up without the class name; a tappable source chip.
6. The widget when caught up ("all clear") and at a due time.
7. A fresh install mid-semester: old overdue work withheld.

Do this before any build from `v8` goes to TestFlight: `v8` is also the
line the sign-out fix (3.0.1) ships from.

## Decisions waiting

Each needs Marco, and most need Olisa. Nothing below is merged.

1. **What to ship, and when.** 3.0.1 (12) from `v8` would now carry the
   launch-prep work as well as Olisa's sign-out fix. Olisa's plan for
   the sign-out fix was two phones, then TestFlight to three affected
   students for a week, then the store. Marco also said "submit" on
   2026-10-10; that was read as the pull request, not App Store review.
   App Store Connect needs a build number above every one it has seen
   (check TestFlight → Builds), and Olisa is the Account Holder.
2. **One argument in the course-material sync.** `CourseKnowledgeCollector`
   asks Canvas for announcements from 200 days back without an end date,
   and Canvas ends the window 28 days after the start, so ask has never
   had an announcement (Marco's phone: 106 course documents, none of
   kind `announcement`). Passing `until:` fixes it. It is in Olisa's
   sync, hence not done.
3. **`parked/ask-course-sync-fixes`.** A half-failed course-material sync
   erases a class's material for everyone in it, and one forbidden
   course aborts every course. Fixes are written and parked; its commit
   message lists a regression and two server-side prerequisites
   (paginate `selectLiveDocumentsForCourses`; batch uploads by bytes).
4. **Completion state in the ask summary.** Every ask question sends
   each item's "done" / "outstanding" status to the server, and has since
   September; `docs/PRIVACY.md` says three times that completion state
   never leaves the phone. Change the summary or the policy (here and
   wherever it is hosted).
5. **Anonymous Ed posts.** `docs/PRIVACY.md` says they never leave the
   phone; `EdThreadFilter` never reads `isAnonymous`. Change the
   keep-rule (Olisa's scraping) or the sentence.
6. **Canvas Files for ask** (slides, readings, PDFs), and **sending
   earlier chat turns** with a follow-up. Both are probably the biggest
   remaining gains for ask, and both change what leaves the phone.
7. **Small calls from the review**, listed in `ROADMAP.md` → Next: what
   prev shows for finished recurring occurrences (they never appear),
   whether "today" means the next 24 hours, a "system" appearance
   option, deep links from a notification.

## Rules that came out of this work

These are Marco's, from 2026-10-09/10, and they still hold:
- **Don't touch Olisa's sync** (sign-in and session renewal, the feed
  sync and reconcile, the course-material sync, Ed's launch, fetch and
  filter). Build beside it; write a fix up or park it on a branch.
- **The least text that works.** No explanatory sentences, no captions
  that restate a control, no raw errors, no diagnostics on a normal
  screen. He runs DEBUG builds, so "DEBUG only" does not hide text from
  him: keep it collapsed. What must stay is in `CLAUDE.md` → What the
  app does → Profile (the copy rule).
- **Check on his connected iPhone**, not the Simulator or the Xcode app.
  `xcodebuild` from the command line is fine.

## How to work on it

- **Test runs must be alone.** Every worktree's test process shares one
  defaults domain, so two `swift test` runs at once make unrelated suites
  fail at random (`CLAUDE.md` → Traps). A baseline is only a run with
  nothing else testing.
- **`swift test` does not build the widget or iOS-only code.** Before
  calling a change compiled:
  ```bash
  xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
  ```
- **Put it on the phone** (device ids from `xcrun devicectl list devices`
  and `xcodebuild -showdestinations`; on 2026-10-10 the phone was
  `00008150-000A25D63428401C` / CoreDevice
  `8A287085-9C88-5A87-816B-1A8EF80D67AD`):
  ```bash
  xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug -destination 'id=00008150-000A25D63428401C' -allowProvisioningUpdates build
  ```
  then `xcrun devicectl device install app` and `… process launch`, as in
  `CLAUDE.md` → Commands. A locked phone fails the launch but not the
  install.
- **Read what the app did, off the phone**, with a DEBUG build installed:
  `xcrun devicectl device copy from … --domain-type appDataContainer
  --domain-identifier com.lhf.lowhangingfruit --source "Library/Application
  Support/LowHangingFruit/announcement-log.json"` (or
  `course-knowledge.json`), and the App Group plist as in `CLAUDE.md` →
  Commands. Count and date things; do not copy course text out.
- **Worktrees.** The checkout of `v8` used for this work is
  `.claude/worktrees/launch-prep` (local branch `v8-launch-prep`, level
  with `origin/v8`). Agent worktrees made with `isolation: "worktree"`
  start from a stale `main`; make them by hand from `v8`.

## Loose ends

- The main checkout (`~/penn-dashboard`) is still on
  `fix/canvas-signin-bulletproof` with four uncommitted files of sign-in
  work from 2026-10-08. It overlaps Olisa's sign-out fix in `v8` and was
  deliberately not touched. Reconcile it or drop it, with Marco.
- `v8-launch-prep` still exists on the remote because these notes cite
  it. Delete it once nobody needs the reference.
- Pull requests 1, 2, 6 and 7 are still open from July and August.
  Nobody has checked whether anything in them is still wanted.

## Suggested order

1. Plug in Marco's phone; install `v8`; walk the seven checks above.
2. Decide 1 (what ships) with Olisa, and 4 (completion state) before
   anything new reaches the store.
3. Take the one-argument announcements fix (2) if Olisa agrees.
4. Then the parked sync fixes (3), with the server changes they need.
