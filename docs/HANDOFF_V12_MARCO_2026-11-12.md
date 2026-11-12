# Hand-off for Marco: `v12`, ambassador mode, for the finishing touches (2026-11-12)

Written 2026-11-12 in Olisa's cloud session. Olisa's words that day: "I
think this is ready to go. I want to push this to v12 and remove the degree
progress thing temporarily because I don't think it is ready. I want to send
this version of v12 over for marco to put the finishing touches on."

So this page is what `v12` holds, what has and has not been seen working,
and what is left before it can ship. The cloud session has no Mac and no
phone: everything it calls "compiled" was compiled on the GitHub runner, and
everything it calls "seen" was seen by Olisa on his own iPhone.

## 1. Read this first: `v12` does not contain your `v11`

`v12` and `v11` both start at `v10` `4c136b2`. On 2026-11-12 `v11` was 103
commits past it (`f03dce0`, the agent connection and the draft work) and
`v12` was 73 past it. Neither holds the other. Nothing here was merged into
`v11`, on purpose: it is your line.

A trial merge of the two (`git merge-tree`, nothing written) on 2026-11-12:

- **Five files conflict:** `CLAUDE.md`, `ROADMAP.md`, `docs/PRIVACY.md`,
  `docs/appstore/REVIEW_NOTES.md` and `FeatureFlags.swift`. The four
  documents are "each side added a section"; keep both. `FeatureFlags.swift`
  is each side adding its own flags near the same place; keep both sets.
- **Six Swift files merge without a marker:** `AppState.swift`,
  `ContentView.swift`, `NotificationScheduler.swift`, `RootView.swift`,
  `SettingsPage.swift` and `VisualStructureTests.swift`. Read each around
  the merged hunks anyway. The trap "a textually clean merge can put a line
  in the wrong place" (CLAUDE.md → Traps) came from exactly this kind of
  merge. The places to look: `ContentView.DashRoute` (v12 adds `.degree` and
  `.ambassador`), `RootView.onOpenURL` (v12 adds `smooth://ambassador`),
  `NotificationScheduler` (v12 reserves slots for the ambassador reminder,
  `reservedForeignSlots`), and the Profile section order in `SettingsPage`.

Which branch becomes the base is yours and Olisa's call. Whichever way it
goes, run the whole suite on the merged tree before trusting it.

## 2. What `v12` holds beyond `v10`

### Ambassador mode (the reason for this hand-off)

Profile → "ambassador mode". For the founders' friends at other schools;
every other student sees one row and nothing else. CLAUDE.md → What the app
does → Profile → 8 is the full description. In short:

- **Sign in with a code**, not an account. The code comes from the
  ambassador's private page link. New codes start with the school
  (`uva-…`). It is kept in the Keychain.
- **The page, top to bottom** (as of 2026-11-12, after Olisa's first look on
  his phone):
  1. "the job": "get smooth in front of as many eyes as you can." / "spam
     the chats. put up posters. post every day." / "bring back what people
     say and ideas for smooth." Then a filled button, "open my web page ↗".
  2. today's post, with copy and "i posted it"
  3. posters: "all posters" (an in-app gallery), "scan dashboard ↗", "send a
     poster idea" (photo picker and a note)
  4. feedback and ideas (a text box that goes to the founders)
  5. numbers, the daily reminder, more messages and posting tips, pause,
     sign out
- **The daily reminder** is a local notification, spared by the due-date
  reschedule pass.
- Files: `AmbassadorPage.swift`, `AmbassadorModel.swift`,
  `AmbassadorClient.swift`, `AmbassadorReminders.swift`,
  `AmbassadorPostersView.swift`, `PosterIdeaSheet.swift`,
  `AmbassadorCodeStore.swift`, and `Ambassador/` in the Kit. Tests:
  `AmbassadorTests.swift`.

### The ambassador server

`smooth-ambassadors/` is a Cloudflare Worker and D1 database on the
poster-scan tracker's own site. It is **not** Supabase and nothing in
`backend/` knows about it. It is deployed by a ChatGPT session that owns the
Sites project, from a zip this repo builds; `smooth-ambassadors/docs/deploy.md`
says how. Two deploys are live (2026-11-11 and 2026-11-12). A third zip was
handed to Olisa on 2026-11-12 and **whether it is deployed is not recorded
here**: it removes the checklist from the web page, puts the job line on
top, and carries the rewritten anonymous posts. Until it is live, the app's
"today" post and "more messages" still show the older, shorter texts,
because the server writes them.

Rules that are easy to break by accident:

- Never open a `/scan/...` or `/r/...` link on the live site. Each one is a
  real count.
- The founder page's token is Olisa's. It is not in the repo and must not go
  into a chat.
- The repository is public. Poster images, real ambassador names and any
  ambassador code stay out of it.
