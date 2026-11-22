# Hand-off for Marco: `v12`, ambassador mode and the download count

First written 2026-11-12, **rewritten 2026-11-22** so it reads as one page
again. It replaces the earlier version and its three appended sections;
nothing in those is still needed.

Olisa's words on 2026-11-12: "I think this is ready to go. I want to push
this to v12 and remove the degree progress thing temporarily because I don't
think it is ready. I want to send this version of v12 over for marco to put
the finishing touches on."

This page says what `v12` holds, what has and has not been seen working, the
decisions that are yours, and what is left before it ships. It was written in
Olisa's cloud session, which has no Mac and no phone: "compiled" here means
compiled on the GitHub runner, and "seen" means seen by Olisa on his iPhone.

## 0. What changed since you last read this

Ten days of work landed after the first hand-off. In order:

| Date | What |
|---|---|
| 2026-11-12 | The ambassador page opens on "the job" and a filled "open my web page" button. The getting-started checklist is gone. |
| 2026-11-18 | Three new sections: "what works", "from the founders", "help us help you" (send a feed recording; report how a post did). |
| 2026-11-19 | Every written post was removed. The bank is Olisa's two real Sidechat posts, each with a reply line. Pull to refresh on the page. |
| 2026-11-22 | **Downloads by school.** Every install, at every school, sends one anonymous count. Ambassadors see "{school} downloads". |

The last row is the one to read carefully (section 3). It is not only an
ambassador feature, and it changes a line of the privacy policy.

Everything on the server side is deployed. Nothing in the list has been
released in an app build, and most of it has never run on a phone.

## 1. Read this first: `v12` does not contain your `v11`

Both lines start at `v10` `4c136b2`. On 2026-11-22:

- `v12` is 95 commits past it (`115384a`), stamped **3.4.1 (20)**.
- `v11` is 104 commits past it (`2f49f8d`, 2026-11-12, "Stamp 3.5.0 (21)").

