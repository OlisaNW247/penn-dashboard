# Hand-off for Marco's Mac: v10, the tree and the facts on a phone (2026-11-05)

Written 2026-11-05 in Olisa's cloud session, which has no Swift toolchain
and no phone. Olisa is on a Windows loaner laptop this week, so everything
that needs `xcodebuild`, a device or a Mac's eyes is on this page, in the
order to do it. Section 2 is the text to paste into a new Claude Code
session on the Mac; section 1 says what happened today so that session's
first `swift test` is not a surprise.

## 1. What landed on `v10` today, from the cloud

All of it blind (written without a compiler) unless the line says otherwise.
The GitHub runner (`.github/workflows/tests.yml`) now compiles every push to
`v10` (it listened to `v8` and `main` only until 2026-11-05, so none of the
v10 work had a runner compile before today); read its verdict before the
Mac's run: `gh api repos/OlisaNW247/penn-dashboard/actions/workflows/tests.yml/runs?branch=v10`.

- `f275c3f` **`v8` merged into `v10`**: the Chrome extension's store builds
  (0.1.1, 0.1.2), its Ed read and the submission state it feeds the phone.
  One conflict in CLAUDE.md → Known gaps, both sides kept. From here nothing
  lands on `v8`; `v10` is the only line.
- `e720b82` the runner trigger for `v10`; `75b1139` `.claude/worktrees/`
  ignored.
- `f4f17e9` **The probe script** (`backend/scripts/ask-probe.mjs`): two new sets,
  `history` (the recording's pair: the class-today question answered from
  the schedule, then "you should've said that in my original question") and
  `meeting` (the class-today question alone), and `--history-file`. Node
  only; nothing for the Mac to compile.
- `28e8803` + `f398bd0` **The tree reads applied facts**: the context document the tree sends,
  and the on-device answerer's pool, take the dashboard's own fact
  application (a rescheduled item carries the new date; a cancelled one is
  rendered `cancelled`, never dropped; `undo` and a hand-edited date win as
  on the card). Before this a v10 phone showed "cancelled" on the card while
  the tree called the item outstanding with the feed date.
- `fae20bd` (merged as `e0ab790`) **The time-frame resolver and per-intent freshness** (steps 1 and 2 of
  `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`, Marco's own research): a pure
  Kit resolver that turns "today / tomorrow / this week / Thursday / past N
  days" into absolute local date ranges and an intent (class meeting, due
  on, recent news, policy, specific); a half-life decay on dated posts for
  the meeting and news intents only, none for policy; a frozen regression
  set with a pinned clock. Steps 3 to 6 wait on one decision (how the
  weekly schedule reaches the phone), which is Olisa's and Marco's.

**The runner compiled all of it green: 3631 tests / 348 suites at
`e0ab790`** (2026-11-05, Xcode 26.3, 111.5 s; +35 / +3 over 3596 / 345; one
test in `AskRecencyExcerptTests` rewritten because "when is the midterm" is
now a policy question). So the Mac's `swift test` should match 3631 / 348;
what the runner cannot do, and the Mac must, is the iOS `xcodebuild` (the
widget) and the phone. The implementers' own lists of the lines they were
least sure of are in the commit bodies of `28e8803` and `fae20bd`.

## 2. Paste this into a new Claude Code session on the Mac