- Nothing in ambassador mode mentions ratings or reviews, and a test keeps
  it that way.

### Degree progress: in the tree, switched off

`FeatureFlags.degreeProgress` is `false` since 2026-11-12. No row in
Profile, no read of Path@Penn, nothing deleted. To bring it back, set the
constant to `true`; the tests that skip themselves while it is off run
again. Before doing that, read CLAUDE.md → Known gaps → "Degree progress":
the options row has never run on a device, the numbers were never checked
against Path@Penn's own page, and the App Store questions (guideline 5.2.2,
the privacy label) are open. `docs/PRIVACY.md` still has its degree section,
now headed by a line saying it is switched off. If this build ships with the
flag off, decide whether that section should be published at all.

## 3. What has been checked, and what has not

**Compiled and tested on the GitHub runner** (the `tests` workflow, run by
hand so the unsigned iOS build runs too): see CLAUDE.md → Test baseline for
the count at the commit this file landed with. No test has run on a Mac for
this branch since the ambassador work began, and nobody has run
`swift test` locally. The shared-defaults trap cannot bite on the runner,
so expect your first local run to be the first chance for it.

**Seen on Olisa's iPhone** (Debug builds installed with
`bash scripts/build-to-phone.sh`):

- The app builds, installs and launches with ambassador mode in it.
- Sign-in with a real code against the live server: the page drew (his
  screenshot, 2026-11-12, showed the reminder row, the anonymous-app picker,
  messages, feedback and the footer).

**Not seen by anyone yet:**

- The job-first layout itself. It was written after that screenshot; the
  build on his phone at the time still had the checklist.
- The posters gallery, the scan-dashboard link and a poster idea sent with a
  photo from the phone.
- The daily reminder firing, surviving the next reschedule pass, and its tap
  landing on the ambassador page from a cold launch.
- The `smooth://ambassador?code=…` link from Safari.
- The page in dark mode.
- The founder page showing an idea that the app sent.

## 4. What is left before this can ship

In rough order.

1. **Your pass on the page.** It was laid out in a cloud session from a
   description and one screenshot. The copy is Olisa's wording ("spam the
   chats"); your copy rule (the least text that works) was applied by
   someone who is not you. The "the job" section has three lines of text and
   a caption under the button, which is more than any other section in
   Profile.
2. **The device checks in section 3.**
3. **Merge with `v11`** (section 1), then the full suite and an iOS build on
   the merged tree.
4. **App Review.** `docs/appstore/REVIEW_NOTES.md` opens with a paragraph for
   ambassador mode that needs a real test code. Olisa makes one in the
   founder page (an ambassador named for App Review) and pastes it into App
   Store Connect only. The privacy label has not been re-read for ambassador
   mode: what leaves the phone is in `docs/PRIVACY.md` → "Ambassador mode".
5. **The version stamp.** `project.yml` still says 3.4.1 (20), the build
   uploaded from `v10` on 2026-11-07. App Store Connect refuses a build
   number it has seen, so check TestFlight → Builds there before choosing
   the next one. Whether 3.4.1 is live was not readable from the cloud
   session (Apple's lookup did not answer).
6. **The third server zip**, if it is not deployed yet (section 2).

Known and left alone: Yik Yak is reported to cap a post at 200 characters,
and every anonymous post is longer than that once its link is counted. If an
ambassador uses Yik Yak, the server needs short versions.

## 5. Commands

```bash
git fetch origin && git checkout v12 && git pull

# Build, install and launch on the plugged-in iPhone, in one step
bash scripts/build-to-phone.sh

# The suite (alone on the machine; see the shared-defaults trap)
cd LowHangingFruitKit && swift test --no-parallel

# The ambassador Worker's own tests (Node 22)
cd smooth-ambassadors && npm ci && npm test
```

To try ambassador mode you need a code. Olisa has a test ambassador on the
live roster and can send you its code directly. It is not written here
because this repository is public.

## 6. Text for a new Claude Code session on your Mac

```text
Read CLAUDE.md, then ROADMAP.md, then docs/HANDOFF_V12_MARCO_2026-11-12.md.
I am Marco. Olisa handed me v12 on 2026-11-12 for the finishing touches on
ambassador mode (Profile → ambassador mode). Degree progress is switched off
on purpose (FeatureFlags.degreeProgress = false); leave it off.

First: check out v12, run `cd LowHangingFruitKit && swift test --no-parallel`
alone on this machine, and tell me the count against CLAUDE.md → Test
baseline. Then build to my phone with `bash scripts/build-to-phone.sh`.
Do not merge v11 and v12 until I say which is the base; section 1 of the
hand-off lists what conflicts. Do not open any /scan/ or /r/ link on the
live poster site, and never write an ambassador code into the repository.
Design changes go on their own branch until I approve them.
```