Neither holds the other, and nothing here was merged into `v11`: it is your
line. The update floor on the `update-manifest` branch reads 3.4.1, and the
automation only raises it once a version has been live for six hours, so
3.4.1 is live. Whether 3.5.0 (21) was uploaded or released could not be read
from the cloud session (Apple's lookup did not answer).

A trial merge of the two (`git merge-tree`, nothing written), re-run on
2026-11-22:

- **Five files conflict:** `CLAUDE.md`, `ROADMAP.md`, `docs/PRIVACY.md`,
  `docs/appstore/REVIEW_NOTES.md` and `FeatureFlags.swift`. The four
  documents are "each side added a section"; keep both. `FeatureFlags.swift`
  is each side adding its own flags near the same place; keep both sets
  (`v12`'s are `degreeProgress = false` and `installCount = true`).
- **Six Swift files merge without a marker:** `AppState.swift`,
  `ContentView.swift`, `NotificationScheduler.swift`, `RootView.swift`,
  `SettingsPage.swift` and `VisualStructureTests.swift`. Read each around the
  merged hunks anyway. The trap "a textually clean merge can put a line in
  the wrong place" (CLAUDE.md → Traps) came from exactly this kind of merge.
  Where to look:
  - `ContentView.DashRoute`: `v12` adds `.degree` and `.ambassador`.
  - `RootView`: `v12` adds the `smooth://ambassador` link in `onOpenURL`, and
    the install-count hook in `RootCore`'s `.task` and its `scenePhase`
    handler (`reportInstallCountIfDue`, after `updateGate.refresh()`).
  - `NotificationScheduler`: `v12` reserves slots for the ambassador
    reminder (`reservedForeignSlots`).
  - `SettingsPage`: the Profile section order, with the ambassador row.
- `docs/appstore/LISTING.md` also merges without a marker; `v12` added a
  paragraph under App Privacy.

Which branch becomes the base is your call and Olisa's. Whichever way it
goes, run the whole suite and an iOS build on the merged tree before trusting
it. The build number has to be above every one App Store Connect has seen,
so above 21 if that build went up.

## 2. Ambassador mode

Profile → "ambassador mode". It is for the founders' friends at other
schools; every other student sees one row and nothing else. CLAUDE.md → What
the app does → Profile → 8 is the full description.

**Sign in is a code, not an account.** The code comes from the ambassador's
private page link. New codes start with the school (`uva-…`). It is kept in
the Keychain.

**The page, top to bottom, as it is now:**

1. **the job.** "get smooth in front of as many eyes as you can." / "spam the
   chats. put up posters. post every day." / "bring back what people say and
   ideas for smooth." Then a filled button, "open my web page ↗".
2. **what works.** One line ("the posts that work don't look like ads."),
   five short steps, and Olisa's two Sidechat posts as worked examples with
   their upvotes and the reason each worked.
3. **from the founders.** Only when there is something: posts Olisa or you
   wrote for that one ambassador on the founder page, each with copy buttons.
4. **today.** Today's post, "then reply:" with the reply and a "copy reply"
   button, then copy and "i posted it". It alternates between the two posts
   below. There is no rest day any more.
5. **posters.** "all posters" (an in-app gallery), "scan dashboard ↗", "send
   a poster idea" (photo picker and a note).
6. **help us help you.** "show us your feed": the ambassador picks a screen
   recording of their school's anonymous app, the phone cuts up to 16 stills
   out of it and sends the stills, never the video. "how did a post do": one
   screenshot, the app, the kind of post, upvotes and views.
7. **feedback and ideas.** A text box that goes to the founders.
8. **numbers.** Link opens, the school's poster scans, **the school's
   downloads** (section 3), posts logged.
9. **daily reminder.** Every day, weekdays or off, with a time. A local
   notification that the due-date reschedule pass leaves alone.
10. **messages.** The same two posts, each with its reply, and six posting
    tips.
11. Pause for four weeks, sign out.

Pull down on the page to fetch it again. The app keeps a fetched plan for 30
minutes; before pull to refresh existed, Olisa's phone went on showing posts
the server had already dropped.

**The two posts, and why only two.** On 2026-11-19 Olisa, with the build on
his phone: "remove all the AI generated texts we have and put only these 2".
They are the ones that did well for him on Sidechat with no pitch in them:

- "What do you guys use to stop missing assignments?" (22 upvotes at Penn)
- A homecoming frat ranking with Smooth slipped into the B tier (65 upvotes).
  The repo's copy says `[frat]` where names go: the repository is public and
  each school has to write its own.

Each carries the reply "Smooth for Students on the App Store". Neither has a
link. Do not add written posts back to
`smooth-ambassadors/worker/templates/messages.json`; a post for one campus is
written by a founder on the founder page ("send a post to try").

**Files.** UI: `AmbassadorPage.swift`, `AmbassadorModel.swift`,
`AmbassadorClient.swift`, `AmbassadorReminders.swift`,
`AmbassadorPostersView.swift`, `PosterIdeaSheet.swift`,
`FeedRecordingSheet.swift`, `PostResultSheet.swift`,
`AmbassadorCodeStore.swift`. Kit, under `Ambassador/`: `AmbassadorCode`,
`AmbassadorPlan`, `PosterIdeaImage`, `FeedRecordingFrames`. Tests:
`AmbassadorTests.swift`.

**The server.** `smooth-ambassadors/` is a Cloudflare Worker and D1 database
on the poster-scan tracker's own site. It is not Supabase and nothing in
`backend/` knows about it. It is deployed by a ChatGPT session that owns the
Sites project, from a zip this repo builds; `smooth-ambassadors/docs/deploy.md`
says how. Five deploys are live, the last on 2026-11-22. **Nothing is waiting
to be deployed.**

Rules that are easy to break by accident:

- Never open a `/scan/...` or `/r/...` link on the live site. Each one is a
  real count.
- The founder page's token is Olisa's. It is not in the repo and must not go
  into a chat.
- The repository is public. Poster images, real ambassador names and any
  ambassador code stay out of it.
- Nothing in ambassador mode mentions ratings or reviews, and a test keeps it
  that way.

## 3. Downloads by school (2026-11-22): every install sends one count

Olisa: "I want to be able to measure the amount of downloads at each school
and display that on the ambassador dashboard for them to see."

Apple reports nothing by school. A campaign tag on the tracked links would
count only people who tapped one, and the two posts above carry no link, so
it would miss most of what ambassadors cause. Asked which way to count, Olisa
chose the app reporting its school.

**What the app does.** Once per install, after the student has connected
Canvas, it sends `POST /api/install` to the ambassador site with two things:
the school's Canvas host (`canvas.upenn.edu`) and `new` or `existing`. No id,
no name, no version. Then it never sends again.

- `existing` means onboarding was already complete the first time a build
  with this code launched, so an update on an existing install. Otherwise
  `new`.
- It runs from `RootCore` only: at a cold launch and on each return to the
  foreground, after the update check. Never behind the update wall, never
  from the background wake, never in preview or demo.
- A 2xx or a 400 ends it for good. Anything else retries after six hours.
- A school switch does not report again: one student must not become two.
- Code: `InstallCountReporter.swift` (UI), `InstallCountRule.swift` (Kit,
  pure), the hook in `RootView.swift`. Tests: `InstallCountTests.swift`.
- **Off switch:** `FeatureFlags.installCount`. With it `false` nothing is
  sent and the ambassador row hides itself.

**What the server keeps.** A tally per school per day and no record of any
phone. It counts only the 220 schools in the app's own catalog
(`worker/canvas-hosts.json`, generated from it; a test fails when the two
drift). One network counts at most 300 a day per school.

**What the number means.** Students who connected Canvas on a build that has
the count. It is not Apple's download number. It reads zero everywhere today,
starts when a build with it ships, and should jump at Penn as existing
students update. A reinstall counts again. A student who typed a Canvas
address outside the catalog is not counted. Someone who can script requests
could inflate a school by up to 300 a day per network, which is acceptable
while the number only motivates and not if anyone is ever paid on it.

**Why this needs your attention.** It is the first thing a non-Penn phone has
ever sent us. `docs/PRIVACY.md` has a new section, "One anonymous count:
which school", and its "No analytics, tracking, or advertising" line became
"No tracking or advertising". Two decisions follow, in section 5.

## 4. Degree progress: in the tree, switched off

`FeatureFlags.degreeProgress` is `false` since 2026-11-12. No row in Profile,
no read of Path@Penn, nothing deleted. To bring it back, set the constant to
`true`; the tests that skip themselves while it is off run again.

Before doing that, read CLAUDE.md → Known gaps → "Degree progress": the
options row has never run on a device, the numbers were never checked against
Path@Penn's own page, and the App Store questions (guideline 5.2.2, the
privacy label) are open. `docs/PRIVACY.md` still has its degree section,
headed by a line saying it is switched off. If this build ships with the flag
off, decide whether that section should be published at all.

## 5. Decisions that are yours and Olisa's

None of these was settled in the cloud session.

1. **Does the install count ship in this build?** If yes, the next two items
   have to be done before submitting. If not yet, flip
   `FeatureFlags.installCount` and they can wait.
2. **The App Store privacy label.** The count has no identifier and is not
   linked to a user, but it is data the app sends and we keep as a tally. The
   cautious answer is one new entry: Usage Data → Other Usage Data, not
   linked to the user, Analytics. `docs/appstore/LISTING.md` → App Privacy
   has the paragraph.
3. **The pasted App Review notes.** Every "No analytics, tracking, ads or
   third-party SDKs" line in `docs/appstore/REVIEW_NOTES.md` was true when it
   was pasted and is not true of this build as worded. The replacement line
   is at the top of that file.
4. **Which branch is the base**, `v11` or `v12` (section 1).
5. **The page's copy.** It was laid out in a cloud session from descriptions
   and a few screenshots. The wording is Olisa's ("spam the chats"); your
   copy rule (the least text that works) was applied by someone who is not
   you. Three things to look at:
   - "the job" has three lines and a caption under its button, more text
     than any other section in Profile.
   - The two posts appear twice: under "what works" with the upvotes and the
     reason, and again as the thing to copy.
   - A reply is its own list row with a bordered "copy reply" button. Nobody
     has looked at it on a device.
6. **Whether two posts are enough.** Every ambassador is handed the same two
   on alternate days for good. On one campus that wears out fast, so the
   "borrow the format, not the words" step and the posts a founder sends are
   doing the real work.

## 6. What has been checked, and what has not

**Compiled and tested on the GitHub runner** (the `tests` workflow, run by
hand so the unsigned iOS build runs too): 3,915 tests in 385 suites, all
green, with the iOS build, at `5ad2470` on 2026-11-22. Later commits change
only `smooth-ambassadors/`, `docs/` and notes. CLAUDE.md → Test baseline has
the trail. No test has run on a Mac for this branch since the ambassador work
began. The shared-defaults trap cannot bite on the runner, so your first
local run is the first chance for it.

**The server.** Its own suite passes; the built single-file site matches the
original on every existing route; a rehearsal on the real scan backup passes;
the install route had a security review, whose two findings were fixed before
deploying. After each deploy the live site was read from the cloud session
with GETs only, and no scan total has ever dropped.

**Seen on Olisa's iPhone** (Debug builds installed with
`bash scripts/build-to-phone.sh`):