> Read CLAUDE.md top to bottom, then ROADMAP.md, then
> `docs/HANDOFF_V10_2026-11-04.md` and `docs/HANDOFF_V10_MARCO_2026-11-05.md`
> (this page). Work on `v10` in the worktree `.claude/worktrees/v9`
> (`git pull --rebase origin v10` first; `v10` is the only line, nothing
> goes to `v8`). Commit as yourself with the two trailer lines the other
> sessions use, and `git pull --rebase origin v10` before every push:
> Olisa's cloud session pushes to the same branch. Then, in this order,
> stopping where it says to stop:
>
> 1. **Compile.** `pgrep -f LowHangingFruitKitPackageTests` must be empty,
>    then `cd LowHangingFruitKit && swift test --no-parallel` alone on the
>    machine. Compare with the runner's latest `v10` verdict. Expected:
>    3596 / 345 plus the blind additions listed in CLAUDE.md → Test
>    baseline for 2026-11-05 (the runner read 3631 / 348 at `e0ab790`). Fix
>    anything the Mac finds in today's commits in place; a test that pins old behaviour may be rewritten to the new
>    intent, never loosened or deleted. Record the count, date, machine
>    and seconds in Test baseline. Then
>    `xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
>    (the widget and the iOS-only files, which `swift test` never compiles).
> 2. **Phone build.** Build the iOS Debug app to Marco's iPhone (CLAUDE.md
>    → Commands; check the installed build is this one, "install only the
>    newest build"), launch it, let one sync finish in the foreground.
> 3. **Facts on cards, by eye** (ROADMAP → Now, facts item 6; nobody has
>    looked yet). Run `bash backend/scripts/verify-facts-on-phone.sh
>    <CoreDevice id>` and read the three lines. In the app: open a card a
>    fact touched (PHYS 0151 has 17 facts on the server; the megaphone's
>    `changed` and `needs a look` groups list them), tap `undo`, confirm
>    nothing was completed or deleted (re-run the script: the completed
>    count is unchanged), confirm a date edited by hand still wins over a
>    fact's date, and that a cancelled card is out of todo and tagged in
>    all. Write what you saw, good or bad, in CLAUDE.md → Known gaps (the
>    "Phase 1 of the composed day has run on a device once" entry) and
>    `docs/PRIVACY.md` only if a behaviour differs from what it promises.
> 4. **The tree on the phone**, in one conversation, and write each answer
>    down verbatim with whether a source chip showed: "Do I not have cis
>    2620 class today?"; then "you should've said that in my original
>    question". Then a question about an item a fact touched ("was <the
>    cancelled item> cancelled?", "when is <the moved item> due now?") and
>    check the tree agrees with the card. Then, after 8 pm Eastern, "what's
>    due tomorrow" and check the day it names. Record all of it in
>    CLAUDE.md → Known gaps (the "recording fixes, on a phone" entry) and
>    `docs/TREE_IMPROVEMENT_PLAN.md` → Status.
> 5. **The retrieval bench on real data.** Pull `course-knowledge.json`
>    off the phone (`backend/bench/extract-facts/pull-from-phone.sh`, or
>    the `devicectl device copy from` line in `docs/TREE_IMPROVEMENT_PLAN.md`
>    → "Running the bench"; it lives in the app container under
>    `Library/Application Support/LowHangingFruit/`), keep it outside the
>    repo (`~/lhf-bench/`), and run
>    `LHF_BENCH_KNOWLEDGE=~/lhf-bench/course-knowledge.json swift test --no-parallel --filter RetrievalBenchTests`.
>    Commit only counts, document titles and which of the 30 questions
>    got the right passage (never a passage body) to the plan's Status;
>    that is what the next retrieval change is tuned against.
> 6. **Labels.** The roughly 40 judgment calls in
>    `backend/bench/extract-facts/corpus/phone/marco/LABELS-*.md`
>    (`docs/HANDOFF_V10_2026-11-04.md` → "What we need", item 1). Rescore
>    without model calls: `deno run --allow-read --allow-write
>    bench/extract-facts/score.ts --results results/<tag>.jsonl --corpus
>    <corpus dir>`.
> 7. **Stop here and ask Olisa** before any of the following: stamping
>    the next build (the hand-offs say 3.4.1 (18); with the sign-in
>    rewrite and the facts it is a 3.5.0 in substance, his call), the
>    Release archive, the `otool -L` check that the widget's AlarmKit link
>    is weak, the upload, and the Release-state lines in CLAUDE.md and
>    `docs/appstore/CHECKLIST.md`. Also his call: whether the weekly
>    schedule is sent down in the manifest or built on the phone (the
>    research's steps 3 to 6 wait on it).
> 8. **Optional, one time, for a release lane that needs no Mac:** export
>    the Apple Distribution certificate with its private key as a
>    password-protected `.p12` from Keychain Access, and hand it to Olisa
>    through a password manager, never through chat, email or the repo.
>    With it and an App Store Connect API key, the cloud session can
>    write a GitHub workflow that archives and uploads from the runner.
>
> Before the session ends: CLAUDE.md and ROADMAP.md updated per the
> "Start here" table (Test baseline, Known gaps, Now), committed with the
> change they describe, pulled with rebase, pushed to `v10`.

## 3. What Olisa does from the cloud meanwhile

Canary measurements with the new probe sets ran on 2026-11-05 from the
`ask-probe` GitHub workflow (`meeting` 10/10 from the post; `history` 10/10
corrected the earlier turn, so history works server-side); the candidate models for `ask` before
`gpt-4.1-mini`'s shutdown on 2027-01-14 (a secret change and a deploy, at
his tap), and the one-pass server prompt change measured on `ask-canary`
before `ask`. None of it needs the Mac; all of it needs the phone results
above to be worth more than a probe.
