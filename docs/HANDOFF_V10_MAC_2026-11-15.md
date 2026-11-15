# Hand-off for a Mac: v10 on a phone (2026-11-15)

Written 2026-11-15 in Olisa's cloud session for the first session on
Olisa's own Mac. It replaces section 2 of
`docs/HANDOFF_V10_MARCO_2026-11-05.md` for whoever has the Mac, Olisa or
Marco: the steps are the same, the state has moved.

## What changed since the 2026-11-05 hand-off

- **The tree runs on Claude Haiku 5.5 in production** since 2026-11-15
  17:25 UTC (`ask` v24, `LHF_MODEL`, `LHF_ASK_REASONING={"enabled":false}`).
  A server change: every installed build already gets it. CLAUDE.md → "ask:
  the model, the hedge, and the loop that tunes them" has the numbers.
- **Phone-side tree work on `v10`, compiled on the GitHub runner, never on
  a phone or in an iOS build:** Marco's held course-material sync (the
  "manifest failed" fix, `c5f8d2a`), the room on `ClassMeeting`
  (`9fdf8b4`), dated excerpt labels "posted 2026-11-01 (yesterday)"
  (`ec12121`), per-intent excerpt budgets, the computed weekly-schedule
  line with its authority rule, and the due-in-range list (`0f093a6`).
  Runner: 3700 tests / 356 suites green at `0aab3af`; the commits after it
  touch only docs.
- Marco's `agent/connection-v11`, `v11` (the Sweeper page) and Olisa's
  `v12` (degree progress) are **not** in `v10`. Do not merge them in this
  session; that is a separate decision.

## Before you start (once)

- macOS with Xcode 26 and the iOS 26 SDK; Xcode → Settings → Accounts
  signed in with an Apple ID on team `24A3TDB277` (Olisa's is the Account
  Holder).
- The iPhone on a cable, unlocked, Developer Mode on (Settings → Privacy
  & Security → Developer Mode), and trusted in Xcode → Window → Devices and
  Simulators.
- The repository cloned, and Claude Code running in it.

Installing a Debug build over the App Store copy keeps every bit of data
(same team, same container). Going back to the store copy later means
deleting the app, so the phone stays on the Debug build until the next
App Store update installs over it.

## Paste this into Claude Code on the Mac

> Read CLAUDE.md top to bottom, then ROADMAP.md, then
> `docs/HANDOFF_V10_MAC_2026-11-15.md`. Work on `v10` (`git fetch origin
> v10 && git checkout v10 && git pull --rebase origin v10`). Commit with
> the trailer lines CLAUDE.md asks for, and `git pull --rebase origin v10`
> before every push: a cloud session pushes to the same branch. Then, in
> order, stopping where it says to stop:
>
> 1. **Compile.** `pgrep -f LowHangingFruitKitPackageTests` must print
>    nothing, then `cd LowHangingFruitKit && swift test --no-parallel`,
>    alone on the machine. Expected 3700 tests / 356 suites (the runner's
>    count at `0aab3af`). Then
>    `xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`,
>    which compiles the widget and the iOS-only files the runner never
>    sees. Fix anything either finds in the 2026-11-14/15 commits in
>    place; a test that pins old behaviour may be rewritten to the new
>    intent, never loosened or deleted. Record count, date, machine and
>    seconds in CLAUDE.md → Test baseline.
> 2. **Phone build.** Build the Debug app to the connected iPhone and
>    install it (CLAUDE.md → Commands), launch it, and leave it open in the
>    foreground for two minutes so one course-material sync runs.
> 3. **Did "manifest failed" go away?** Copy the App Group plist off the
>    phone (CLAUDE.md → Commands, the `devicectl device copy from` line)
>    and read `lastCourseKnowledgeSyncSummaryV1`. Expected "manifest ok".
>    If it still fails, the line now names why (cancelled, transport,
>    http N, decoding): write that down, do not guess a fix.
> 4. **The tree, on the phone, in one conversation.** Ask each, and write
>    down the answer word for word and whether a source chip showed:
>    "Do I have <one of my classes> class tomorrow?", then "you should've
>    said that in my original question"; "what is the late policy for
>    <a class with a syllabus>"; "any news from <a class on Ed> this
>    week"; and, after 8 pm Eastern, "what's due tomorrow" (check the day
>    it names). Record the answers in CLAUDE.md → Known gaps (the
>    "recording fixes, on a phone" entry) and `docs/TREE_IMPROVEMENT_PLAN.md`
>    → Status.
> 5. **Facts on a card, by eye.** Open a card a fact touched (the
>    megaphone lists them), tap `undo`, and check nothing was completed or
>    deleted. Then edit a date by hand on a fact-touched card and check
>    the hand edit wins. Record it in the Known-gaps entry about Phases
>    1-3.
> 6. **Stop and ask me** before stamping a build number, archiving,
>    uploading to App Store Connect, or merging any other branch into
>    `v10`.
>
> Before the session ends: CLAUDE.md and ROADMAP.md updated per the
> "Start here" table, committed with what they describe, pulled with
> rebase, pushed to `v10`.