- The app builds, installs and launches with ambassador mode in it. The last
  build he installed was `7498f4d` on 2026-11-19.
- Sign-in with a real code against the live server, and the page drawing.
- The "messages" list. That is how the stale-plan problem was found.

**Not seen by anyone yet:**

- The reply row and pull to refresh. They landed after his last build.
- "what works", "from the founders" and "help us help you". They need the
  server, which only went live after his last build.
- The feed recording, end to end: that the photo picker hands a screen
  recording over as a file, that readable stills come out of a real iOS
  recording, and how long sixteen take on a two-minute clip.
- The post-result sheet, the posters gallery, the scan-dashboard link and a
  poster idea sent with a photo from the phone.
- The daily reminder firing, surviving the next reschedule pass, and its tap
  landing on the ambassador page from a cold launch.
- The `smooth://ambassador?code=…` link from Safari.
- The page in dark mode.
- The founder page showing what the app sent.
- **The install count.** It has never run on a phone. A Debug build that
  connects Canvas should add one to its school, which is a real count and not
  a test. Penn's "upenn downloads" on an ambassador page is where to see it.

## 7. What is left before this can ship

In rough order.

1. **The decisions in section 5.**
2. **Your pass on the page.**
3. **The device checks in section 6.**
4. **Merge with `v11`** (section 1), then the full suite and an iOS build on
   the merged tree.
5. **App Review.** `docs/appstore/REVIEW_NOTES.md` opens with a paragraph for
   ambassador mode that needs a real test code. Olisa makes one on the
   founder page (an ambassador named for App Review) and pastes it into App
   Store Connect only. Keep it separate from the code you test with, so it
   can be removed later without touching yours.
6. **The version stamp.** `v12`'s `project.yml` says 3.4.1 (20), and 3.4.1 is
   already live. Check TestFlight → Builds in App Store Connect before
   choosing the next number.

Known and left alone:

- A typed-in school outside the catalog is not counted, and a school added to
  the catalog later needs `npm run gen:hosts` in `smooth-ambassadors/` and a
  redeploy before it counts.
- The feed stills are evenly spaced, not chosen: a fast scroll can land
  between posts.
- The website's upload forms ran in desktop Chromium only. iOS Safari and
  HEIC screenshots are untried.

## 8. Commands

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
live roster and sends you its code directly. It is not written here because
this repository is public. That test ambassador is at UVA, so the posters,
numbers and downloads you see are UVA's; ask Olisa to add you at Penn on the
founder page if you would rather test as yourself.

## 9. Text for a new Claude Code session on your Mac

```text
Read CLAUDE.md, then ROADMAP.md, then docs/HANDOFF_V12_MARCO_2026-11-12.md.
I am Marco. Olisa handed me v12 for the finishing touches on ambassador mode
(Profile → ambassador mode) and the per-school download count. Degree
progress is switched off on purpose (FeatureFlags.degreeProgress = false);
leave it off.

First: check out v12, run `cd LowHangingFruitKit && swift test --no-parallel`
alone on this machine, and tell me the count against CLAUDE.md → Test
baseline (3915 / 385). Then build to my phone with
`bash scripts/build-to-phone.sh`.

Do not merge v11 and v12 until I say which is the base; section 1 of the
hand-off lists what conflicts. Do not open any /scan/ or /r/ link on the live
poster site, and never write an ambassador code into the repository. The
install count (FeatureFlags.installCount) sends one real count per install:
tell me before a build with it on goes onto a phone that has not reported
yet. Design changes go on their own branch until I approve them.
```
