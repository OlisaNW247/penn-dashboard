# LHF (Low Hanging Fruit), shipped as **Smooth**

## Start here: every session reads this file, and updates it before it ends

This file and `ROADMAP.md` are the project's memory. Sessions don't remember
each other; these two files are how the next one knows what this one did.

**At the start of a session:** read this file top to bottom, then
`ROADMAP.md`. Treat both as claims to re-check rather than facts: when a
line here disagrees with the code, the code wins, and fixing the line is
part of the job. The release number below has been stale before.

**Before a session ends (or before the last commit of a piece of work),
update them.** What goes where:

| Changed | Update |
|---|---|
| What the app does (a screen, a setting, a feature added or removed) | **What the app does**, below, and **Done recently** in `ROADMAP.md` |
| The test count after a verified run | **Test baseline** (count, date, branch, how it was run) |
| A new or merged branch; a new ship line | **Branches** |
| A bug that looked like something else, or a fix whose wrong version was tempting | a new entry in **Traps that have already bitten** |
| Something still unverified on a device, or known broken | **Known gaps**, and **Now** in `ROADMAP.md` if it blocks a release |
| A privacy-relevant behaviour (what leaves the phone, how to delete it) | the intro below **and** `docs/PRIVACY.md`, in the same commit |
| A plan, idea, or experiment set aside | `ROADMAP.md` (**Next**, **Later**, or **Tried and parked**) |

Keep the register: prose that says *why*, dated when a fact can go stale
(`2026-09-24`, never "yesterday"). Replace a stale line; don't append a
contradiction beside it. Commit these files with the change they describe,
not in a separate "docs" commit later.

---

A personal academic dashboard for college students. It reads the student's
own **Canvas** (calendar feed plus their signed-in session) and
**Gradescope**, merges them into one chronological "what's due" list, and
sends local reminders. (It tracked grades too until the owner took Grade
Watcher out of the app on 2026-10-18; the grade fetch still runs, for the
reasons under "What the app does".) SwiftUI, iPhone-first, and it also builds
for macOS from the same source. The user-facing name is **Smooth** (since
2026-09-12; it was **Locust** from 2026-09-09). Display names and copy only:
bundle ids, module names, App Group names and defaults keys keep their LHF
names.

**Schools.** As of 2026-10-28 onboarding searches 220 curated US university
Canvas sites locally, ranked by name and aliases with bounded typo matching.
Specialized live-directory programs are excluded. Any other HTTPS Canvas
address can be entered manually. Catalog sources and limitations live in
`docs/canvas-directory/`; authenticated support is not proven for all sites. Everything
server-side is Penn-only for now: pooled course materials, the server path
of ask, the announcement AI assist, and "stay signed in" (PennKey).
Non-Penn installs run fully on-device, because the backend keys course
material by numeric Canvas course id, and two schools' ids would collide.

**Privacy posture; say it this way.** "The student's own data stays
on-device; course material is pooled server-side; ask has an on-device
fallback." Grades, completions, submission state, the work list, the
student's name, and Canvas/Gradescope cookies never leave the phone. Since
2026-11-02 (blind) a question to the tree also carries the earlier turns
of the conversation on screen (the last three exchanges, the student's
words and the answers shown, dropped when the screen closes, stored by
nobody), so "you missed that" and "what about that class" mean something
to the model; `docs/PRIVACY.md` says so. The
one exception, since 2026-10-22: a student who pairs the Chrome extension
shares completions, due-date edits, their own tasks and the work list
with their own laptop **end-to-end encrypted** (AES-256-GCM, a key that
goes from the laptop's screen to the phone's camera and never to the
server); the server stores ciphertext it cannot read. Name, reminder
settings and grades are never in it. Backend requests carry the app's
marketing version (`X-Smooth-Version`, since 2026-10-27) so the server can
refuse builds below the update floor; it is the same for every copy of a
release. The feedback card and Profile row (3.3.0) open a
Google Form in Safari; the app adds nothing to the link. The
PennKey password is saved automatically (since 2026-10-23) after a verified
Penn Canvas sign-in inside the app's own login page, with a one-line
disclosure above that page; it stays in this phone's Keychain
(this-device-only, never synced) and only ever goes to Penn's login page. Since 2026-11-04 (written, not
deployed) the pooled course material is also read once per revision by a
model on the server for course-level "facts"; they belong to the class,
carry no user id, and a student's AI-assist switch does not stop them
(`docs/PRIVACY.md` says so). The phone also reads Canvas's own structured
endpoints (Planner, module completion, section dates) with the student's
session and keeps the results on the phone. Since 2026-11-10 (built, never
on a phone or against Canvas) a student with the agent connection on also
polls their agent's open drafts, keeps a content-free list of them in
`UserDefaults.lhf` (`agentDraftsCacheV1`), tells the server when a draft
was seen, declined, submitted or failed, and submits a draft to Canvas from
the phone with their own session; the server never sees the session and
the phone sends it only the outcome. There is no analytics, tracking,
or third-party SDK. Don't say "everything is on-device" (untrue since
`assistant-ui`) or "no server" (untrue since the backend). `docs/PRIVACY.md`
is the student-facing version and must change in the same commit as any
behaviour it describes.

**The backend.** A small Supabase project (Postgres plus Edge Functions;
`backend/PROTOCOL.md` is the contract). Every Penn install talks to it
through an anonymous account created on first launch: no email, no
password, no name. Two things go through it:
- **Course materials.** Syllabus, course pages, modules, assignment
  descriptions and announcements are fetched from Canvas with the student's
  own login, then pooled per Canvas course so classmates share one copy.
  Since 2026-11-10 (blind) the PDFs an instructor links from an assignment's
  description are pooled too: at the end of a successful
  `refreshCourseKnowledge`, `attachmentPass` (`AppState+AssignmentAttachments.swift`;
  planning in `AssignmentAttachmentPlanner.swift`, fetching in
  `CanvasFilesClient.swift`, the document in `AssignmentAttachmentRunner.swift`)
  reads each linked file id from open or just-past assignments, fetches PDFs
  under 10 MB and uploads them as `file` documents, the shape the Chrome
  extension makes. The student's own uploads and submissions are never read.
  Sync is automatic: after Canvas connects, then on the refresh loop with
  hourly staleness. There is no manual sync. Since 2026-10-02 (`v8`, not
  yet verified on a device) the same sync also reads **Ed Discussion** for
  any class whose Canvas site has an Ed tool: the app performs the tool's
  LTI launch in a hidden WebView (with the Keychain's Canvas cookies
  injected first, or the launch bounces to Penn WebLogin), reads Ed's
  session token out of the landed page's `localStorage` (since
  2026-10-09; Ed keeps no session cookie) into the Keychain
  (`EdSessionTokenStore`, with any Ed cookies in
  `SessionCookieStore.Service.ed` as a fallback), reads the board with
  `EdClient` (`x-token`), and keeps only announcements, pinned threads
  and staff posts (`EdThreadFilter`) as documents of kind `ed`. Student,
  private and anonymous posts never leave the phone; no author is ever
  named. `docs/ED_DISCUSSION.md` is the design record;
  `FeatureFlags.edDiscussion` is the kill switch.
- **ask** ("the tree"). Questions go to the backend with the on-device
  context document and matched excerpts, and are answered by a model via
  OpenRouter under LHF's own key (see the ask section below). The
  Announcement Watcher's AI assist is routed the same way, only for
  announcements that an on-device gate judges could carry a task, and
  (since 2026-10-23, on `fix/megaphone-every-class`) for at most six
  instructor/TA Ed posts a day, judged only for whether they still matter.
  Each answer also carries a short "until when this matters" note, which
  the phone keeps and the server does not. Since
  2026-10-18 that covers Ed announcements and pinned posts too (title and
  body, no author, once each, never for a hidden class), under the same
  switch and the same gate; the text is what the pool already holds. (For
  one day, 2026-10-19, the Canvas loop also read plain staff posts; the
  merge of 2026-10-20 kept Marco's Ed pass, which does not.) It is on by
  default, and a student can turn it off under Profile → notifications,
  which `docs/PRIVACY.md` promises. Neither questions nor answers are
  stored, only per-user daily request counts and token totals.

Disconnecting Canvas deletes the student's enrollment/usage rows and
anonymous account from the backend. Since 2026-09-24 there is no separate
delete button; the disconnect confirmation says so. Offline, over quota, or
with the backend unreachable, ask answers on-device:
`OnDeviceAssistantResponder` computes exact answers from the dashboard's
items, retrieves policy and content answers from synced course materials
(`CourseKnowledgeCollector` → `CourseKnowledgeStore`), and on iOS 26 /
macOS 26 Apple Intelligence devices rephrases via Apple's on-device model
(`OnDeviceLanguageModel`). Fourteen Edge Functions are in
`backend/supabase/functions/`, all fourteen deployed: `ask`,
`ask-canary`, `delete-account`, `device-sync`, `discover-websites`,
`extract-announcement`, **`extract-facts`** (2026-11-05), `extract-profile`,
`map-categories`, `pair`, `sync`; and the three of the v11 agent connection,
**live since 2026-11-08 about 03:00 UTC (the night of 2026-11-08 US
Eastern), at Olisa's go relayed by Marco; redeployed 2026-11-10 about
06:30 UTC at Marco's "Yes, deploy" as `agent-auth` v5, `mcp` v3,
`agent-snapshot` v3 with migrations `20261109090000_agent_hardening.sql`
and `20261109100000_agent_drafts.sql` applied (rate limits, sweeper,
approve and deny bound to lookup, the drafts backend, the assignment
context)**; then **`agent-auth` v6 and `mcp` v4 on 2026-11-10 about 07:45 UTC at
Marco's "Yes, deploy"** (the sign-in page's "Connected to Smooth, returning
to <agent>" state before the redirect, and explicit annotation hints on every
read tool; no migration; the 14-step `agent-e2e.mjs` probe, drafts included,
passed on them); then **`mcp` v5 about 19:00 UTC the same day** (each attachment
listed once in `get_assignment`); then **`agent-auth` v8, `mcp` v7, `agent-snapshot` v5 about
20:40 UTC with migration `20261110090000_agent_uploads.sql`** (files from an
agent in checksummed 16 KB chunks or by one signed PUT, after claude.ai
refused to transcribe a 57,000-character base64 PDF; the probe's upload leg
passed on production with 100 KB chunked, one chunk resent, and 50 KB PUT) (`node backend/scripts/deploy-agent.mjs --public-base
https://smooth-agent.vercel.app/functions/v1`): `agent-auth` (our own OAuth
authorization server, the phone approves each connection), `mcp` (the
remote MCP server Claude connects to) and `agent-snapshot` (the opted-in
student's work list), from `agent/connection-v11`, `backend/PROTOCOL.md` →
"The agent connection". The first two run with `verify_jwt = false`
(`config.toml`, `deploy-function.mjs`). Their public face is **the
connector front, `https://smooth-agent.vercel.app`** (a Vercel Edge
Function under Marco's account, `backend/connector-front/`), which serves
the root OAuth discovery documents Claude needs and forwards to the two
functions; `LHF_AGENT_PUBLIC_BASE` names it, so the issuer and MCP URL are
`https://smooth-agent.vercel.app/functions/v1/agent-auth` and `.../mcp`. Marco's claude.ai signed in against production on 2026-11-09.
Written on `claude/v11-backend-645aa0` on 2026-11-10 and **not deployed**:
the sign-in page's "Connected to Smooth" state and explicit annotation
hints on the read tools (`agent-auth`, `mcp`; no migration). `extract-facts` (written 2026-11-04 on
`v10`, **live since 2026-11-05 01:20-01:45 UTC**, the evening of
2026-11-04 US Eastern; version 1, with the `sync` that serves its facts at
version 17 and migration `20261104090000_course_facts.sql` applied; the
prompt's round 4, the stale-document rule, is live since 2026-11-05 21:13 UTC
as `extract-facts` v5 and `sync` v21) reads each pooled course document once per
revision with Claude Haiku 5.5 and stores the course-level changes it states
in `course_facts` (a cancelled item, a new date, a new task, each with a
quote); the manifest serves them to every enrolled classmate. No user id is
in any fact (see "Facts and structured sources" under Architecture). `pair` and
`device-sync` (the Chrome extension's pairing and encrypted sync) and the
`20261022090000_chrome_extension.sql` migration went live on 2026-10-22
with Olisa's go (`sync` v11, `delete-account` v6); `extract-profile` v8
and `discover-websites` v4 followed on 2026-10-23, also at his go, so
every function that resolves a caller now knows a paired laptop. `sync` v12 (the
window-kind rules of `docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md` Phase 2) went
live on 2026-10-23 at Olisa's go, about 16:00 UTC; before it the pool held
40 live announcement documents, every one from spring 2026, and 97 Ed.
`sync` v13 went live on 2026-10-27 at about 14:22 UTC, at Olisa's go: v12's
own source (`a2e2b1b`) plus the NUL guard in `validateDocuments`, deployed
from a worktree on purpose so that `v8`'s undeployed `sync` changes (the
server exam dates) did not ride along. `sync` v14 and `discover-websites` v5
followed the same day at Olisa's go, with migration
`20261027150000_server_collector.sql`, from the same v12 base plus both
patches (exam dates still left out): crawled website rows are stamped
`collector = 'server'` and no client's complete-set report retires them.

**Visual language.** Marco's Smooth design: a white paper ground with
tomato/marigold/lemon/teal/cobalt/grape accents, an "after sunset" dark
mode, the S app mark, and bundled type registered at runtime by
`SmoothFontRegistry` (`RedesignTokens.swift`):
- Satoshi (Fontshare FFL).
- Inter, Familjen Grotesk and Space Mono (all SIL OFL, licence files beside
  them in `Resources/`).
- Roobert SemiBold for the dashboard title: a commercial face from
  Displaay, cleared for shipping on 2026-09-15 under a personal agreement
  Olisa holds. There is deliberately no licence file in the repo; the
  agreement is Olisa's to produce if it is ever asked for.

**Release state.** Live on the App Store: **3.4.1 (build 20) since 2026-11-08
at 22:29 UTC** (public iTunes
lookup, read 2026-11-10), and the `update-manifest` floor is 3.4.1 (read the
same day; `sync` refused a 3.4.0 install with 426 at 03:49 UTC on 2026-11-10,
as designed). Before it, 3.4.0 (build 17), released 2026-10-28 at 21:43 UTC.
**3.4.1 (build 20) was archived from `v10` `c3a4feb` and uploaded at 16:39 EST (21:39
UTC) on 2026-11-07** ("Upload succeeded"; it supersedes build 19 (`5bc1a9f`,
15:38 EST the same day, before the sheet listed every post) and build 18
(`bd9d20c`, 2026-11-06, before the megaphone redesign and the final-exam
dedup); attach 20), after 3708/353 Swift, Deno 713 and
the iOS simulator build on the same tree, and after the facts backend was
redeployed from the same commit (`sync` v22, `extract-facts` v6, the
`finish_fact_extraction` migration applied). `sync` is at **v25 since 2026-11-10
about 08:00 UTC** (Marco's "Yes, deploy sync"; v24 was deployed on
2026-11-06 by someone else, without a note here): v24 plus the rule that a
client report listing no `file` ids cannot retire a course's file rows,
which the phone's assignment-PDF pass needs; a throwaway user's manifest
round trip passed on it. The Debug build of the same
tree is on Marco's iPhone 17 Pro since 14:06 EST the same day, over the 3.4.0
(17) store copy, so the App Group container is readable again. Marco created the 3.4.1 version
record (done; live 2026-11-08), attached build 20, pasted `docs/appstore/LISTING.md` → What's New in
3.4.1 and submits; the floor automation raises `update-manifest` six hours
after it is live. What 3.4.1 carries beyond 3.4.0 is listed in
`docs/appstore/CHECKLIST.md` → "3.4.1 (18) submission". Before 3.4.0: **3.3.0
(build 16)** (App Store id `6783911002`), released 2026-10-27 at 22:37 UTC per
the public iTunes lookup, read 2026-10-28. It still carries the launch crash recorded in
`docs/LAUNCH_CRASH_2026-10-26.md` (Known gaps) and the notification-tap
crash; **3.4.0 (17)** from `release/3.4.0` fixes both (it also carries the
onboarding work of PR #16; 3.3.1 was stamped but never uploaded). Before
it, **3.2.1 (build 15)**, released 2026-10-25 at 18:46 UTC, the build the
launch-day installs of 2026-10-26 got. Before it, **3.2.0 (build
14)**, live per Olisa on 2026-10-25. Before them, **3.1.0 (build
13)**, released 2026-10-21 at 19:07 UTC per the public iTunes lookup, read
2026-10-23
(`curl -s "https://itunes.apple.com/lookup?id=6783911002"`); before it,
3.0.0 (11) from about 2026-10-01 and 1.2.1 from 2026-09-04. This line has
been stale before, so re-check it rather than trust it. 3.1.0 (13) is the
release the owner asked to send straight to App Review on the evening of
2026-10-20: the Smooth Sweeper, the exam cards, the megaphone redesign,
Ed posts, the ask work and the sign-out fix, with Grade Watcher removed.
It was **archived from `1450fdc` and uploaded at 19:11 on 2026-10-20**
(`docs/appstore/CHECKLIST.md` → "3.1.0 submission"). To read the
released source, check out `1450fdc`, not the `v8` tip.
**3.2.0 (build 14): archived from `a9af3ad` on `fix/megaphone-every-class`
(PR #13: all of `v8` `fb3ed94` plus the megaphone, Ed and keep-check
work) and uploaded to App Store Connect at 18:18 EDT (22:18 UTC) on
2026-10-23** ("Upload succeeded"; the Release widget's AlarmKit link
checked weak first), at Marco's say. Attaching it to a 3.2.0 version and
submitting for review is Marco's step in App Store Connect. He did: on
2026-10-24 App Store Connect called 3.2.0 "previously approved" and its
train closed. Whether it is released yet is not recorded (the iTunes lookup
is unreachable from the cloud container). **3.2.1 (build 15)** is the same
release line plus the Smooth Sweeper settings and the takeover fix, stamped
3.2.0 (15) first; its export was refused at 20:52 EDT on 2026-10-24 because
the 3.2.0 train is closed, so it was restamped 3.2.1 (15) the same evening
(`4fe7a4f`), **archived from `4fe7a4f` and uploaded at 20:57 EDT
(00:57 UTC 2026-10-25)** ("Upload succeeded"; the widget's AlarmKit link
weak). Creating the 3.2.1 version record, attaching build 15 and
submitting are Olisa's steps in App Store Connect; whether done is not
recorded here yet (`docs/appstore/CHECKLIST.md`, top). The What's New in `LISTING.md` leaves out the AI
judgments and the server exam dates until `extract-announcement` and
a `sync` carrying them is deployed (v14 or later; v13 is the NUL guard
alone, see below) (`docs/appstore/CHECKLIST.md` → "3.2.0 (14)
submission"). PR #13 was not yet merged into `v8` at upload time; the
archived commit is reachable from the branch until it is.
**3.4.0 (build 17)** was **archived from `69efb63` on `release/3.4.0` (tree identical to `v8` `316bd28`, the merge of PR #16) and uploaded at 14:55 EDT (18:55 UTC) on 2026-10-28** ("Upload succeeded"), after 3399/327 Swift, 614 Deno and the signed iOS Debug build on the same tree. App Store Connect accepted build number 17, which confirms 14–16 were the only ones taken. Marco creates the 3.4.0 version record, attaches build 17, pastes the notes from `docs/appstore/LISTING.md` and submits with expedited review; the floor automation then raises `update-manifest` once 3.4.0 is live. 3.3.1 (17) was never uploaded. **3.3.0 (build 16)**, the feedback card and Profile row plus the hardened update lock, was **archived from `11a4381` on `claude/sharp-newton-qwv18v` and uploaded at 12:40 EDT (16:40 UTC) on 2026-10-27** ("Upload succeeded"), after 2933/264 green and the iOS Debug build on the same tree. Olisa created the 3.3.0 version record, attached build 16 and submitted it for review on 2026-10-27, per his word that day; it was approved and **released at 22:37 UTC on 2026-10-27** (public iTunes lookup, read 2026-10-28), so **3.3.0 (16) is what is live**. It carries neither the duplicate-category launch-crash fix nor the notification-tap crash fix: both ship in **3.4.0 (17)** from `release/3.4.0` (`docs/RELEASE_3.3.1_PLAN.md`, which also records the rename to 3.4.0), after PR #14 and PR #16 landed in `v8`. The live manifest has carried the feedback object (`2026-10-smoothie`) since the same day, checked against the sanitizer's rules; builds below 3.3.0 ignore it.
3.0.1 (12) was stamped on 2026-10-09 for the sign-out fix alone and never
archived. The `update-manifest` floor is **3.3.0** since 08:52 UTC on
2026-10-28 (`f133993`, the `update-floor` workflow's automatic run, about
ten hours after 3.3.0 went live rather than six). Before that it was 3.2.1
from 2026-10-27 (`9a49cc5`, the workflow's first real run, at Olisa's
word), 3.2.0 from 2026-10-25 (`feec931`) and 1.2.1 from 2026-09-09. Every
gated build below 3.3.0 shows the update wall, so until 3.4.0 is live every
student is held on the build with the launch crash. From here the workflow raises it on each
release (Update gate, below). Marco's
read of the public iTunes lookup on 2026-10-08
(`curl -s "https://itunes.apple.com/lookup?id=6783911002"`) put 3.0.0
(build 11) live since 2026-09-28 at 17:34 UTC, the date `v8`'s notes round to
"about 2026-10-01"; the floor then was 1.2.1, as now. Builds 7–9 of 3.0.0
were uploaded from `v5` and none was released (build 8 was rejected under
2.1(a), see Known gaps). Build 10 was uploaded 2026-09-16 at 9:54 AM,
from before stay-signed-in existed, and attached to that rejected
submission but never resubmitted. Build 11 is the first from `V7`
(uploaded 2026-09-27, with Olisa's session logic restored; see the
24-hour trap). App Store Connect refuses an upload whose build number is
not higher than every build it has seen, so check TestFlight → Builds
there, not this file, before picking the next one.

App Store Connect, as left on 2026-09-27 (re-check it): the app is
"Smooth For Students", team Stem Forward Co., whose Account Holder is
Olisa's Apple ID. The updated Apple Developer Program License Agreement
was accepted that day with Olisa's OK; until the Account Holder accepts a
new one, Apple blocks every submission. The iOS version record was
renamed 2.0.0 → 3.0.0, and its What's New and review notes were saved
(the notes as pasted are at the top of `docs/appstore/REVIEW_NOTES.md`).
Marco was finishing by hand: remove 3.0.0 from the old rejected
submission `067299d2…`, swap build 10 for 11, then Add for Review →
Submit. He did: it was approved and released automatically on 2026-09-28
(Release state, above). The `update-manifest` floor stayed at 1.2.1 until
2026-10-25 (see above). macOS 1.0 shows "Ready for
Distribution" there (reviewed 2026-08-30), whatever older docs say. On launch the app fetches a public update-policy file that can
require an update (`Update/`, below).

## What the app does

Screen by screen, as of 2026-10-20 on `v8` (Olisa's `v8` and Marco's
`v8-loud-alert-actions` merged; compiled green and on Olisa's phone, see
Test baseline).
Keep this current. It is the fastest way for a new session to know what exists.

- **Onboarding.** A three-beat intro (`MissionIntroView`: since 2026-10-30
  the first pane's scattered chips gather into an ordered list 0.9 s after
  it appears, replaying on re-entry and skipped under Reduce Motion, and
  the third pane lists Dashboard, Reminders and Ask only; Grade Watcher
  was dropped from it). Then `OnboardingView`'s walk:
  1. university search (220 curated Canvas sites; manual address fallback)
  2. Canvas login (WebKit, the school's own SSO; Penn is PennKey + Duo),
     detection unchanged since 3.3.0
  3. optional Gradescope choice: Continue with Canvas only / Connect Gradescope
  4. reminders, which since 2026-10-20 ends with a **"smooth sweeper"**
     section under "turned in notifications": one line in ink ("an alarm
     10 minutes before anything you haven't turned in.") and the switch
     itself (a second, parenthetical nudge line was cut 2026-10-30) (`NotificationScheduler.loudAlertEnabled`, on by default, the
     same preference Profile → reminders shows as "Smooth Sweeper"). It
     was a page of its own for a few hours that day; the owner saw the two
     pages on his phone and had them combined. A student who taps "skip
     reminders for now" with the switch on has a sweeper that cannot ring
     until reminders are on, as before. Three progress dots (canvas,
     gradescope, reminders); the school picker has none.
  5. a per-course setup walk (`OnboardingCourseSetup`)

  The intro's "Preview" link (centred under "Get started" since
  2026-10-30) and the "preview with sample data" footer on the school
  search pane open demo mode, App Review's only way in (see Known gaps).
  The Canvas login pane carries no door since 2026-10-30 (owner's call: a
  student at the real login sees only the login); Back from it returns to
  the school pane, which does.
  The bottom panel hides while the iOS keyboard is open. A reconnect from the
  dashboard banner opens the Canvas login directly; the school picker is
  behind the back chevron, and since 2026-10-09 (blind) picking a
  different school there asks "switch school?" first, because it signs
  the student out and forgets the saved password and Duo trust. A student can instead
  paste a Canvas calendar link (`PasteFeedLinkSheet`); that install gets
  the feed but no session. Since 2026-10-18 Profile → accounts shows a
  "sign in to canvas" button under the canvas row for exactly that state
  (connected, no saved login, not preview), because no banner appears
  there and Grade Watcher's reconnect button is gone. At Penn, the PennKey
  sheet is **"the vault"** since 2026-10-18 (`PennKeyCredentialsSheet`): a
  vault-door emblem that clunks shut once as the sheet opens (drawn
  already shut under Reduce Motion), the same one line about the
  Keychain, the two fields. It was a lock icon under "stay signed in to
  canvas". Only the look changed. **Since 2026-10-23 it is
  no longer offered after the Canvas login**: the login saves the PennKey
  itself ("Stay signed in", below), the onboarding step after a connect is
  a "Canvas connected" page ("Disconnect at any time in Settings") with
  Continue, and the vault is only the repair tool Profile → accounts
  opens through "update password" once Penn has rejected a saved password.
- **Dashboard** (`ContentView`):
  - **Header.** The "Smooth" wordmark and the weekday. Tapping the wordmark
    ripples its squiggle and sweeps a shine across it. The **Sweeper**
    broom (tomato, a small dark-red dot while it is on; since 2026-11-10 on
    `v11`), the **megaphone** and a profile button sit beside it. All
    three are 42pt squircles with 8pt spacing on `v11` (48pt with two)
    (continuous corners, radius 0.32 × size; owner's call 2026-11-06; the
    control row's filter and + stay round). Since
    2026-10-18 the megaphone is here, where the grades button was, and
    always shows (an empty list says "no announcements"); the grades
    button is gone with Grade Watcher (below).
  - **Banners.** A sync error ("couldn't sync") and, since 2026-10-10,
    "not saving on this phone" when the ledger is running in memory or
    its last save failed (`StorageHealth`; never in preview or demo
    mode). There is **no Canvas sign-out banner any more** (owner's rule,
    2026-11-02: the student signs in once and the app fixes what breaks
    silently). In its place one small status line under the banners, no
    card (`AppState.canvasSessionStatusLine`): "slow connection ·
    reconnecting" once a silent renewal has run 3 seconds, "approve the
    duo push on this phone" while a push waits, and the three the student
    must act on: "pennkey password changed · update in profile" (opens
    Profile), "duo needs you · tap to finish" and "sign in to canvas"
    (no login and no saved password), both opening the sign-in as a cover
    over the dashboard, with an xmark to close it (it does not restart
    onboarding; the lock-out trap below). The 24-hour clock,
    `canvasSessionExpired`, the confirmed-dead latch, a dead probe and a
    failed, timed-out or landed attempt never produce a line; that is the
    point. A "reconnect gradescope" banner
    (since 2026-10-27, hardening A4) appears only after a real login page
    was seen on two syncs an hour apart, and opens the same cover.
  - **Control row.** A full-width **todo · all · prev** switch
    (`DashViewPicker`), then a **class filter** menu (narrows all three
    views, with a clearable chip under the row), **+** (a plain `plus`
    glyph since 2026-10-30, `calendar.badge.plus` before; the add sheet: a
    one-off or weekly assignment, class picked from a grid of per-class
    coloured chips, `CoursePicker`). The **megaphone** used to be a fourth
    control here and moved to the header on 2026-10-18, where its circle
    is marigold (the class filter beside the switch is cobalt: ink glyph on
    a cobalt fill, like the tomato add button). It opens
    `AnnouncementFindsView`, which since 2026-10-18 is two lists under the
    page header and a class filter (the dashboard's own `ClassFilterMenu`,
    default all classes, not remembered):
    1. **found**: the tasks the Announcement Watcher found in Canvas
       announcements and Ed posts, and the exams the class has found
       (the syllabus's too), that are still ahead: not finished and not
       hidden by the dashboard's own rule (`isHiddenAnnouncementTask`:
       past, undated a week after its post, or a same-day reminder, see
       "Which announcement tasks show"). Drawn as the dashboard's own `AssignmentCardView`
       (exam cards keep the exam look; swipe to finish; "edit date"
       works), soonest first, one card per exam when the syllabus and an
       announcement both name it. A "NEW" tag sits beside the class.
       Hidden when empty.
    2. **announcements**: the Canvas announcements and the Ed
       announcements and pinned posts from the **past 7 days, plus each
       class's newest post** however old (since 2026-10-23, so a class
       that posts rarely, or only on Ed, never vanishes), newest first,
       across classes. On top of that standing set sits the **keep-check**
       (`announcementRecordsForSheet`): a post is taken off once it is
       over (its judged event has passed, or every task found in it is
       finished or past, which needs no AI), and an older post comes back
       while it still matters (judged `standing`, an `event` ahead, a
       `task` still open). An Ed staff post lists only while judged to
       matter (an event or due date ahead). The judgments come from
       `extract-announcement`'s `relevance` field, once per post, stored
       on the phone (`AnnouncementRelevanceStore`); completion state never
       leaves the phone. A row is class, date ("ed" beside it for an Ed
       post), title, a one-line preview, an arrow and a "task found" tag
       when a find came from it; the whole row opens the original. Empty
       says "no announcements". A find whose real Canvas/Gradescope twin
       is finished leaves the found list too
       (`announcementFindsWithFinishedTwin`). Since 2026-10-23 two rows of
       class **bubbles** sit at the top, wrapped so every class shows
       (only classes switched on; a program site such as "TAP 2028" is
       never a class anywhere in the app, `NonClassCanvasSite`) ("all", preset on every open,
       then one per class; tap a class to switch to it, tap more to add
       them, tap a selected one to drop it). With classes selected the
       two lists become **one compiled list**, newest first, each find
       directly above the post it came from
       (`announcementSheetCompiled`, `announcementSheetTap`). Judgments
       for posts read before the server gave them are **backfilled**,
       relevance only, sharing the 6-a-day budget, and only once this
       install has seen the server return one (`serverJudgesRelevanceV1`,
       `AppState+RelevanceBackfill.swift`).

    The dismiss button says "back to assignments". What each list holds
    is decided in `AppState+AnnouncementSheet.swift`
    (`announcementFoundItems(now:)`, `announcementSheetRecords(now:)`),
    read-only over the same rows as before; the window and the
    keep-check are display only, the log still keeps 60. Before 2026-10-10 the sheet listed only
    extracted tasks and hid itself when there were none, which read as
    "announcements are missing".
    The Canvas rows are an on-device cache (`AnnouncementLogStore`,
    `announcement-log.json` beside the course-knowledge file; title,
    class, date, link and a 280-character preview; cleared on
    disconnect), filled by `syncAnnouncements`, which asks Canvas
    for 60 days back *through tomorrow* (see the announcements-window
    trap). The Ed rows are built at display time from `.ed` course
    documents (`EdDocumentHeader`), never written to that file, and the
    list follows `$courseKnowledge` without the sync calling it.
    Extraction, including the AI assist, still only ever sees the last
    14 days. For an Ed post that is 14 days since it was *posted*: the
    posting day its document's header names (`CourseDocument.shownPostedAt`
    through `AppState.edPostDate`, since 2026-10-19, written without a
    compiler), and the thread's last activity only for a document synced
    before that. The badge counts
    exactly what the sheet can show: unread found items plus unread
    listed posts, so it never counts a passed task or a post the sheet
    does not list. Rows unread when opened are tagged NEW
    (`AnnouncementReadState`, which marks only the shown rows seen), and
    the first fill of each kind on an install counts as already seen. The
    badge caps at "99+" (VoiceOver still gets the true count). Since
    2026-10-20 (afternoon, blind) the count is stored
    (`AppState.announcementBadge`, written by `refreshAnnouncementBadge`
    at the end of every rebuild, after every change to the log, the Ed
    records or the seen set, after a due-date edit, and on the 5-minute
    refresh) rather than computed on every read: see the freeze trap.
  - **todo**: overdue plus the next two days. Tasks found in
    announcements are cards here and in all (see the bullet after prev).
    For someone who signed up
    on or after the 2026-10-09 build, unfinished Canvas/Gradescope work
    that was already more than 7 days overdue at their first sync is
    withheld from todo, all, the widget and ask (`SignupBacklog`; a
    set-once cutoff in `UserDefaults.lhf`, `signupBacklogCutoffV1`). The
    decision is taken beside the sync, never inside it: at `init`, an
    install whose ledger already holds feed rows, or that had finished
    onboarding when this build first launched (`signupBacklogSeenV1`),
    records a "hide nothing" sentinel and sees no change; otherwise the
    first `rebuildDashboardItems` that sees real feed items records
    "now minus 7 days". Nothing is deleted, finished work still reaches
    prev, and manual work is never hidden.
  - **all**: future work through the term.
  - **prev** (`DoneView`): leads with "N down this week", shows this week's
    finished work, and opens "earlier this semester" in place. Finished work
    only: a task found in an announcement that went by unfinished is not
    here. (For part of 2026-10-18 prev listed those as "past", and the
    owner's phone filled with tasks already taken; they now leave the
    dashboard entirely, see the tasks bullet below.) A *finished*
    announcement task is ordinary finished work and stays.
    Work the sign-up rule withholds has no way back from prev since
    2026-11-06: the owner removed the "N older hidden · show" line as
    ugly. `signupBacklogRevealedV1` still holds whatever a phone had
    chosen before.
  - **Tasks found in announcements** (2026-10-18, owner's call; not yet on
    a phone). Canvas announcements (`syncAnnouncements`) and Ed
    announcements and pinned posts (`AppState+EdAnnouncementTasks.swift`,
    triggered after the course knowledge changes and once at launch) are
    read for tasks by the same extractors, the same "ai assist" switch and
    the same on-device gate, once per post (`processedAnnouncementIDs` holds
    both kinds of id). Each task, submission or preparation, dated or not,
    is a card for a class whose per-class "announcements on dashboard"
    switch is on (the default; it now governs Canvas and Ed together). A
    task whose own wording reports something done ("grades posted") stays
    megaphone-only, and a preparation task (`.event`) still answers to the
    class's "items with nothing to submit" switch. An undated task sits
    under "later" in all like any undated item, for seven days after its
    post (next bullet). Rows are `.canvasAnnouncement` ledger rows; an Ed
    one has an `ed-` sourceID (`AnnouncementOrigin`), which gives "from ed"
    and "open in ed" on the card. It is a prefix and not a new
    `Assignment.Source` or a new column on purpose: an older build maps an
    unknown source to `.canvas` (the wrong source, and an id that no longer
    matches the stored one), and a schema change makes an older build fall
    back to an empty in-memory ledger. The same task on Canvas, on Ed, or
    already a Canvas assignment is one card (`resolvingAnnouncementDuplicates`
    with a fixed survivor order: not hidden by a rule, then dated, then Canvas,
    then id). Two announcements are one task only on the same day (dates
    within `AssignmentDeduplicator.similarTitleDueDateTolerance`, about 26
    hours, or one undated): the same title for the 6th and again for the
    20th is two tasks. A tick on the hidden twin carries to the shown one
    only between copies of the same day (`completionFollows`), never across
    a gap, a reschedule included. A Canvas post that stops
    coming back inside the fetched window has its rows flagged
    `isGoneFromFeed` and its cards hidden (`reconcileAnnouncementPresence`;
    evidence is the announcement log's posted date; an empty fetch judges
    nothing, and so does a class the fetch returned no post for; a post
    must be missing from two judged fetches in a row, counted in
    `announcementMissCountsV1`; a finished task stays in prev; a post that
    returns restores them). The flag never deletes: the store's aging rule
    exempts announcement rows (Traps). An edited due date stays while its
    row is hidden. Ed deletions are not detected, see Known gaps.
  - **Which announcement tasks show** (2026-10-18, owner's call, after the
    phone filled with stale ones: "Take quiz covering assignments 1 and 2"
    from a Sept 14 Ed post, "Attend the weekly rotation quiz"; "none of
    these previous ones are honestly helpful"). Visibility rules,
    evaluated at every rebuild by `AppState.isHiddenAnnouncementTask`
    (`AppState+AnnouncementTaskRules.swift`); an unfinished task they hide
    is in todo, all and prev **nowhere**, and the ledger row is never
    deleted or flagged, so it returns the moment a rule stops matching:
    1. **Past.** A dated task whose date (the student's edit, if any) has
       passed. A finished one is finished work and stays in prev. Syllabus
       and announced exams follow the same rule. This is the one rule for
       "an announcement or Ed task vanishes at its due time and is never
       overdue" (the owner's rule of 2026-10-19, whose own implementation,
       `AppState.isExpired` widened to every `.canvasAnnouncement` item, was
       removed in the 2026-10-20 merge: `isExpired` is the `.event` rule
       for feed items alone again, and leaves an `.event` that is itself an
       unlinked announcement task to this rule, so no item is judged by
       both; one linked to a Gradescope twin keeps the event rule). Where
       it is asked: the
       dashboard's coursework and assessments buckets (`live` in
       `rebuildDashboardItems`), the megaphone's found list and badge (at the
       sheet, `announcementFoundItems(now:)`, not in the lists' input: see
       "Where the two announcement lists are judged" below), and
       ask's work pool (`announcementItemsStillOpen`, asked of the *feed*
       date, because the context document keeps it). The one place that
       cannot is the widget's ledger fallback (`LedgerWidgetReader`, another
       process, no post dates): it keeps the dated half, `dueAt < now`, for
       announcement rows, and the app's published snapshot, built with the
       whole rule, wins whenever there is one.
    2. **Undated tasks age out**: shown until 7 days after the post, then
       gone (`undatedAnnouncementTaskLifetime`). The post date is the
       announcement log's `postedAt` for a Canvas post, the Ed post's
       posting day (`edPostDate`) for an Ed post, and, when neither still holds the post, when
       the ledger first saw the row (`AssignmentStore.firstSeenDates`, a
       read, no new column). A syllabus exam has none and is never aged.
    3. **Same-day class reminders are not cards**: a title that opens with
       attend / come to / come in / bring / join us (after "please",
       "remember to", "don't forget to"), or says "in class/lecture today",
       and is due within 12 hours of the post or on its calendar day
       (`AnnouncementClassReminder`). "HW 3 due tonight" stays, and so does
       a found exam. This one needs the post's *own* date: the first-seen
       fallback is not the post's time.
    **Where the two announcement lists are judged.** `announcementPageItems`
    and `announcementFinds` are the megaphone's *input* and are deliberately
    not filtered by this rule in `isVisibleAnnouncement`: the sheet judges
    them at display time (`announcementFoundItems(now:)`, the badge), so the
    page keeps a past row the sheet will not show (`AnnouncementSheetTests`;
    the merge briefly filtered one level too early, which that test caught).
    Feed items (Canvas, Gradescope, manual) are never judged by any of it.
    The Ed pass reads only posts dated within the 14 days the Canvas pass
    uses, and skips a post with no date (`edDocumentsEligibleForTasks`); the
    date is the header's posting day (`edPostDate`), so a thread bumped by a
    reply yesterday is not "recent". The megaphone's found list and its
    badge ask the same rule, so what the dashboard keeps off itself is not
    listed there either, and neither is ask (since the 2026-10-20 merge,
    blind; before it ask still called them outstanding).
  - **How the posts are read, and what stops them being read forever**
    (merged 2026-10-20; the limits written 2026-10-19 without a compiler).
    Two passes, one ratchet. Canvas announcements go through
    `syncAnnouncements`, Ed announcements and pinned posts through
    `syncEdAnnouncementTasks`; both pick their extractor with
    `announcementExtractor(for:courseCode:)`, share the informational gate
    and the "ai assist" switch, and record what they read in
    `processedAnnouncementIDs`. The limits protect the quota `ask` shares (on
    2026-10-19 one failing extractor re-sent the same 13 posts every 15
    minutes and emptied it): a post that fails extraction three times is
    marked read with no find (`announcementExtractionAttemptsV1`, "gave up
    N"), a quota refusal ends the run touching no counter, and a run in
    which every backend extraction failed backs the extractor off for an
    hour (`announcementExtractionBackoffUntilV1`; in the Canvas loop the
    list is still refreshed). **Both passes obey all three, on the same two
    keys** (the Ed pass since the review of 2026-10-20, blind; Ed ids are
    `ed:…` and Canvas ids digits, so the counters cannot meet, and one
    back-off serves one quota). The Ed pass also keeps Marco's own six-hour
    wait (`edTaskRetryAfterV1`) for a failed post under the cap. Both keys
    clear with the processed ids, on disconnect and in the extraction repair.
    **Twins are dropped at write time by both passes**
    (`droppingAnnouncementTwins`; the post still counts as read): an Ed task
    that restates a task on the ledger or earlier in the run, and a Canvas
    task that restates an Ed find already on the ledger (the Canvas loop
    compares only against Ed finds, not against other Canvas posts). A
    syllabus exam row is never in the comparison pool, so an Ed or Canvas
    post that *moves* an exam is filed, not dropped as the syllabus's twin;
    the dashboard then shows the announced date (`announcementDedupOrder`
    offers the syllabus last). Staff posts that are neither
    announcements nor pinned are no longer read for tasks (the Canvas loop
    read them for one day).
  - **Exam cards** (2026-10-18, owner's call; not yet on a phone). "If
    you ever have a midterm, the class finds it from the syllabus or from
    an announcement. Either way, if a midterm is found, don't duplicate
    it." An exam card is a soft warm grey tint with normal ink type
    (since 2026-11-04, owner's call from mockups: the earlier black card
    with white type out-shouted overdue work) (`SmoothExamPalette`, drawn when the title is
    an exam by `ExamDetection.isExam`, or when the dashboard says so with
    `DashItem.examStyleOverride`). Three roads in, one card out:
    - **The syllabus.** `AppState+SyllabusExams.swift` runs
      `SyllabusExamRows` over each class's syllabus, course home page and
      course pages in the on-device course knowledge (not announcements,
      modules, assignment descriptions or Ed, which have their own
      readers), at launch and whenever the knowledge changes, off the main
      actor. `SyllabusExamExtractor` finds the lines that name an exam
      next to a date. Each exam is a `.canvasAnnouncement` row, kind
      `.event`, whose `sourceID` is `syllabus-{canvasCourseID}-{kind}[-n]
      [-makeup]` (`AnnouncementRecord.syllabusFindSourceID`,
      `ExamIdentity.sourceKey`): the id is the exam's identity and not its
      date, so a second pass writes the same rows, a moved date updates
      the row and keeps its tick, and an older build reads an announcement
      task. No new `Source`, no new column, for the reason given under Ed
      finds above. A date with no time is stored at 23:59:59 local like
      every all-day Canvas entry (`AllDayDueMoment`), so the exam is
      "today" all day and leaves the dashboard when the day is over (into prev
      only if it was finished), and the open
      card hides the clock time for it. Rows are never deleted when a
      syllabus stops naming an exam (Known gaps). Since 2026-10-18
      (`v8-server-exam-dates`) the server's reading comes first:
      `extract-profile` already stored each class's `examDates`, and
      `sync`'s manifest now sends them (`CourseProfileWire.examDates` ->
      `CourseGradingProfile.examDates` in `courseKnowledge.gradingProfiles`).
      A dated server exam wins over the on-device parse of the same
      `ExamIdentity`, and an exam only the server named is filed too, both
      under the same `syllabus-...` id, so a row already on the phone is
      updated in place and never filed twice. Undated entries are ignored,
      so are names that are not exactly one exam ("Quiz 3", "Midterms",
      "Midterm 1 and 2"), and a date more than 150 days past is dropped like
      the on-device one. The on-device parse is the fallback for a class the
      server has nothing for and for every exam the server left out. Two
      refinements (`SyllabusExamRows.reconciled`): on a day both agree on, the
      phone's time of day is kept, because the server only gives a day; and
      when they disagree on the day and the phone's syllabus line named a
      weekday that fits the date it chose (`ExamCandidate.weekdayConfirmed`),
      the phone's reading stands, because the server is given no current date
      and so guesses the year of a date written without one. A phone reading
      with no weekday to back it loses to the server, as does one whose
      weekday fits no year (a typo).
      **Nothing arrives until the backend half is deployed**; an older server
      simply has no `examDates` and the phone reads the text as before.
    - **An announcement.** An announcement task whose title *leads with*
      an exam ("Midterm 1", "Take the final exam"; not "Bring a calculator
      to the exam", `ExamDetection.leadingExamIdentity`) is a found exam
      too (`Assignment.isFoundExam`).
    - **Canvas or Gradescope** list it as an ordinary item and keep every
      rule they had.
    - **One card per exam.** `resolvingAnnouncementDuplicates` also joins
      by exam identity and date (`ExamDetection.isSameSitting`): the same
      kind, number and modifiers within 60 days is one sitting (a
      reschedule, not last year's recycled site), and an unnumbered exam
      against a numbered one, or Midterm N against Exam N, only when both
      are dated within a calendar day. A final is only another final, two
      different numbers never match, a makeup is its own exam. Precedence:
      a feed item, then an announcement, then the syllabus (the order
      `announcementDedupOrder` offers them in), so an announced new date
      replaces the syllabus's; an announcement with no day does not hide a
      syllabus row that has one, and neither does a Canvas or Gradescope
      exam with no due date (the dated twin is the card and the feed row is
      left out of the dashboard, `displaced`; nothing is written onto it).
      The hidden twin stays in the ledger and a tick on it carries to the
      card that is shown only if it was a tick on the same day: the
      tick on the syllabus's Oct 23 midterm does not complete the Oct 30
      one an announcement moved it to.
    - **Rules for a found exam.** It shows for every class that is not
      hidden whatever the class's "announcements on dashboard" and "items
      with nothing to submit" switches say. Past and unfinished, it leaves
      the dashboard like any announcement task (finished, it stays in prev);
      a feed exam keeps its normal overdue behaviour. It gets the ordinary lead-time reminders and never the
      loud 10-minute alert (`NotificationScheduler.loudAlerts` skips
      `isFoundExam`: the syllabus's rows are `.event` and already out, but
      the announcement extractors file every exam as a submission). A
      syllabus exam is in the megaphone's found list since 2026-10-18 (it
      was left out before, as found in no announcement), and its card
      says "from syllabus".
  - **Facts on cards** (2026-11-04, `v10`, behind `FeatureFlags.appliedFacts`;
    nothing has been watched on a device; the backend went live on
    2026-11-05 and six real facts exist, but none had reached a phone when
    this was written). A card the instructor
    cancelled leaves **todo**, stays in **all** tagged `cancelled`, and
    nothing is completed or deleted. A moved date shows the new date with
    the old one small and struck through, tagged `moved`; a changed scope
    or a note is tagged `changed` and listed on the opened card as the
    instructor's own sentence, linking the post where it is known. The
    opened card carries `undo`, which rejects the fact (it stays rejected
    when a newer fact arrives). A new task from a post is a "from
    announcements" card. Caveats: a cancelled item already overdue appears
    nowhere (todo hides it, all excludes overdue, prev is completed-only);
    a medium-confidence cancel is never applied.
    The **megaphone** sheet is a list of posts with the dashboard's controls
    (Marco, from the phone, 2026-11-06 and 11-07: "should just be one tab",
    "like on the dashboard where it's todo and prev", "all the
    announcements should look the same"): a todo · prev capsule switch
    (`SmoothSegmentPicker`, the view the dashboard's switch is built on),
    the dashboard's class filter menu to its right and the same chip under
    the row. Every row is the same post row (class, date, NEW, title, one
    preview line, an arrow with `go to canvas` or `go to ed` under it;
    Canvas rows open the Canvas Student app). The sheet lists every post
    the phone keeps (the log's 60 days / 300 posts, Ed staff posts
    included; the old 7-day window and the staff-post rule went on
    2026-11-07 when Marco found two posts on the sheet). **todo** holds a
    post while a find from it is open, while a live `new_task` /
    `reschedule` / `cancel` / `scope_change` fact from it has no past
    date, while its stored judgment is an event or task not yet over, or
    while it is under 3 days old (the grace for the unread); everything
    else is **prev** (`AppState.announcementSheetSplit`, pure). The badge
    counts unread posts in todo only. The found task cards and the
    fact rows are the dashboard's and no longer appear on the sheet; a
    new-task fact whose shortened title and date match an item the course
    already lists is redundant (the Dec 14 double final exam). A
    document-level verdict from the model, to replace the recency rule, is
    designed in ROADMAP → Next.
  - **Canvas's own signals** (2026-11-04, behind
    `FeatureFlags.structuredCanvasSources`): Planner ticks and dismissals,
    met module requirements and section due-date overrides now move cards;
    module-only work gets rows. See Architecture.
  - **Nothing to submit** (2026-11-06, owner's call from mockups and a
    phone pass): such a card reads `in class` in the small line under its
    due value, where "late" sits (`SmoothDueValue.secondaryLabel`), so it
    is never taller than its neighbours. Overdue, "late" wins; undated,
    "no date" does. The old "nothing to submit" caveat line under the
    title is gone. Diagonal stripes were tried on the phone the same day
    and rejected as too busy. VoiceOver hears "nothing to submit" as the
    card's value. **Since 2026-11-10 the word is truthful** (Marco: CIS
    3990's Project 2, handed in on a git server, read "in class"):
    `NothingToSubmitLabel.text` says "in class" only for Canvas `on_paper`
    (`onPaperCanvasAssignmentIDsV1`, beside `noSubmissionCanvasAssignmentIDsV1`,
    same per-item update), an `.event`, or a title naming a quiz or exam, and
    "off canvas" otherwise. Only the word: reminders, the Sweeper's silence
    and the auto-file at the due time are unchanged. Compiled and tested on
    the Mac; not on a phone. The missed PHYS 0151 Quiz 7 of 2026-11-09 was
    shown in todo and filed at its due time; nothing loud rings for an
    in-class quiz (`docs/QUIZ_MISSED_2026-11-09.md`).
  - **Where a card came from** ("from announcements", "from ed", "from
    syllabus", `DashItem.sourceText`) shows only in the opened card, under
    the full due date (2026-11-06). The collapsed card's caveat line now
    carries only the fact words: cancelled, moved, changed.
  - **Cards.** Tap a card to open it (full date, "edit date", and since
    2026-10-09 "open in canvas" / "open in gradescope", derived at display
    time by `Assignment.sourceLinks` from the URL the ledger already
    stores; a Canvas+Gradescope pair shows both, manual work and recurring
    tasks show none). An edited date is saved since 2026-10-10
    (`dueDateEditsV1` in `UserDefaults.lhf`, owned by `AppState`,
    `AppState+DueDateEdits.swift`) and is what the card, reminders, the
    widget and the on-device answerer all use; before that it lived only
    in the view model and was gone on relaunch. The context document sent
    to the server keeps the feed date on purpose, because
    `docs/PRIVACY.md` promises due-date edits never leave the phone. The
    ledger is the edit's proper home; defaults is the stopgap that avoids
    a schema migration. On the student's own work the opened card also
    shows "delete" (a one-off task) or "stop repeating" (an occurrence of
    a recurring task), each behind a system confirmation (2026-10-10;
    `OwnTaskRemoval`, `AppState.removeManualAssignment` /
    `removeRecurringTask`). Never on feed items or on preview and demo
    data. Swipe right
    to complete it, with a small paper-scatter animation. A floating
    button opens **ask**.
  - **Feedback card** (since 3.3.0, 2026-10-27, owner-approved from a
    mockup): under the header, a one-time card ("how's smooth so far?" /
    "takes 2 minutes.", grape speech bubble, ×) styled like the update
    banner (`FeedbackNoticeCard.swift`). Tap opens the form in Safari, ×
    dismisses; either marks the notice's id handled in `UserDefaults.lhf`
    (`lhf.feedbackNoticeHandled.<id>`), so it never returns, and a new id
    shows again. It exists only while the update manifest carries a
    `feedback` object (`FeedbackNotice`, sanitized: https to
    `docs.google.com` or `forms.gle` only), never in preview or demo,
    during onboarding or behind the update wall. Remove the object from
    `lhf-update.json` to stop it without a release. The link carries
    nothing about the student.
  - **Turned in** (how a card knows, read from the code on 2026-10-18).
    A card is done when the student swiped it; when Canvas's grades fetch
    reports its assignment submitted (`submittedCanvasAssignmentIDs`,
    joined on `Assignment.canvasAssignmentID`, which for a calendar row
    is the URL fragment, section-override rows included); when Gradescope's
    scrape says so (`gradescopeSubmitted`, which a paired Canvas card
    takes on); or when Canvas expects nothing online and the due time has
    passed. Both services' answers are kept in the ledger, so a relaunch
    shows what was last seen. The Canvas half needs a saved Canvas login,
    and with none nothing ever flips (Traps, "a card that stays not done").
    It runs on activation and on the 5-minute loop, at most every 15
    minutes, and since 2026-10-23 once at a cold launch too (blind; the
    launch pass under Background). Since
    2026-10-18 (`fix/submission-status`) a module-listed assignment whose
    Canvas id differs from a similar-titled calendar row is its own card
    instead of hiding behind it, and a Gradescope assignment's own name no
    longer counts as its status.
- **Grade Watcher** (`GradeWatcherView`). **Removed from the app by the
  owner on 2026-10-18** (`FeatureFlags.gradeWatcher = false`): no grades
  button, so no route to `GradeWatcherView` or `GradeReportView` in a
  Release build (the DEBUG `-LHFShowGrades`/`-LHFShowReport` launch
  arguments still work), and no "grade posted" notifications
  (`NotificationScheduler.gradeNoticesToPost`, at the posting point).
  Nothing is deleted, and the Canvas grade fetch
  (`AutoSyncCoordinator.refreshCanvasGrades`) deliberately keeps
  running: it is the only source of auto-submitted state, "turned in"
  notices, the 401 session-renewal probe, course intel and
  announcements, and the course-knowledge refresh. Gating that fetch on
  the flag is the wrong fix. What it was, per-course grades from
  Canvas's API with the student's session:
  - syllabus categories (`GradeCategoryMap`, editable in
    `GradeCategoryMapEditor`, with a server-suggested mapping)
  - a "decided" syllabus prediction (`GradeCountPredictor`)
  - per-item/category/course overrides with provenance
  - a "how this is calculated" panel
  - the grade report (`GradeReportView`)

  `docs/grades.md` is the design record.
- **ask / "the tree"** (`AssistantView`). A chat about your classes: the
  server path for Penn, with the on-device responder as fallback. Either
  way the search over course material runs on the phone (see "ask:
  retrieval is on the phone" under Architecture). Source chips under an
  answer are links when they can be tied to exactly one document
  (`CitationLinks`, 2026-10-10). Its own canned lines are a few words
  ("Couldn't find that.", "answering from your phone.").
  Since 2026-10-22 (blind) the composer has a **mic** at its trailing
  edge on iOS: tap to listen, the words stream into the field
  (`VoiceDictationRules.merged`: the draft as it was, a space, the
  transcript), tap again or tap send to stop; nothing is ever sent by the
  mic itself, because a misheard word must not send a question the
  student never asked. Recognition is Apple's `Speech` framework with
  `requiresOnDeviceRecognition = true`, and the mic is hidden outright on
  a device or language that cannot transcribe locally
  (`VoiceDictationRules.availability` → `.hidden`), which is what lets
  `docs/PRIVACY.md` say audio never leaves the phone. The audio session is
  set to `.record` only while listening and restored afterwards (the
  `AVAudioSession` trap). A 60-second cap stops a pocket tap. The two
  usage strings (`NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`) live in both `project.yml` and
  `App/Info.plist`, pinned by `VoiceDictationTests`. Not on the Mac (its
  sandbox would need the audio-input entitlement, and nothing there is
  verified). Seen working on Olisa's iPhone the same morning ("mic is
  working perfectly"). Owner's ask of 2026-10-22: "voice mode for the tree AI";
  dictate-then-send was the agreed first version, hands-free with spoken
  answers set aside (`ROADMAP.md` → Next).
- **Profile** (`SettingsPage`; `ProfileView` is only a wrapper), in order:
  1. your name
  2. accounts (Canvas and Gradescope connect/disconnect; "update password"
     only when Penn rejected a saved PennKey password; "sign in to
     canvas" under the canvas row when Canvas is connected with no saved
     login, since 2026-10-18; since 2026-10-27 every reconnect row opens
     the sign-in as a cover over the dashboard, never the first-run
     walk; a "save pennkey" row while Penn is connected with no saved
     password; "couldn't reach smooth · will retry" while a disconnect's
     server deletion is still pending). The sign-in health lines and the "ed
     discussion" status row that `v8` added here were taken off the page
     on 2026-10-10 ("a whole yap about Canvas", Marco), moved into one
     collapsed "sign-in diagnostics" disclosure, and on 2026-10-18 put
     back in plain view at their `ba75e97` places (health lines under
     the canvas row, the ed row under gradescope) at the co-owner's
     request, still `#if DEBUG`. The disclosure is gone. The three sync
     summary rows (announcements, ed tasks, course material) sit under the
     ed row, also `#if DEBUG`, and so does a "testing (debug build only)"
     section at the foot of the page (simulate a Canvas logout, probe Ed).
     **Since 2026-10-20 every one of those rows is also behind
     `FeatureFlags.profileDiagnostics`, which is off** (the owner, looking
     at a DEBUG build: "I just don't want the debug diagnostics to be
     visible to the user in this version"); nothing was deleted, so
     flipping the flag brings them back in a DEBUG build, and the same
     facts stay readable off the phone from the App Group plist
     (Commands). A Release build never showed any of it. The
     strings and `SignInHealthTests` remain.
  3. appearance (light / dark; there is no "system" option and the
     default is light, whatever this file said before 2026-10-10)
  4. reminders (on/off; 10 minutes, 1 hour, 3 hours, 1 day, 2 days;
     "turned in" confirmations). "10 minutes before" (`LeadOffset.m10`,
     2026-10-09) is opt-in: off by default and absent from the onboarding
     pills (`LeadOffset.onboardingOffered`). A reminder's title is the
     class and its body is the assignment's name then the lead phrase
     ("Problem Set 4. Due in 1 hour", `NotificationScheduler.reminderBody`,
     2026-10-09; before that the body was the lead phrase alone). Since
     2026-10-18 a loud 10-minute alert switch sits beside them, on
     by default (`notif.loudAlertEnabled`), labelled **"Smooth Sweeper"**
     since 2026-10-20 (the owner's student-facing name for the whole
     mode; it was "loud 10-minute alert"; "Berserk" stays in code, tests
     and this file): for work that takes a
     submission and has not been handed in, three Time Sensitive
     notifications three seconds apart at 10 minutes before the due time
     (`NotificationScheduler.loudAlerts`). Not for anything with nothing
     to submit, a recurring occurrence, a completed item or an exam the
     app found (exam cards, below); at most 10 items, nearest first,
     planned before the ordinary reminders so they come out of the same 60
     pending slots, and it replaces the plain "10 minutes before" for an
     item that has the alert. It needs the Time Sensitive entitlement in
     `App/LHFApp.entitlements` (iOS only); without it iOS delivers them as
     ordinary notifications and says nothing. Never heard on a phone yet.
     The owner calls it **"Berserk mode"** (2026-10-19: right before an
     assignment goes unsubmitted it "goes berserk and forces you to notice
     and either fix it or do something about it"); to students it is
     **"the Smooth Sweeper"** since 2026-10-20 (the Profile switch, the
     reminders page of onboarding, the takeover's heading, the island
     card's label and the alarm permission text all say so), and since 2026-10-19
     (`v8-loud-alert-actions`, not on a phone) each buzz carries two
     buttons: **"turned in"**, which silences that item's remaining
     buzzes at the tap and then marks it done exactly as a swipe does once
     the dashboard has loaded, and **"open in canvas"**, the card's own
     link ("open in gradescope" for a Gradescope-only item; manual work and
     Ed finds get "turned in" only). Both open the app (`.foreground`), on
     purpose: handling "turned in" without opening it would run app code
     off screen, the path that has crashed on every background wake. The
     one notification delegate (`NotificationResponseDelegate`) is
     installed in `LHFApp.init`, because iOS hands a button tap that
     cold-launches the app only to a delegate assigned before launch
     finishes; the old one was assigned at the first reschedule, too late.
     Taps wait in a queue (`NotificationActionInbox`) until the dashboard
     is bound, so none is lost or applied to an empty list; a waiting
     "open" expires after 2 minutes (a Mac with its window closed would
     otherwise open Canvas days later), a waiting "turned in" never does,
     because it is the student's own claim. Rules in
     `LoudAlertActions.swift`.
     **On iOS 26 it is a real alarm** (2026-10-19, owner's call: "the
     three buzzes doesn't quite do enough"; rang on Marco's iPhone the
     same day). When the
     student allows AlarmKit (one system prompt, from the first foreground
     reschedule that has something to ring; usage string in
     `NSAlarmKitUsageDescription`, kept in both `project.yml` and
     `App/Info.plist`), the three buzzes become one AlarmKit alarm at the
     same moment for the same items (`plannedAlarms` reuses `loudAlerts`).
     It goes full screen and rings through silent mode and Focus like the
     Clock app. Below iOS 26, on the Mac, with permission refused, or
     whenever AlarmKit throws, the buzzes stay. The secondary button is
     **"turned in"**, the only one that marks anything done. Stop opens
     the item's Canvas or Gradescope page, or only stops when there is
     none (Traps, "an alarm's stop is any dismissal"). Since iOS 26.1 the
     system draws its own "Stop" label. The intents are `LiveActivityIntent`s in
     `App/LHFApp.swift`, handed to the package through
     `BerserkAlarmIntents.factory`, because the system needs App Intents
     metadata it extracts from the app target. Alarm ids are a hash of
     (assignment id, ring time), so a reschedule is idempotent and a moved
     due date replaces the alarm. A reconcile never stops a ringing alarm
     except for an item the student has just finished. Preview and demo
     data never ring. Its sound is `App/berserk-alarm.caf` (2026-10-19, the
     owner's pick: the first 13 seconds of Ed Motta's "Seis da Tarde",
     faded out over the last 4, at 80% volume ("like 20% quieter"), 16-bit
     CAF), played from the main bundle
     because that is the only place developers report AlarmKit's
     `.named` finding a sound; without the file it is the default tone.
     **It is commercial music. On 2026-10-20, asked before the 3.1.0
     archive whether it should come out, Olisa said it ships: "Keep it, I
     have a licence."** As with Roobert (Visual language, above), there is
     deliberately no licence file in the repo; the licence is Olisa's to
     produce if it is ever asked for. Until that answer, the rule here was
     that the file and its four `project.pbxproj` lines had to come out
     before any archive. It is in the public repo since 2026-10-19: the
     owner chose to push it, saying he accepts the copyright risk, after
     being told the repo is public and that git history keeps it. Files: `BerserkAlarmPlan.swift` (pure rules),
     `BerserkAlarmDelivery.swift`, `BerserkAlarmScheduler.swift`
     (AlarmKit, iOS 26 only).
     **Rang on Olisa's iPhone on 2026-10-20** (the merged build): full
     screen on the lock screen, the song once, "turned in" marked the
     card done after unlock. Olisa's verdict on the look: when the phone
     is unlocked it is "a little alarm notification drop in", and he
     wanted the whole screen to be Smooth. iOS allows no app to draw its
     own screen while closed, so the answer is two pieces (2026-10-20,
     blind): **(1) the alarm's Live Activity is drawn by the widget
     extension** (`LHFWidget/BerserkAlarmActivity.swift`, iOS 26 only,
     added to the bundle under `#available`): the Dynamic Island when the
     phone is unlocked and the lock-screen card, in tomato with the class,
     the assignment and a live countdown to the due time; no buttons and
     no `widgetURL` (the system alert keeps "Stop" and "turned in", and a
     tap opens the app). It needs `NSSupportsLiveActivities` in
     `project.yml` and `App/Info.plist` (app target only), and the
     metadata type both targets decode, `BerserkAlarmMetadata`
     (assignment id, class, title, due moment, page URL), now lives in the
     Kit (`Sources/LowHangingFruitKit/Alarms/`), because the widget links
     the Kit and not `LowHangingFruitUI`. The alarm id namespace is
     `v2`: an alarm the previous build scheduled carries the old metadata
     and would ring without the Live Activity, so the first reconcile
     after the update cancels every old alarm and schedules it again once.
     **(2) the Berserk takeover screen inside the app** (2026-10-20,
     blind; `BerserkTakeover.swift` pure rules and the model,
     `BerserkTakeoverView.swift`, `BerserkTakeoverHost.swift` applied in
     `RootCore`, `BerserkAlarmScheduler+Alerting.swift` the AlarmKit
     questions): the moment Smooth is on screen while an alarm is ringing,
     or a loud buzz is tapped on its body or lands while Smooth is open,
     Smooth covers its whole window: full-bleed tomato that breathes
     (still under Reduce Motion), "Smooth", a live countdown to the due
     time ("due now" once it passes), the assignment, the class, and three
     choices: **"turned in"** (stops the alarm, pulls the item's delivered
     buzzes, and deposits `.turnedIn` in the same inbox a notification
     button uses, so `ContentView` ticks the card exactly as a swipe
     does), **"open in canvas"** / **"open in gradescope"** when the item
     has a page (stops the alarm, opens it), and **"not yet"** (stops the
     alarm, completes nothing). "turned in" is the only choice that
     deposits a "turned in"; no dismissal marks work done (the alarm's
     rule, carried onto the screen). Three roads in: the host listens to
     AlarmKit's alarm updates while the scene is active and reads the
     ringing ids on each activation (`alertingAlarmIDs`,
     `alertingUpdates`, `stopAlarm` on `BerserkAlarmBackend`, defaulted
     for the Mac and the test fakes), and the notification delegate files
     a buzz (`LoudAlertActions.berserkSignalAssignmentID`) when a loud
     buzz lands in the foreground (`willPresent`) or is tapped on its body
     (`UNNotificationDefaultActionIdentifier`, which `action(...)` still
     maps to nil; a tap on a button files nothing, the student chose). A
     ringing alarm is traced back to its item by recomputing
     `BerserkAlarmPlan.alarmID` for every dashboard item
     (`alarmIndex`); `Alarm` exposes no metadata. A signal it cannot yet
     trace waits (a cold launch raises it before the dashboard has
     loaded) and is resolved again when `NotificationScheduler.
     rescheduleGeneration` changes, which is how the host learns the
     dashboard handed over its items without touching `ContentView`. An
     alarm signal whose alarm stopped ringing is dropped, a buzz is kept
     two minutes (`buzzLifetime`, the `openLifetime` reasoning), a
     finished item's signal is dropped, preview and demo data never take
     over, one assignment is one takeover (alarm over buzz), soonest due
     first and the rest wait their turn. The screen leaves on its own when
     its alarm stops ringing (from the lock screen too) or its item is
     finished; a buzz takeover otherwise waits for a choice. The model
     remembers answered alarm ids and, for two minutes, answered
     assignment ids, so buzzes two and three of a "not yet" do not bring
     it back. The system's own alert still appears on top (the drop-in
     when unlocked); the takeover is what the student sees underneath and
     after. **Both pieces seen on Olisa's iPhone the same day** (build of
     `8d00e62`, 11:25): it rang, the Dynamic Island showed the tomato
     card, and the takeover worked. Which road in he used, and the
     lock-screen card, are not recorded.
     **Smooth Sweeper settings** (2026-10-23, Marco, `codex/sweeper-settings`;
     in 3.2.1 (15), 2026-10-24; build 15 was first stamped 3.2.0): the Sweeper has its own
     section immediately below reminders (`SweeperSettingsSection`; since
     2026-11-10 on `v11` that section is gone and the Sweeper is its own
     page, `SweeperView`, opened from the header broom: on/off, a live
     countdown card for the next alarm actually set, the defaults, and a
     page per class with its own lead time and sound,
     `notif.sweeperCourseMinutesV1` / `notif.sweeperCourseSoundV1`,
     resolved by `SweeperPlan.swift`; sketch in
     `smooth-prototype/sweeper.html`), with
     5/10/15/20/30/60-minute timing (`notif.sweeperMinutes`), four sounds
     (`SweeperSound`: Smooth's clip, `App/sweeper-chime.wav`,
     `App/sweeper-pulse.wav`, both original synthesized audio, and the
     system alarm) with previews of the bundled ones, and an expandable
     per-class selection (`notif.sweeperExcludedCourses`, separate from the
     ordinary reminders' class settings). Defaults are unchanged: 10
     minutes, Smooth, every class. A change re-plans alarms and the
     fallback buzzes; the sound is part of the alarm's identity, so
     changing it replaces idle alarms, and work finished under an earlier
     timing or sound is still recognised. Marco's validation: an iOS Debug
     build, 109 targeted tests in five suites, installed on his iPhone 17
     Pro on 2026-10-23; the full suite and real alarm playback with the new
     sounds are not yet seen. The permission text now reads "rings an alarm
     before work you haven't turned in, at the time you choose". A review of
     the merge (2026-10-24) found the takeover screen could not find a
     ringing alarm under any non-default timing or sound, because
     `BerserkTakeoverRules.alarmIndex` still rebuilt the id with the fixed
     ten minutes and no sound; it now enumerates every option, as the
     stop-on-finish path does (compiled green in the 2890/260 run of
     2026-10-24, with a test; not yet seen on a phone). Left as Marco wrote
     them, for the owners: the fallback buzzes now play the chosen sound,
     so with the default each of the three buzzes starts the 13-second song
     three seconds apart (build 14 used the system tone; Marco's test pins
     the new behaviour); the previews play through `AVAudioPlayer` without
     touching the audio session, so the silent switch mutes them and they
     stop other audio (the `AVAudioSession` trap); a 60-minute lead
     suppresses the plain 1-hour reminder for loud items, as 10 minutes did
     for the 10-minute one; and two capitalised explanatory lines remain in
     the section. The section's footer (Marco's "A list minute alarm right
     before your miss an assignment.", corrected on 2026-10-24) was removed
     the same evening at Olisa's word, seeing it on his phone ("Remove the
     text under smooth sweeper"); the section ends at the classes row.
  5. classes (rename, hide, delete/restore; "add recurring task")
  6. notifications (per-class reminders, lead times, announcements on
     dashboard, items with nothing to submit, the announcement "ai assist"
     opt-out)
  7. sync (iCloud sync, off by default; on macOS, open at login)
  8. feedback (since 3.3.0, 2026-10-27): one "send feedback ↗" row that
     opens the Google feedback form in Safari (`FeedbackForm.defaultURL`,
     or the live notice's link when the manifest carries one)

  `ProfileSemesterSection` (semester rollover, "add a class") exists but
  is only reachable from its `#Preview`; `VisualStructureTests` forbids
  "semester" in the page body, so none of its text ships.

  **Copy rule (2026-10-10, Marco): the least text that works.** No
  explanatory sentences, no captions restating a control, no raw system
  errors, no developer diagnostics on a normal screen. Sync failures
  read "couldn't sync"; the Canvas banner reads "reconnect canvas",
  "duo needs you", or "pennkey password rejected". What must stay is
  listed in the memory note `keep-copy-minimal` and comes from
  `docs/PRIVACY.md` and `docs/appstore/REVIEW_NOTES.md`.
- **Background.** A 5-minute refresh loop while open, `BGAppRefreshTask` in
  the background (`BackgroundRefresh.swift`), silent Canvas session renewal
  (`CanvasSessionRenewer`, plus the saved PennKey password where
  available) and "turned in" notifications. Grade-change notifications
  are held back while Grade Watcher is off (2026-10-18). **Since
  2026-10-23 (`launch-refresh-rework`, blind) a cold launch runs the
  Canvas chain once** before the loop's first sleep: the feed sync from
  the root view as before, then `fetchSessionSources` (connected services,
  Grade Watcher → course intel → course material and Ed) and
  `settleAfterFetch` (session check, silent-renewal retry, Duo line,
  reload, badge, reschedule). The two notification drains
  (`announceGradeChanges`, `announceTurnedIn`) and the laptop sync are
  **not** in the launch pass: the drains can post, and the root view
  already ran the laptop pass; a "turned in" raised by the launch fetch
  therefore waits for the loop's first pass, up to five minutes. Before
  this, nothing at launch ran the chain and a phone that locked inside
  the first five minutes synced only on its next return to the
  foreground (seen 2026-10-23: twenty silent minutes after an install).
  Marco's `parked/launch-submission-refresh` was the source; merged as
  written it would have run the drains at launch too.
- **Widget** (`LHFWidget/`, a separate process). Next-due list in small and
  medium; lock-screen inline, rectangular, and circular ("N due" within 24
  hours). It shows the app's published snapshot whenever one decodes,
  empty included ("all clear"), and reads the ledger only when the app
  has never published (`WidgetSnapshotStore.current`, 2026-10-10). Its
  timeline has an entry at each of the next due times so it re-renders
  when work goes overdue (`WidgetTimelinePlanner`); overdue work stays
  listed.
- **Mac.** The same app, plus a menu-bar extra that keeps the sync loop
  alive (`LHFScenes.swift`) and open-at-login.
- **Connect an agent** (2026-11-08, `agent/connection-v11`, compiled, never
  on a phone; behind `FeatureFlags.agentConnection`, Penn installs past
  onboarding with a backend only). Profile → accounts gains a "connect an
  agent" row (on / off) opening `AgentConnectionsView`: the opt-in switch,
  the disclosure (the exact fields shared, the recipients by name, that
  turning it off deletes the list and disconnects every agent, the privacy
  policy link), the connected agents with "last used" and "disconnect",
  and a "have a code?" field for the typed 8-letter code. A
  `smooth://link?c=…` URL (the "Open Smooth" button on the agent's sign-in
  page) or a typed code looks the pending request up and shows
  `AgentLinkApproveSheet`: "connect Claude?", what it reads, "did you just
  start this?", three numbers to pick from (a wrong one denies the request
  on the server), "not now". Approving turns the opt-in on if it was off.
  With it on, `agentSnapshotPass` uploads the work list
  (`AgentSnapshotBuilder` over `syncWorkList()`, courses, own tasks; no
  grades, no name) right after `deviceSyncPass` in `ContentView.refresh()`
  and the launch task, foreground only, at most every 10 minutes, every
  failure silent. Turning it off, disconnecting Canvas and account deletion
  delete the server's list and revoke every agent. `docs/PRIVACY.md` →
  "Connecting an AI assistant" is the student-facing text. Copy in
  `AgentConnectionCopy`, pinned by `AgentConnectionCopyTests`.
- **Drafts from an agent, and submitting them** (2026-11-10, v11 Phases 3
  and 4, phone half; on `claude/v11-phone-c7aaf2`, compiled and tested,
  **never on a phone and never against Canvas**). `agentDraftsPass`
  (`AppState+AgentDrafts.swift`) runs right after `agentSnapshotPass` in
  `ContentView.refresh()` and the launch task, with the same gates (Penn,
  backend, opt-in on, foreground only), at most every 5 minutes, failures
  silent (both passes' gates and throttles: `AgentPassRules.shouldStart`).
  It also refreshes the connection list (for the line below),
  re-sends any outcome report the server never acknowledged, and replaces
  `AppState.agentDrafts` (memory) and `agentDraftsCacheV1` (the same drafts
  with no body, link, note or signed URL, so a relaunch draws the chips
  before the first poll). A draft matches a card by equality: its
  `assignment_id` is the snapshot item id, which is `Assignment.id`. The
  list decodes one draft at a time (`AgentDraftList`, 2026-11-11): a draft
  with no id or a non-object is skipped, never the whole list. The card's
  preview reads only the body's head, and the cache clips the agent's name
  to the 40 characters the card prints.
  - **The card.** "drafted by claude" in the collapsed card's caveat line
    beside cancelled / moved / changed, the chip in grape (`smoothGrapeInk`,
    the agent's and ask's colour; the exam card's secondary colour on its
    inverted ground) (`DashItem.caveatText`, `factCaveatText`,
    `agentChipText`, `DashItem.agentDraft`); the opened card shows two lines
    of the body, the link, or the file's name and size, and one button drawn
    like "edit date" (a glyph, then the words): "review and submit" ("check
    canvas" once a submission went out with no answer). A draft on an item
    that cannot be submitted online still shows, chip and all; the sheet
    says why. The first open marks the draft `seen`. Only the newest open
    draft per item shows. Once the phone sends it and Canvas takes it, the
    card goes to prev at once (`completeAfterAgentSubmit`: the shown card is
    found through its own id, a `linkedID` or a hidden twin by
    `shownAssignment(forItemID:)`, then `markCompleted`, as a swipe would) and reads
    "submitted by you · drafted by claude" there
    (`AppState.agentSubmittedNamesByItemID`, from the attempt records, which
    now keep the agent's name; `DashItem.agentSubmittedBy`).
  - **The notice.** One local notification per new draft, "Claude drafted
    Problem Set 7" (`AgentDraftNotices`, remembered in
    `agentDraftsNotifiedV1`, bounded at 200), only for a draft whose card
    is on the dashboard, posted with the turned-in notices' rules.
  - **The review sheet** (`AgentDraftReviewSheet`, redesigned 2026-11-11).
    Why: on Marco's phone a plain-text draft on PHYS 0151 "Problem Set 7"
    (Canvas `submission_types` = `online_upload` only) opened, Submit ran the
    preflight, the preflight refused the text with `.unsupportedType`, and
    the sheet printed "submit this one in canvas", which read as "review and
    submit didn't work". Now the sheet **knows what Canvas takes before the
    student decides**: when it opens, once per draft (memory,
    `AppState.agentDraftAcceptanceByDraftID`), `agentDraftAcceptance` answers
    "not online" without asking anyone for an item the phone can never send
    (no Canvas ids, a quiz, Gradescope, nothing to submit), else uses what
    the last structured-sources run read off the assignments list
    (`CanvasOverrideAssignment.submissionRules`: `submission_types`,
    `allowed_extensions`, `locked_for_user`, kept in memory in
    `canvasSubmissionRulesByAssignmentID`) **only when it lets the student
    send**: a list answer that would block (locked, nothing online) can be
    hours old, so it is confirmed with one live GET and only the live answer
    blocks (cached once confirmed; a GET that cannot be had blocks nothing
    and the submit's preflight decides), else runs the submit's own
    preflight GET early (`CanvasSubmissionClient.fetchRules`; the same request
    the submit makes first, so no new network call and `docs/PRIVACY.md` is
    unchanged). `CanvasAcceptance.derive` turns the four fields into text /
    link / file (with extensions) / nothing online / locked;
    `DraftSubmitPlan.make` turns (draft kind × that) into the routes on
    offer, the default, or a block. Top to bottom: the class code in its
    accent ink, the title (Familjen 24), "drafted by claude" in grape, the
    agent's note behind a grape rule; the draft full width (the text in
    Inter 16, selectable; or the rendered pdf pages inline in a PDFKit view
    with "<title>.pdf · n pages"; a link as a ruled 56pt row that opens it;
    a file as a row with name, size and "preview", QuickLook); one line,
    "canvas takes a pdf or docx here" / "canvas takes text here" / "this one
    can't be submitted online" / "canvas has this one locked" (and, under
    it, a refusal for this draft: "canvas doesn't take .zip here · ask for a
    pdf file", "canvas doesn't take a link here"); the `SmoothSegmentPicker`
    "send as text" / "send as pdf" only when both go; then, pinned at the
    bottom on paper, "this goes in under your name; read it", a filled grape
    48pt squircle "submit to canvas" (confirmation names the kind: "send
    problem set 7 as a pdf?") and a plain "decline". Blocked, "open in
    canvas" (a text link to the Canvas app) takes the submit's place.
    Choice rules: a text draft on a file-only assignment goes as a pdf
    (**any** text draft, plain or markdown: `DraftDocumentRenderer`
    renders plain text too, paragraphs on blank lines, single breaks kept,
    nothing read as markup); on a text-taking assignment "send as text" is
    the default and the pdf optional, except that a markdown draft where
    Canvas takes both text and files defaults to "send as pdf"; if the early read failed the draft's
    own kind is offered (text beside pdf, markdown leaning pdf) and the
    submit's preflight decides. Results in plain words with the next step:
    "no connection · try again", "sign in to canvas in profile, then try
    again", "canvas has this one locked" + open in canvas, "it may have gone
    in · check canvas" + open in canvas, "couldn't reach canvas · try
    again"; submitted is a full-sheet state (teal tick, "submitted to
    canvas", "in at 9:41 pm" when verified, else "check canvas to be sure",
    done). Every string in `AgentConnectionCopy`, pinned by
    `AgentConnectionCopyTests`; the table and choices by
    `DraftSubmitPlanTests`.
  - **Submitting** (`CanvasSubmissionClient`, promoted from the spike, and
    `AgentDraftSubmitter`): a preflight GET of the assignment decides
    everything that can refuse (submission types, `allowed_extensions`,
    locked, `can_submit`, session, CSRF token) before any POST; then the
    attempt record is written (`AgentSubmitAttemptStore`, its own JSON file
    under Application Support, written `.atomic` before `begin` returns);
    then, for a file, Canvas's slot POST, the multipart upload to the slot's
    URL with no cookie or CSRF header, and a confirm GET on a redirect; then
    the submission POST, **exactly once, never retried, not even after a
    422**; then a verify GET of `/submissions/self`. A 2xx with an id is
    `submitted` (verified or not); a refusal by Canvas or a request that
    never left the phone is `failed`; a 5xx, a timeout or a lost connection
    after the POST is indeterminate: the record stays, the card says "check
    canvas", nothing retries. A draft with a record is never submitted
    again, whatever the server says, and cannot be declined either.
    Outcomes are reported with `draft` (`submitted` with
    `canvas_submission_id` and `attempt`, or `failed` with a short
    `error_class`). Disconnecting Canvas and turning the opt-in off clear
    the drafts, the cache, the notice memory, the known-connection ids and
    the attempt records. Since 2026-11-11 disconnecting Canvas also clears
    the assignment-PDF pass's memory (`attachmentAttemptsV1`,
    `lastAttachmentSyncSummaryV1`) and the in-memory Canvas submission
    rules the review sheet reads first.
  - **Text as a PDF** (2026-11-10 for markdown; 2026-11-11 for every text
    draft; compiled and tested, never on a phone). claude.ai will not emit a
    144,000-character base64 PDF, so a document travels as source text and
    is rendered on the phone. `DraftDocumentRenderer` (Kit, `Agent/`):
    `pdfData(forDraftBody:format:)` picks markdown (a heading, list, code
    fence, emphasis, an explicit first line `<!-- format: markdown -->`, or
    a `format` field) or plain text (`plainParagraphs`,
    `attributedString(fromPlainText:)`). Markdown: `AttributedString(markdown:)`
    to blocks, Inter 11.5 pt body, larger Inter-Bold headings, Space Mono
    code. Both: US Letter with 1-inch margins through
    `UIGraphicsPDFRenderer` + `CTFramesetter` behind `#if canImport(UIKit)`
    (macOS answers nil, and the plan then offers no pdf). `$...$` math stays
    text. Submit sends it as `<title>.pdf` (`application/pdf`) through the
    ordinary file path, same attempt record, same never-twice rule. A render
    failure drops the pdf route with "couldn't make a pdf".
  - **Connected.** After the right number is picked the approve sheet
    becomes a confirmation ("connected to claude", "go back to claude to
    finish", done) instead of closing itself a second later; and a
    connection that appears in the list while the app is open (the
    connection row is created when Claude trades the code, after the
    approval) raises a one-line "connected to claude" under the status
    lines, dismissed with a tap (`AppState.agentConnectionBanner`,
    `noteAgentConnections`; the first list on an install only records).
    Marco, 2026-11-09: "there should be some UI that makes it clear when
    you're connected since it is not that clear."
- **Pair a laptop** (2026-10-22, never compiled). Scanning the Chrome
  extension's QR code with the iPhone camera opens Smooth
  (`smooth://pair?c=…#k=…`, `.onOpenURL` in `RootCore`) on "pair this
  laptop?" (`PairLaptopSheet`), Penn installs past onboarding only. On
  "pair" the phone claims the code under its own token and keeps the key
  in the Keychain (`SyncKeyStore`). From then on `ContentView.refresh()`
  runs `deviceSyncPass()` (foreground only, at most every 2 minutes):
  fetch the laptop's sealed snapshot, merge, apply what the laptop changed
  through the same paths a swipe, an edited date and the add sheet use
  (inside `RemoteApplyGate`, so the tap hooks do not re-date them), then
  seal and put the phone's own. Profile → accounts shows a "laptop" row
  with "unpair" when paired. Pairing a second laptop unlinks the first.
  Unpairing keeps the change log; disconnecting Canvas clears it and the
  key.
- **Chrome extension** (`chrome-extension/`, started 2026-10-22; running
  in Olisa's Chrome since 2026-10-23, and by 2026-10-24 20:00 UTC it had
  uploaded 692 documents across 10 courses, 53 of them PDF `file`
  documents from one course, read from the live table). A helper for the
  phone, Penn only, loaded
  unpacked: it collects course material the phone cannot reach with the
  browser's own sessions, and syncs the student's completions, edits and
  manual tasks with the phone, end-to-end encrypted after a QR pairing.
  What is built and what is only designed: `docs/CHROME_EXTENSION.md` →
  Status.

## Commands

```bash
# Tests — the primary gate. Runs on the macOS host.
cd LowHangingFruitKit && swift test
# If a parallel run hangs (see Test baseline), this is the reliable form:
cd LowHangingFruitKit && swift test --no-parallel

# iOS build (simulator)
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# iOS build to a connected phone, then install and launch
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug \
  -destination 'id=<device UDID from -showdestinations>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <CoreDevice id from `xcrun devicectl list devices`> <path>/Smooth.app
xcrun devicectl device process launch --device <CoreDevice id> com.lhf.lowhangingfruit

# macOS build (the package; `swift test` also exercises this)
cd LowHangingFruitKit && swift build

# Backend — Deno/Supabase Edge Functions, a separate toolchain from the above
cd backend && deno task test
cd backend && deno task check
```

Since 2026-11-02 every push to `v8` also runs the three suites on GitHub's
runners (`.github/workflows/tests.yml`: `swift test --no-parallel` on a
macOS image with Xcode 26 selected, the Deno suite with `--no-check`, the
extension's `npm test`). It is the compile gate when no Mac is at hand; it
builds no app and signs nothing, so the iOS `xcodebuild`, the archive and
the phone still need a Mac. Read a run with `gh api
repos/OlisaNW247/penn-dashboard/actions/workflows/tests.yml/runs`.

`xcrun devicectl` launch fails with `FBSOpenApplicationServiceErrorDomain
error 1` when the phone is locked; the install still succeeded. The built
product is `Smooth.app` (see the macOS naming trap below).

`-LHFDemoData` (DEBUG only) seeds the bundled sample courses so the app is
usable without a real Canvas session, and pairs with `-LHFShowSettings`,
`-LHFShowGrades`, `-LHFShowReport`, `-LHFShowAssistant`, `-LHFTabAll` or
`-LHFTabDone` to land directly on a screen:

```bash
xcrun simctl launch booted com.lhf.lowhangingfruit -LHFDemoData -LHFShowAssistant
```

`-LHFAgeCanvasSession` (DEBUG only) backdates the saved Canvas cookies'
`capturedAt` by 25 hours before launch, so the real renew-on-open path runs
now instead of tomorrow. Every silent-renewal step in a DEBUG build is
printed as an `LHF-RENEW` line and kept in `UserDefaults.lhf`
`debugRenewalLogV1` (last 50: time, app state, status; never a cookie, URL
or credential). Watch it live on a tethered phone (the `--` matters, or
devicectl eats the flag):

```bash
xcrun devicectl device process launch --console --terminate-existing --device <CoreDevice id> com.lhf.lowhangingfruit -- -LHFAgeCanvasSession
```

After the fact, read it (and the session flags) straight off the phone,
read-only, from the App Group plist:

```bash
xcrun devicectl device copy from --device <CoreDevice id> --domain-type appGroupDataContainer --domain-identifier group.com.lhf.lowhangingfruit --source Library/Preferences/group.com.lhf.lowhangingfruit.plist --destination /tmp/lhf.plist
```

That copy only works while the installed app is a developer build. Against
the App Store copy it fails with `ContainerLookupErrorDomain error 7`,
and a Release build keeps no renewal log anyway. Installing a DEBUG build
over the store copy keeps everything (same team, `24A3TDB277`, so the data
container, App Group and Keychain all carry over) and makes the container
readable; copy the plist and cookie jar before the first launch to see the
state the store build left. Going back to the store copy means deleting
the app, so the phone stays on the debug build until the next App Store
update installs over it.

`-LHFSessionDiagnostics` (DEBUG only) snapshots what the silent re-login
has to work with at launch: whether a PennKey password is on file, and
every saved Canvas cookie's domain, name, expiry and capture time (never a
value). It prints `LHF-DIAG` lines and keeps them in `UserDefaults.lhf`
`debugSessionDiagnosticsV1`. Run it before `-LHFAgeCanvasSession`, or
together with it (the snapshot is taken first).

Since 2026-10-19 (blind) the App Group plist also holds one-line summaries of the
last announcement sync (`lastAnnouncementSyncSummaryV1`: where it exited,
Canvas count, eligible, finds, errors, processed, the first error's kind,
"gave up N"), the last Ed task pass (`lastEdTaskSyncSummaryV1`, 2026-10-20,
blind: eligible, finds, errors, processed, first error; a run with nothing
to read is written in front of the last real line, "| last run:") and the
last course-material sync (`lastCourseKnowledgeSyncSummaryV1`: outcome,
courses, documents, manifest, upload, the Ed status line); a DEBUG build
with `FeatureFlags.profileDiagnostics` flipped to true shows the three as
"announcements", "ed tasks" and "course material" rows in Profile →
accounts, under the ed discussion row (they were in a "sign-in
diagnostics" disclosure before the merge, which no longer exists, and in
plain view until the owner hid them on 2026-10-20); with the flag off,
as it is, this plist copy is the only way to read them.
Counts and words only, never a title, id, body or URL. They exist because
on 2026-10-19 the Announcement Watcher produced no Ed finds on Olisa's
phone and nothing on the device said where the sync had stopped.

Crash reports come off the phone the same way (`--domain-type
systemCrashLogs`, files named `Smooth-<date>.ips`; list them with
`xcrun devicectl device info files --device <id> --domain-type systemCrashLogs`).
An `.ips` is one JSON header line plus a JSON body: read the thread with
`"triggered": true`. Reading someone else's phone needs it paired in
Xcode → Devices and Simulators first; Finder's "Trust" alone is not
enough for `devicectl`.

Release upload (2026-09-27, the path that worked; do **not** run
`xcodegen generate` first, whatever `docs/appstore/CHECKLIST.md` used to
say, and bump `CURRENT_PROJECT_VERSION` by hand in both `project.yml` and
`project.pbxproj`):

```bash
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Release -destination 'generic/platform=iOS' -archivePath build/Smooth.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Smooth.xcarchive -exportPath build/export -exportOptionsPlist docs/appstore/ExportOptions.plist -allowProvisioningUpdates
```

The export step uploads straight to App Store Connect, using the Apple
account signed into Xcode. Submitting for review is a separate, manual
step in App Store Connect; there is no API key on the dev Mac.

## Test baseline

**Current on `agent/connection-v11` at the merge of 2026-11-10 (about 06:45
UTC, 01:45 US Eastern): 3819 tests / 369 suites, all green, `swift test
--no-parallel` alone on Marco's Mac (55 s). The tree is `agent/connection-v11`
(the agent connection through the assignment-PDF pass, 3754 / 362) plus three
session branches merged that night, `claude/quiz-inclass-9d38b8` (+9 / +1:
`NothingToSubmitLabel`, `CourseKnowledgeHeldSyncTests`),
`claude/v11-backend-645aa0` (Deno only) and `claude/v11-phone-c7aaf2` (+43 /
+5: drafts, the attempt store, `CanvasSubmissionClient`, the review sheet),
plus Marco's `origin/v11` (+13 / +1: the Sweeper page and
`CompletionSwipe.Axis`); every merge was textual in CLAUDE.md and ROADMAP.md
only and the Swift merged itself, so this run is the first compile of the
combination. Deno 871, `deno task check` clean, Node 49. The device build of
this tree went on Marco's phone that night; at its first open (13:15 US
Eastern, 2026-11-10) the held sync and the PDF pass both worked for the first
time (Traps, the `.task` entry). The Phase 3 phone half ran for real on 2026-11-11 02:06 UTC: a draft
from Claude showed on the Problem Set 7 card and the review sheet marked it
`seen`; the redesigned sheet was approved on the phone the same night and
Decline reached the server; and at 22:52 ET 2026-11-10 the first real
Submit went through: Problem Set 7, drafted by Claude from the pooled PDF,
rendered on the phone, submitted from the review sheet, Canvas submission
id 357257138, attempt 1. Every phase of v11 has now run end to end on
Marco's phone.**

**Current on `claude/v11-phone-c7aaf2` (2026-11-10, off `agent/connection-v11`
`2503a3b`): 3797 tests / 367 suites, all green, `swift test --no-parallel`
alone on Marco's Mac (98 s), +43 / +5 over the 3754 / 362 below, nothing
removed: `CanvasSubmissionClientTests` (the CSRF header, the text, URL and
file bodies, the file two-step with no cookie on the upload, the confirm
GET, the attempt-before-POST order, one POST never retried, the
indeterminate branch, verify agreement), `AgentDraftTests`,
`AgentSubmitAttemptStoreTests`, `AgentDraftSubmitterTests` (never twice),
`AgentDraftsStateTests`, plus additions to `AgentConnectionClientTests`,
`AgentConnectionWiringTests` and `AgentConnectionCopyTests` (whose
`connected("claude")` pin became `connectedHeading` / `connectedNext`).
Blind: never on a phone, never against Canvas.**

**Before it, on `agent/connection-v11` (2026-11-10, early morning US Eastern):
3754 tests / 362 suites, all green, `swift test --no-parallel` alone on
Marco's Mac (88 s), +40 / +4 over the branch's 3714 / 358 of 2026-11-08:
the snapshot's Canvas ids and the assignment link lines (+7 / +1), and the
assignment-PDF pass (`AssignmentAttachmentPlannerTests`,
`CanvasFilesClientTests`, `AssignmentAttachmentWiringTests`, +33 / +3).
Deno 870 (was 824: the hardening, the drafts backend, the assignment
context, the file-retirement rule), `deno task check` clean, Node 46. The
Swift pass is blind: never run against real Canvas.**

**On `claude/quiz-inclass-9d38b8` (2026-11-10): the label fix's filtered runs
green (`DueValueSecondaryLabelTests` 8, `NoSubmissionCaveatTests` +1, 40 tests
in 3 suites); full `swift test --no-parallel` alone on Marco's Mac: 3760 / 362, all green
(55 s), +6 over the 3754 / 362 below. Then the held course-material sync
(`CourseKnowledgeHeldSyncTests`, +3 / +1): 3763 / 363, all green (85 s). No iOS
build (no iOS-only code touched).**

**Chrome extension (a separate suite; never add it to the Swift or Deno
counts): 517 tests, all green, on `v8` (2026-11-04, `cd chrome-extension
&& npm test`, node 22 in the cloud container), plus the closed-loop
harness `npm run e2e` (real Chromium, fake Ed/Canvas/backend; see
`docs/CHROME_EXTENSION.md` → Status, 2026-11-04).** The pure core: term,
course code, assignment ids, content hash, ICS (74), dedup (64),
Gradescope parsing (51), the sync snapshot (18, pinned to the shared
AES-GCM vector the Swift suite also pins), and the course-material
builders (141: HTML text, Canvas URLs, Canvas documents, Ed, sync plan).
Plus 23 for the work list (the phone's todo · all · prev rules and due
phrases) and the Canvas and Gradescope readers against a fake fetch.
Plus 32 for the backend client, the pairing state machine and the QR
encoder (whose pinned matrices were decoded back to their exact input by
OpenCV in a scratch venv; that check is not part of `npm test`).
Plus 28 for the collector and the Ed course matcher, against a fake fetch
and a fake backend.
Plus 14 for the encrypted device sync (a two-device round trip through a
fake backend) and the popup's merge of the phone's work list.
Plus 13 for Canvas Files (listing, skips, caps, non-fatal failures) with
an injected extractor; pdf.js itself is checked only by hand in headless
Chromium, not by `npm test`.
Plus 9 for the worker's collection run (throttle, back-offs, persistence
on a stop, follow-up calls). `node --test` takes
a quoted glob (`"test/*.test.js"`), not a directory, on node 22.

**Current on `agent/connection-v11` (2026-11-08, evening): 3714 tests / 358
suites, all green, `swift test --no-parallel` alone on Marco's Mac (85 s), +40
/ +6 over `v10`'s 3674 / 352 (`CanvasSubmitSpikeTests` 9; the Phase 2 agent
connection: `AgentLinkRequestTests`, `AgentSnapshotBuilderTests`,
`AgentConnectionClientTests`, `AgentConnectionCopyTests`,
`AgentConnectionWiringTests`, `AgentSnapshotPassTests`); the iOS Debug build
(`generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`) succeeds. Deno 824 passed
(was 713: the agent connection's store, auth, mcp, tools, snapshot and
connector-front tests), `deno task check` clean, `node --test
backend/scripts/*.test.mjs` 30, `backend/scripts/sql-check.sh` green with the
agent migration applied twice. Nothing from this branch is on a phone or
deployed.**

Before it: **on `v10` (2026-11-07, evening, every post listed, the 3-day grace):
**Current on `v11` (2026-11-10): 3687 tests / 352 suites, `swift test
--no-parallel` on Marco's Mac.** +13 / +1 over `v10`'s 3674 / 351: two
`CompletionSwipeTests` for the drag-direction rule and the new
`SweeperOverridesTests` (11). In that run two things failed and both are
accounted for. `DashboardSmallFixesTests` pinned the 48pt header
squircle; it now pins 42pt drawn with a 44pt hit area, on purpose. The
`AnnouncementFuzzTests` 5-second cap was missed while an `xcodebuild` ran
alongside; alone it passed 2/2. The signed iOS Debug device build of the
same tree succeeded.

Before that: Current on `v10` (2026-11-07, evening, every post listed, the 3-day grace):
3674 tests / 351 suites, all green, `swift test --no-parallel` on Marco's Mac
(85 s); the signed iOS Debug device build (3.4.1 (20)) is on his phone and
launched.** -26 over 3700 / 351 on purpose: 31 tests that pinned the 7-day
window, the keep-check and the staff-post hiding went with those rules
(`AnnouncementSheetRulesTests` 10, `AnnouncementRelevanceTests` 21), 5 added
(`AnnouncementSheetSplitTests` judgment cases, the badge history test); one
Ed-rows test re-pinned to list the staff post.

Before it: **on `v10` (2026-11-07, the megaphone's todo · prev split): 3700
tests / 351 suites, all green, `swift test --no-parallel` on Marco's Mac
(86 s); the signed iOS Debug device build succeeded and is installed on his
phone (launch refused while locked).** +2 over 3698 / 351 on purpose:
`AnnouncementSheetSectionsTests` (5) went with the sheet's cards and fact
rows; `AnnouncementSheetSplitTests` (7) pins the todo · prev rule.

Before it: **on `v10` (2026-11-06, night, the megaphone's dashboard controls):
3698 tests / 351 suites, all green, `swift test --no-parallel` on Marco's Mac
(87 s); the signed iOS Debug device build succeeded (built 14:55 EST; the
phone was unreachable for the install).** -2 / -1 over 3700 / 352 on
purpose: `AnnouncementSheetTapTests` (6) went with the class bubbles;
`FactApplicationTests` +3 (the shortened-title duplicate rule) and the
switch-label test +1.

Before it: **on `v10` (2026-11-06, evening, the megaphone's two sections): 3700
tests / 352 suites, all green, `swift test --no-parallel` on Marco's Mac
(89 s); the signed iOS Debug device build succeeded and is on his phone.**
-8 / -1 over 3708 / 353 on purpose: `AnnouncementSheetUndoTests` (3) went
with the sheet's undo and `AnnouncementSheetCompiledTests` (10) with
`announcementSheetCompiled`; `AnnouncementSheetSectionsTests` (5) pins the
to-do and brief ordering instead.

Before it: **on `v10` (2026-11-06, the merge for production): 3708 tests / 353
suites, all green, `swift test --no-parallel` on Marco's Mac (53 s), the only
run on the machine; iOS Debug simulator build (`iPhone 17 Pro`) succeeded
twice on the same tree; Deno 713 and `deno task check` clean.** +10 / +1
over 3698 / 352: `CanvasLockedCompletionTests` (7, the prev swipe-back fix
from `docs/TEST_REPORT_2026-11-06.md` finding 6) and three
`SyncSummaryFormatTests` (the `error kinds` breakdown). Stamped 3.4.1 (18).

Before it: **on `v10` (2026-11-06, dashboard design pass): 3698 tests / 352
suites, all green, `swift test --no-parallel` on Marco's Mac (55 s); iOS
Debug device build succeeded and is on Marco's phone.** +2 over 3696:
+1 `ExamCardStyleTests` (grey palette), +2 `NoSubmissionCaveatTests`
(`sourceText`), +3 `DueValueSecondaryLabelTests` ("in class"), and 4
removed on purpose with the "older hidden" line (`SignupBacklogCopyTests`,
which only pinned that line's words; its suite went with them, the new
label suite replaced the count).

**Before it, on `v10` (2026-11-06, later): 3696 tests / 352 suites, all green,
`swift test --no-parallel` on Marco's Mac (52 s), the only test run on the
machine; the iOS Debug simulator build (`iPhone 17 Pro`) succeeded on the
same tree; Deno 713 and `deno task check` clean.** +5 tests / +1 suite over
3691 / 351: `FactTitleTests` (the short collapsed title of a fact row),
`AssistantPresentationTests.canvasLinkEdges` and two `AnswerLinkPolicyTests`
(ask's Canvas links go through `CanvasAppLink`). Deno +2: the `new_task`
title strip. Earlier the same day: **3691 tests / 351 suites, all green, `swift test
--no-parallel` on Marco's Mac (66 s), the only test run on the machine; the iOS
Debug simulator build (`iPhone 17 Pro`) succeeded on the same tree; Deno 711
and `deno task check` clean.** +3 tests / +1 suite over 3688 / 350:
`AnnouncementSheetUndoTests` (the megaphone changed row's `undo`, bug hunt
item 5's second half) and three new rows in `ConnectFailureRecoveryTests`'
save-row truth table (item 17's gap). The first full run of the day was
3688 with one red, `AskKnowledgeWiringTests` "cites the syllabus it quoted":
not a regression but Apple's on-device model paraphrasing under the test
runner (see Traps, "Apple Intelligence rewrites the on-device answer under
`swift test`"); `OnDeviceLanguageModel.compose` now returns nil under the
test runner, and the rerun was 3688 green before the two fixes landed.

Before that: **on `v10` (2026-11-05, evening, uncommitted tree before the bug-hunt
fix commit): 3688 tests / 350 suites, all green, `swift test --no-parallel`
on Marco's Mac; the iOS Debug `xcodebuild` for `generic/platform=iOS` with
`CODE_SIGNING_ALLOWED=NO` succeeded; Deno 711 tests and `deno task check`
clean; Node `node --test backend/scripts/*.test.mjs` 29; the SQL check in
Docker (`backend/scripts/sql-check.sh`) applied all 16 migrations, both
facts migrations twice for idempotency, and passed RLS, the 11 claim checks
and the 6 new `finish_fact_extraction` checks.** +57 tests / +2 suites over
3631 / 348: the fix pass for `docs/V10_BUG_HUNT_2026-11-05.md` items 1-21,
23-25, 27, 28 and 32 (its Status table says what each became). Tests
rewritten because they pinned the old, wrong behaviour: `FactApplicationTests`
`rejectedDoesNotSupersede` → `rejectedIsAVerdictOnTheKey`;
`ManifestContractTests` `wholePipe` (cancel and reschedule of one target now
share a key, the newer reschedule wins); `CanvasStructuredSourcesTests`
`quizDiscussionIDs`, `completionAndUndated`, `prefixes` and
`StructuredSourcesWiringTests` `moduleRequirementBySource` (module
completions now carry a requirement type that means done; pages are keyed by
course); `AppliedFactsWiringTests` `requestCarriesCursor` (a request needs a
recorded course set); `SessionProbeGateTests` "the clock alone … show
nothing" (now with a saved credential, since without one three positive
landings deliberately show the sign-in row). New suites:
`OnDeviceCancelledItemsTests`, `SilentReloginReviewTests` (note: its display
name is "Silent re-login review fixes", so `--filter SilentRenewalCore`
misses it; filter on the type name). Nothing from this pass is on a phone.

Before it, **on `v10` at `e0ab790` (2026-11-05): 3631 tests / 348 suites, all
green, `swift test --no-parallel` on the GitHub macOS runner with Xcode 26.3
in 111.5 s (the `tests` workflow, run 42084961566), the first runner compile
of today's blind tree work: +35 tests and +3 suites over 3596 / 345 (the
tree reading applied facts, `28e8803`; the time-frame resolver and per-intent
freshness, `fae20bd`; a prediction of +37 was two high, the runner's count
stands). Every push to `v10` that day compiled green (`e720b82`, `f4f17e9`,
`28e8803`, `f398bd0`, `e0ab790`). Re-verified on Marco's Mac at `09bec0d`
later on 2026-11-05: 3631 / 348 green, `swift test --no-parallel`, 126.5 s
of tests (373 s wall with the build), and the iOS Debug `xcodebuild` for
`generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO` succeeded with no
errors, so the widget and the iOS-only files compile too. Nothing from
today's tree work is on a phone yet.**

Before it, **on `v10` (2026-11-04, evening): 3596 tests / 345 suites, all green,
`swift test --no-parallel` alone on Marco's Mac in 64 s, after the contract
and hostile-input tests below. Earlier that day: 3559 / 340,
`swift test --no-parallel` on Marco's Mac, with all of the 2026-11-04 work
(structured Canvas sources, the identity layer, the applied-fact store and
engine, the facts wire and the megaphone/card changes): +102 tests / +9
suites over the merge below. Deno 671 (was 628), `deno task check` clean.
Later on 2026-11-04 the SQL was executed for the first time, in a throwaway
postgres:16 container (OrbStack): the auth stub, all 15 migrations in order,
the facts migration a second time (idempotent), `rls.test.sql` and the new
`test/claim_fact_extraction.test.sql` (11 checks: the claim state machine,
three attempts, stale-running recovery, the three budgets, the revoke).
`backend/scripts/sql-check.sh` reproduces that run. Deno 686 after the
hostile-input tests and the deploy scripts' 12 Node tests
(`node --test backend/scripts/*.test.mjs`). No iOS build was part of this run;
see Known gaps for the device state.**
One thing to know about that figure: the first full run that day showed
three failures, all wall-clock thresholds in the fuzz suites, while a second
full run and a filtered run were sharing the Mac; the fuzz suites alone
passed in 68 s and none of the code they exercise had changed. Run the
suite alone before reading a fuzz timing failure as a regression.

Before it, **on `v10` (2026-11-03): the merge of `v9` (3442 / 329 at the
onboarding-polish merge, plus the sign-in work) and `origin/v8` `7e004c5`
(3414 / 329, the tree's recency and follow-up work): 3457 tests / 331
suites, all green, `swift test --no-parallel` on Marco's Mac, 115 s,
exactly the predicted sum (3442 + 15, 329 + 2). Deno 628, `deno task
check` green.**

Before it, on the two lines that merged:

**Current: 3442 tests / 329 suites, all green, on `v9` at the merge of `origin/onboarding-polish-2026-10` (2026-11-02, `swift test --no-parallel`, on Marco's Mac, 78 s).** The no-banner sign-in work (`e9a2c71`) took the count from 3420 to 3439 (the `bannerHasVerdict` table and the two retry tests pinned to the one-hour cooldown and the ten-minute timeout retry were deleted with those rules, replaced by status-line, keepalive, Duo and spacing tests), and the onboarding-polish merge added `DuoPasscodeAutofillTests` (+3 / +1 suite). The iOS Debug device build of the same tree succeeded and was installed on Marco's iPhone 17 Pro.

**Previous: 3420 tests / 328 suites on `v9`, all green, on `v9` (2026-11-01, `swift test --no-parallel`, on Marco's Mac, 120 s), the probe-before-expired sign-in fix (`docs/SIGNOUT_2026-11-01.md`), +21 tests over `v8`.** A first run with two implementer agents compiling beside it failed only the three timing assertions in "Fuzz: very long announcement text" (195 s for a 10 s budget); the quiet re-run passed them. One filtered run hung after printing its pass line (the known teardown hang); the re-run did not.

**Previous: 3399 tests / 327 suites on `v8` at `8b691b6` (2026-10-29, `swift test --no-parallel`, on Olisa's Mac, 61 s): two failures and the SEC-10 known issue.** The first run of `30c4132` did not compile: `GradescopeSessionKeepTests` wrote an offset as `15 * 60` in a tuple array, typed `Int` (fixed in `8b691b6`, `hour / 4`). The two failures were `OwnTaskRemovalTests`' stop-repeating tests counting all ten weekly occurrences where the dashboard's term cap (`AppState.withinTermCap`) keeps nine once ten weeks from late October passes the term's end; the tests now count what the cap keeps (`fbb0296`). SEC-10 is fixed in the extension (`decide()` drops anonymous threads after private, as `EdThreadFilter` does) and its `withKnownIssue` wrapper removed, so `EdFilterParityTests` now asserts parity outright. Both fixes are blind until the next Mac run. The iOS Debug device build of `30c4132` succeeded and was installed on Olisa's iPhone 17 at 13:57 local the same day.

**Previous: 3402 tests / 328 suites on `onboarding-polish-2026-10` (`origin/v8` `019e1a5` plus the 2026-10-30 onboarding polish; 2026-10-30, `swift test --no-parallel`, on Marco's Mac, 109 s), all green after two source-pinning tests were updated to the new intent (`ReconnectCoverTests` now expects the preview door on the school pane and not on the Canvas pane; `SweeperOnboardingTests` expects one line). +3 tests / +1 suite over 3399/327: `DuoPasscodeAutofillTests`. The first run of this tree had exactly those two tests red and nothing else; the practice-guide tests were rewritten with the `.finished` step's removal and stayed green.** The iOS Debug device build (3.4.0 (17)) of the same tree was installed on Marco's iPhone 17 Pro the same afternoon and launched onto the intro. Before that: **Current: 3399 tests / 327 suites on `v8` at `8b691b6` (2026-10-29, `swift test --no-parallel`, on Olisa's Mac, 61 s): two failures and the SEC-10 known issue.** The first run of `30c4132` did not compile: `GradescopeSessionKeepTests` wrote an offset as `15 * 60` in a tuple array, typed `Int` (fixed in `8b691b6`, `hour / 4`). The two failures were `OwnTaskRemovalTests`' stop-repeating tests counting all ten weekly occurrences where the dashboard's term cap (`AppState.withinTermCap`) keeps nine once ten weeks from late October passes the term's end; the tests now count what the cap keeps (`fbb0296`). SEC-10 is fixed in the extension (`decide()` drops anonymous threads after private, as `EdThreadFilter` does) and its `withKnownIssue` wrapper removed, so `EdFilterParityTests` now asserts parity outright. Both fixes are blind until the next Mac run. The iOS Debug device build of `30c4132` succeeded and was installed on Olisa's iPhone 17 at 13:57 local the same day.
Deno on `phase0/extract-facts-bench` (2026-11-03): 626 passed, 0 failed, `deno task check` green; +12 for `facts.test.ts`.


**Current: 3414 tests / 329 suites, all green, on `v8` at `b85ef70`
(2026-11-02, `swift test --no-parallel` alone on Marco's Mac, Xcode 26.6,
65.1 s, from a fresh `.build`; the same count the `tests` workflow reported
at `01a71db` on the macOS 26 runner, 100.8 s, run 41482109986, and at
`784da81` on the macOS 15 runner, run 41484871951; the commits between
change only docs).** The
first compile of the week's blind tree work: +15 tests and +2 suites over
3399/327, exactly as predicted (`AskMeetingExcerptTests`,
`ConversationHistoryTests`, two `RecencyIntentTests` cases, one request
test). The first pass at `8bbbc67` failed one test, the three-turn chain
in `FollowUpRetrievalTests`, which pinned that no earlier question is on
the wire; the history change reverses that on purpose and the pin was
rewritten (`01a71db`), nothing loosened. The runner is a fresh machine
each time, so the shared-defaults trap cannot bite there; the iOS
`xcodebuild` is still not covered, and nothing from this tree has been on
a phone. `.github/workflows/tests.yml` runs this plus Deno (470/0) and the
extension's suite on every push to `v8`.
Before it: **3399 tests / 327 suites on `v8` at `8b691b6` (2026-10-29, `swift test --no-parallel`, on Olisa's Mac, 61 s): two failures and the SEC-10 known issue.** The first run of `30c4132` did not compile: `GradescopeSessionKeepTests` wrote an offset as `15 * 60` in a tuple array, typed `Int` (fixed in `8b691b6`, `hour / 4`). The two failures were `OwnTaskRemovalTests`' stop-repeating tests counting all ten weekly occurrences where the dashboard's term cap (`AppState.withinTermCap`) keeps nine once ten weeks from late October passes the term's end; the tests now count what the cap keeps (`fbb0296`). SEC-10 is fixed in the extension (`decide()` drops anonymous threads after private, as `EdThreadFilter` does) and its `withKnownIssue` wrapper removed, so `EdFilterParityTests` now asserts parity outright. Both fixes are blind until the next Mac run. The iOS Debug device build of `30c4132` succeeded and was installed on Olisa's iPhone 17 at 13:57 local the same day.
**Current: 3373 tests / 322 suites on `release/3.3.1` (the three-way merge of `fix/duplicate-category-ids`, `origin/v8` and `claude/sharp-newton-qwv18v`, plus the notification-tap crash fix; 2026-10-27, `swift test --no-parallel`, on Marco's Mac), all green.** Deno: 614 tests, `deno task check` green. iOS Simulator and device Debug builds of the same tree succeeded; the device build (3.3.1 (17)) was installed on Marco's phone that evening, launched, refreshed once, and left no crash report. Before that: 3346 tests / 320 suites on `fix/duplicate-category-ids` (`v8` `e3a57b3` plus the A1 crash fix, Release A, and the hardening groups of 2026-10-27; 2026-10-27, `swift test --no-parallel`, on Marco's Mac, with no other worktree testing at the same time), all green.** Deno: 599 tests, `deno task check` green on Deno 2.9 (`cd backend && deno task test`). The one red test since `aeaf982`, `AskCitationLinkTests` "the encoded request is byte-identical…", was a golden re-typed by hand with `America/New_York` where `JSONEncoder` writes `America\/New_York`; the golden was fixed on 2026-10-27, not the encoder. The new tests since `e3a57b3` are `DuplicateCategoryIDTests` (17, the launch crash, `docs/LAUNCH_CRASH_2026-10-26.md`; run against the original source they die with the production trap), `ReconnectCoverTests` (two suites, the A2 cover, plus two existing tests adjusted), and `SessionCookieLiveSessionTests` (10) with three Keychain tests in `SessionCookieStoreTests` (the A3 gate).  Before that: 2907 / 262 on `v8` `e3a57b3` (2026-10-25, the audit's gate run, same one failure).

**Current: 2933 tests / 264 suites, all green, on `v8` at `17ce51f` (2026-10-27, `swift test --no-parallel`, on Olisa's Mac, 15.5 s), first run.** +43 tests and +4 suites over 2890/260: the tree-plan work of 2026-10-25 (`aeaf982`: local dates in the context document and excerpt block, kept excerpt structure, `WebsiteDiscoveryBatches`, the citation contract, the retrieval bench), compiled here for the first time. The Swift tree is unchanged through `6195eae` (later commits touch only the extension, the backend and docs). The iOS build of this tree (`xcodebuild`, which `swift test` does not cover) has not been run yet.
**Current: 2933 tests / 264 suites, all green, on `claude/sharp-newton-qwv18v` at `3c23d9d` (2026-10-27, `swift test --no-parallel`, on Olisa's Mac, 13.4 s), first run: the feedback card and Profile row of 3.3.0 (16), +19 tests and +2 suites (`FeedbackNoticeTests`), nothing lost. The iOS Debug build of the same tree (widget included) succeeded the same run.**
Before it: **2914 tests / 262 suites, all green, on `claude/sharp-newton-qwv18v` at `c6d404b` (2026-10-27, `swift test --no-parallel`, on Olisa's Mac, 15.3 s), second run.** The first run (`99d4006`, 17.7 s) failed one test, `AskCitationLinkTests` "the encoded request is byte-identical…", whose golden string `aeaf982` (2026-10-25, blind) re-typed with a bare `/` where `JSONEncoder` writes `\/`; `c6d404b` fixed the string. These runs are the first compile of the 2026-10-25 tree-plan work and of the update lock (`f89d908`, seven new `UpdateGateStoreTests`). The iOS Debug build of the same tree (`generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`, widget included) succeeded on Olisa's Mac the same day.
Before it: **2890 tests / 260 suites, all green, on `v8` at `04350cf` (2026-10-24, `swift test --no-parallel`, on Olisa's Mac, 12.8 s), first run.** It is the 3.2.0 release line (Marco's `fix/megaphone-every-class`, below) plus Marco's Smooth Sweeper settings (`codex/sweeper-settings`, PR #12) and the takeover fix (`8067691`), stamped 3.2.0 (15): the sweeper's changed `LoudAlertTests` and `BerserkAlarmTests` and the new parameterized takeover test, nothing lost. It is the first full run the sweeper code has had (Marco ran 109 targeted tests). The iOS Debug build of the same tree succeeded on the first try and was installed and launched on Olisa's iPhone 17 at 20:22 local on 2026-10-24, where the Sweeper section showed under reminders as designed (his screenshot). The footer removal (`311eeeb`) built for iOS and was installed at 20:28. A non-default alarm, a class switched off and the defaults ringing are not yet checked there.
Before it: **2885 tests / 260 suites, all green, on `fix/megaphone-every-class` (PR #13) with `origin/v8` `fb3ed94` merged in (2026-10-23 about 22:10, `swift test --no-parallel`, on Marco's Mac, 29.2 s); the iOS device build of the same tree succeeds.** That is `v8`'s 2736 (Olisa's Marco merge, pushed uncompiled, its one stale structure test fixed here) plus the 149 PR #13 adds: 2755 on the old base `a480eb1`, and `v8` grew by 130 since that base, 2755 + 130 = 2885, so nothing was lost in the merge. Deno: 468 with `--no-check` (Olisa's 428 plus 40).

Either tree compiles for iOS in Debug and Release (`xcodebuild
-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`), which
is what builds the widget extension and `BackgroundRefresh.swift`; `swift
test` compiles neither, so a change in `LHFWidget/` or behind `#if
os(iOS)` needs that `xcodebuild` before it counts as compiled. `v8` before
either line's work was 1539/154 at `e2672eb` (2026-10-09). Hold the rule:
a change that lowers the count has lost work. Investigate rather than accept it, and when a
count drops on purpose (a feature removed with its tests), say which tests
and why in the commit.

Known problems, all pre-existing:
- **Full-run hang.** A parallel `swift test` sometimes stops forever with
  the main thread inside `SecItemCopyMatching` →
  `ItemImpl::checkIntegrity` (the legacy macOS file keychain). It is not a
  Keychain prompt; no SecurityAgent is running. Sampled 2026-09-23 through
  `CanvasAccessTokenStore.load()`; `fac110d` gated that read behind
  `FeatureFlags.canvasAccessTokenValue`, and it still recurred on
  2026-09-24 in the Keychain suites. `--no-parallel` has never hung. When
  it recurs, sample it from a second terminal before killing it:
  `sample $(pgrep -f LowHangingFruitKitPackageTests | head -1) 3 -file /tmp/sample.txt`.
- **`SessionCookieStoreTests` "a calendar-link-only install … cannot use
  Grade Watcher"** reads `canvasSessionExpired` as true. It passes alone
  and in `--no-parallel` runs, but fails most parallel full runs since the
  session-persistence commits (`fac110d`..`99609c0`, 2026-09-24); before
  them it was about one run in ten. A cross-suite race over process-wide
  state that hasn't been pinned down.
- **`CourseContentDashboardTests`** ("flipping a content decision never
  changes `canvasCourseIDsByCode`…") races another suite over shared
  `UserDefaults`, perhaps one run in four. See the shared-`UserDefaults`
  trap: the fix belongs in the polluting suite, not the assertion.

Two lessons from diagnosing the hang: `swift test 2>&1 | grep` fully
buffers the runner's stdout, so the last line printed is not where it
stopped (use `script -q /tmp/log swift test` for a pty); and `--filter`
matches Swift type names (`SessionCookieStoreTests`, or
`SessionCookieStoreTests.testName` with multiple `--filter` flags), never
the quoted display names.

History (newest first; each verified on a Mac). The notes say what moved
the count, so a later drop can be traced:
- 3631/348 `v10` at `e0ab790`, 2026-11-05, GitHub runner (Xcode 26.3, 111.5 s):
  the tree's applied-facts work list (`AppliedFactsWiringTests` +5,
  `AssistantContextDocumentTests` +3) and `AskTimeFrameRegressionTests` (3
  suites); one test in `AskRecencyExcerptTests` rewritten because "when is
  the midterm" is now a `policy` question (its syllabus boost is 1.5).
- 3596/345 `v10`, 2026-11-04 evening: `ManifestContractTests` (a manifest the
  server's own `factsResponse` built, decoded by the phone), hostile-input
  suites for the wire and the structured decoders, a 500-round engine fuzz,
  `FactsPurityScanTests`; the fixes they forced (a `flexString` trap on
  `1e300`, a nondeterministic tie in `FactApplication`, seq/cursor bounds,
  lossy `postedAt`, hex rate-limit headers) are in `v10` with them.
- 3559/340 `v10`, 2026-11-04: composed-day Phases 1-3 (+102 / +9 suites): six new test files
  (`WorkItemIdentityTests`, `CanvasStructuredSourcesTests`,
  `StructuredSourcesWiringTests`, `AppliedFactStoreTests`,
  `FactApplicationTests`, `AppliedFactsWiringTests`) and additions to
  `BackendWireTests`; one existing test was rewritten on purpose: the
  assignment-document test in `CourseKnowledgeTests` now asserts that pooled
  text carries no "Status: submitted" line (see Traps).
- 3457/331 `v10`, 2026-11-03: the merge of `v9` and `origin/v8`.
- 2736/246 `origin/v8` at `fb3ed94` (Olisa's `v8-merge-marco` fast-forwarded, pushed uncompiled, predicted 2736), compiled and run on Marco's Mac 2026-10-23 ~22:00, `swift test --no-parallel`, 28.1 s: **one failure**, `DeviceSyncWiringTests` "a pass is called from the foreground refresh and the launch task, never from the background wake". The test checks call order by text position inside `ContentView.refresh()`; `launch-refresh-rework` moved the grades fetch and the reload into `fetchSessionSources()` / `settleAfterFetch()`, so the positions reversed while the runtime order (fetch, device-sync pass, reload) is unchanged. Test fixed in PR #13's merge of this tip, not a code regression.
- 2755/251 `fix/megaphone-every-class`, 2026-10-23 late, `swift test
  --no-parallel` on Marco's Mac, 23.6 s, green: +3 in `NonClassCanvasSiteTests`
  ("TAP 2028" is never a class) and the compact two-row bubbles. iOS build
  succeeds.
- 2752/250 `fix/megaphone-every-class`, 2026-10-23 evening, `swift test
  --no-parallel` on Marco's Mac, 23.4 s, green, after the class bubbles
  (`AnnouncementSheetBubblesTests`, +20) and `fix/relevance-backfill`
  merged in (`RelevanceBackfillTests`, +13); the two-row bubble layout
  came after it (layout only; the 55 sheet tests re-ran green and the iOS
  build succeeds).
- 2719/246 `fix/megaphone-every-class` (not yet on `v8`), 2026-10-23,
  `swift test --no-parallel` on Marco's Mac, 21.3 s, green, with
  `fix/ed-posts-durable` merged in; the iOS build of the same tree
  succeeds. +113 tests and +9 suites over `v8`'s 2606/237: the every-class
  list and the finished-twin rule (`AnnouncementFindTwinTests` and new
  `AnnouncementSheetTests` cases), the camelCase/"worksheets" matcher
  cases, the keep-check (`AnnouncementRelevanceTests`,
  `AnnouncementRelevanceSyncTests`), staff posts and their daily cap
  (`EdStaffReadBudgetTests` and pass tests), and the Ed fix's 13
  (`CourseKnowledgeCollectorEdTests`, `EdRestoreDropPlanTests`, three
  `CourseKnowledgeBaseTests`). Changed on purpose: two
  `AnnouncementEdRowsTests` cases now expect a staff post as a marked
  candidate row the sheet does not list, and the relevance wire test reads
  a date-only `until` as the end of that day. Deno: 459 with `--no-check`
  (see the backend commit `36e3aee` for why `deno task test` stops at
  type-checking on Deno 2.9.8).
- 2397/214 `v8`, 2026-10-20, verified on Olisa's Mac (2393/213
  at the merge commit, then +4 tests and the parent suite
  `AnnouncementExtractionSuites` from the review: `movedExamIsNotTheSyllabusTwin`
  and `threeFailuresGiveUp` and `backoffAfterAnAllFailedRun` in
  `EdAnnouncementTaskMergeTests`, `canvasPostRestatingAnEdFindAddsNoRow` in
  `AnnouncementWatcherSyncTests`; the harnesses of
  `EdAnnouncementTaskTests` and `EdAnnouncementTaskMergeTests` now also back
  up and clear the retry counters and the back-off, which the Ed pass writes
  with a fixed test clock): the
  merge of `v8` (Olisa) and `v8-loud-alert-actions` (Marco). Arithmetic:
  1975/189 (common base) + 357/20 (Marco) + 58/3 (Olisa) = 2390/212, then
  the merge's own changes. **Deleted on purpose (6, none of Marco's):** in
  `AnnouncementWatcherEdTests` (now `AnnouncementWatcherSyncTests`),
  because they fed Ed posts through `syncAnnouncements` or pinned the
  `announcement-ed:` find id of the Canvas loop's brief Ed reading, which
  the merge removed in favour of Marco's own Ed pass: `edPostBecomesFind`,
  `staffAndPinnedPostsAreRead`, `nothingElseIsRead`,
  `canvasAndEdTwinsMakeOneFind`, `edTwinOfAnEarlierFindIsDropped`; and in
  `AnnouncementLogTests`, `edAdapterSelection`, whose subject
  (`edAnnouncementsForExtraction`) was removed. The Ed pass's own
  selection is `EdAnnouncementTaskTests`'. **Added (9):**
  `edPostsAreNotReadHere` in the renamed suite, and the new suite
  `EdAnnouncementTaskMergeTests` (8: the posting day as the date and the
  window, the twin drop against the ledger and within a run, the quota
  stop, an ordinary failure still waiting, the summary lines, preview).
  **Rewritten, same names or renamed, none loosened:** the other 13 tests
  of the renamed suite now use Canvas announcements as fixtures (the
  summaries, the retry cap, the quota stop, the back-off);
  `AnnouncementLogTests` `edFindJoin` (Marco's `ed-` id and
  `recordID(fromFindSourceID:)`), `edAdapterUsesPostingDay` (now
  `edPostDateUsesPostingDay`, asserts `edPostDate`),
  `edFindCollapsesOntoCanvasAssignment`; `DashboardFilterTests`
  `expiredAnnouncementFindBoundaries` (asks `isHiddenAnnouncementTask`, and
  pins `isExpired` as the `.event` rule alone) and `pastDueFindVanishes`
  (its megaphone "find" fixtures now use informational wording, since
  Marco made every task a card); one call in Marco's
  `AnnouncementTasksOnDashboardTests` renamed `isExpiredEvent` →
  `isExpired`. Where the two sides could disagree, the tests worth reading
  first: `AnnouncementFindExpiryTests` (Olisa's vanish rule, whole) against
  `AnnouncementTaskRulesTests` (Marco's rule). Compiled: no.
- (`v8`'s own history, newest first)
- 2033/192 `v8`, 2026-10-19 (evening): the work-identity dedup tier
  (`AssignmentDeduplicatorTests`, 13) and the extraction retry cap
  (`AnnouncementWatcherEdTests`, 5; the suite is `AnnouncementWatcherSyncTests` since the merge).
- 2015/192 `v8`, 2026-10-19 (later): announcement and Ed tasks vanish at
  their due time (`AnnouncementFindExpiryTests`; its first run had one
  failure from fixture titles the twin check merged, fixed in `6291b2f`).
- 2008/191 `v8`, 2026-10-19 (afternoon): Ed posts through the
  Announcement Watcher (`AnnouncementWatcherEdTests`,
  `AnnouncementLogTests`), the sync summaries and the first-error line
  (`SyncSummaryFormatTests`).
- 1986/189 `v8`, 2026-10-19: the launch-prep merge plus the Ed
  posting-date fix (`EdDocumentHeaderTests`, `AnnouncementEdRowsTests`,
  `EdIngestionTests`, `EdClientTests`).
- (`v8-loud-alert-actions`'s own history, newest first)
- 2332/209 `v8-loud-alert-actions`, 2026-10-19: plus 4 tests for the
  alarm's custom sound (the pure choice, the file, the app target's
  Resources phase read from `project.pbxproj` as a property list, and
  the glue asking `Bundle.main`).
- 2328/209 `v8-loud-alert-actions`, 2026-10-19, `swift test --no-parallel`
  alone on the machine: 2269/207 plus 59 tests and 2 suites for the
  AlarmKit alarm (`BerserkAlarmTests`, `BerserkAlarmDeliveryTests`: the
  plan's parity with `loudAlerts`, stop never "turned in", the delivery
  and settlement tables, "every loud item ends with exactly one of alarm
  or buzzes", ringing-alarm rules, the reschedule serializer). Each review
  fix was reverted in turn and its tests seen failing. The iOS Debug build
  extracts App Intents metadata for both alarm intents; the macOS build
  (`CODE_SIGNING_ALLOWED=NO`) succeeds too.
- 2269/207 `v8-loud-alert-actions`, 2026-10-19, `swift test --no-parallel`
  as the only run on the machine: 2230/206 plus 39 tests, nothing removed.
  One new suite (`LoudAlertActionTests`: categories, labels, parsing,
  the bound-before-drain inbox, staleness, silencing at the tap, and
  source scans of `LHFApp.init` and the scheduler's delegate) and new
  request tests in `LoudAlertTests`. Each review fix was reverted in turn
  and its own test was seen failing.
- (`fix/submission-status`'s own history)
- 2265/208 `fix/submission-status`, 2026-10-18, `swift test --no-parallel`
  as the only run on the machine: 2230/206 plus 35 tests, nothing removed.
  Two new suites (`GradescopeTitleStatusTests`,
  `SectionOverrideCompletionTests`), six tests in
  `AssignmentDeduplicatorTests` and the detail-page tests in
  `GradescopeTests`. The title and id-veto tests were checked by
  neutering each fix and watching them fail; the table-layout and
  override pins pass on the old code too, and their comments say so. A
  third suite, `LaunchRefreshStructureTests`, left with the cold-launch
  fix for `parked/launch-submission-refresh` (2233/207 there);
  `parked/gradescope-unverified-submission` is 2240/206. Measured on
  Marco's Mac in 6.0 s, its base `v8-announcements` re-verified at
  2230/206 the same day; the iOS Debug compile
  (`-destination 'generic/platform=iOS'`) ended in BUILD SUCCEEDED.
- (`v8-server-exam-dates`'s own history)
- 2270/208 `v8-server-exam-dates`, 2026-10-18, `swift test --no-parallel` on
  Marco's Mac, 20.8 s, no other test run active when it started
  (`pgrep -f LowHangingFruitKitPackageTests` was empty): +40 tests and +2
  suites over the 2230/206 of `v8-announcements` it is built on. The
  server exam dates: 7 wire and persistence tests in
  `CourseGradingProfileTests`, the weekday-confirmation tests in
  `SyllabusExamExtractorTests`, and the two new suites
  `SyllabusExamServerRowsTests` and `SyllabusExamServerPassTests`. Nothing
  removed. The same tree compiled for iOS (Debug, generic device and the
  connected phone; Release `CODE_SIGNING_ALLOWED=NO`). The Deno tests were
  written there and not run under Deno (no Deno on that Mac; only under
  Node 24 with a `Deno.test` shim); they first ran under Deno on
  2026-10-23 on `v8-merge-marco`, see the Deno line below.
- 2230/206 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as the
  only run on the machine: the next two entries applied together.
  2190/202 plus 17 (the rules) plus 19 (the sheet) plus 4 new in
  `AnnouncementSheetTests.swift` for the two together: the found list
  follows `isHiddenAnnouncementTask` (an undated task a week past its post and
  a same-day be-there reminder are off it, a syllabus exam is never aged,
  and it equals the not-hidden rows one for one), and through an `AppState`
  the aged-out task and the reminder leave both the list and the badge while
  `announcementPageItems` still holds them. Nothing removed; nothing
  rewritten in the merge. The sheet's own `megaphone` test in
  `SyllabusExamDashboardTests` and the rules' tests merged without conflict.
  Each of the new rules was checked by breaking it (dropping the post dates
  from the call) and watching four named tests fail. One fixture lesson, as
  twice before: the first version of the one-for-one test used titles
  "Task 3 to hand in" and "Task 4 to hand in" with dates hours apart, which
  `resolvingAnnouncementDuplicates` correctly collapses into one card.
- 2209/205 `v8-announcements`, 2026-10-18, the sheet redesign alone (before
  the rules patch below was applied), `swift test --no-parallel` as
  the only run on the machine: 2190/202 plus 19 tests in three new suites
  (`AnnouncementSheetRulesTests`, `AnnouncementSheetBadgeTests`,
  `AnnouncementSheetStructureTests`, in `AnnouncementSheetTests.swift`)
  and one in `SyllabusExamDashboardTests`; nothing removed. Two existing
  tests were rewritten because they pinned the old sheet: `megaphone` in
  `SyllabusExamDashboardTests` ("leaves the syllabus's out" is now "holds
  the announced exam and the syllabus's, soonest first, and each leaves
  once its date has passed"), and `VisualStructureTests` "announcement and
  calendar quick actions have distinct accents" (the megaphone circle is
  marigold now, not the announcement teal). Each new rule was checked by
  breaking it (the window's `>=`, the not-past filter) and watching named
  tests fail.
- 2207/203 `v8-ann-rules`, 2026-10-18, `swift test --no-parallel` as the
  only run on the machine: 2190/202 plus 17. New: a suite
  `AnnouncementTaskRulesTests` (13: the attendance vocabulary pinned, the
  12-hour / same-day window, undated tasks on day 6 and day 8 from the
  log, the Ed document and the first-seen fallback, a found exam never a
  reminder, finished work still in prev, feed items untouched, no ledger
  row lost); 4 in `EdAnnouncementTaskTests` (a Sept 14 Ed post is not read
  on Oct 18 and an Oct 15 post is; the window is the Canvas constant; a
  post with no date is skipped); 1 in `SyllabusExamDashboardTests` (a
  finished past exam stays in prev). **Rewritten, because they pinned the
  "past tasks move to prev" rule that was the bug:**
  `AnnouncementTasksOnDashboardTests` `lapseRule` (now `pastRule`),
  `pastTasksMoveToPrev` (now `pastTasksDropOff`: not in todo, all or prev),
  `boundaryAndOrdinaryEvents`, `completingAPastTask` (now
  `finishingAPastTask`), `finishedTaskIsNotPast`, `editedDateDecidesLapse`
  (now `editedDateDecides`); `AnnouncementLedgerSafetyTests`
  `sameTitleTwoWeeksApart`, `liveTwinOutlastsLapsedTwin`, `lapsedOrder` (now
  `hiddenOrder`, the `lapsed:` argument is `hidden:`);
  `SyllabusExamDashboardTests` `pastExamGoesToPrev` (now `pastExamDropsOff`),
  `allDayLapsesAtTheEndOfItsDay`, `feedExamIsNotLapsed`, `pastExamSparedToo`,
  `hiddenClass`; `AnnouncementDeletionTests` `finishedTaskSurvivesDeletion`
  (lost its `isPast` check). **Removed:** `prevCardMarksPast`, a scan of
  `DoneView`/`ContentView` source for the "past" card, which no longer
  exists.
- 2190/202 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only run on the machine: 2164/201 plus 26 tests, the ledger-safety
  fixes from the review of the announcement-task commit. New: a suite
  `AnnouncementLedgerSafetyTests` (9: two days are two tasks, the live twin
  outlasts the lapsed one, no tick across dates or a reschedule, an edited
  date survives a hidden row); 7 in `AnnouncementDeletionTests`; 5 in
  `EdAnnouncementTaskTests` (retry backoff, the class going away during a
  read); 5 in `SyllabusExamDashboardTests` (an undated Canvas exam yields to
  a dated twin, the syllabus pass re-check). **Rewritten, because they pinned
  the behaviour that was the bug:** `AnnouncementDeletionTests` "a gone row
  ages out like a gone feed item, but finished work never does" (it asserted
  that `pruneAgedOut` deletes a flagged announcement row; now three tests
  assert it does not, and that feed rows still age), and the three
  end-to-end deletion tests that flagged a post on one absent response
  (`deletedPostIsHidden`, `restoredPost`, `finishedTaskSurvivesDeletion`) now
  take two, per the two-miss rule. `EdAnnouncementTaskTests` "a failed
  extraction leaves the post unread, and the next pass tries it again" now
  waits out the six hours. Each new rule was also broken on purpose and a
  named test failed (13 rules; two first mutations did not bite, because the
  mutation or the test was wrong, and a test was added for the carry in the
  title loop).
- 2164/201 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only run on the machine: 2100/198 (the tree with the loud alert, the
  vault sheet and the exam detector and card style merged in; measured
  before this change) plus 64 tests in three new suites (`ExamSittingTests`
  21, `SyllabusExamRowsTests` 14, `SyllabusExamDashboardTests` 29); nothing
  removed or rewritten. A first full run failed one existing test, "the
  per-class switch governs cards for Canvas and Ed together" in
  `AnnouncementTasksOnDashboardTests`: the first version of
  `isFoundExam` asked only whether a title named an exam, so the Ed task
  "Bring a calculator to the exam" counted as one and ignored the class's
  switch. The code was changed (`leadingExamIdentity`: the exam has to be
  what the title leads with), not the test, and a regression test now pins
  it. Each rule was also checked by breaking it and watching a named test
  fail (toggle and nothing-to-submit exemptions, the loud-alert guard, the
  megaphone exclusion, the identity match, all-day storage, placement and
  order).
- 2028/194 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only run on the machine: 1985/191 plus 43 tests in three new suites
  (`AnnouncementTasksOnDashboardTests`, `EdAnnouncementTaskTests`,
  `AnnouncementDeletionTests`); nothing removed. Two existing tests in
  `AnnouncementWatcherWiringTests` were rewritten because they pinned the
  rule the owner reversed (preparation tasks as megaphone-only finds):
  the placement vocabulary test now expects `.main` for preparation and
  keeps `.find` for informational wording, and the dashboard-surface test
  now expects the preparation row on the dashboard; both say so in a
  comment. A first run of the new suites failed three tests, all from
  fixtures whose titles were duplicates by design (two near-identical
  titles with close dates collapse into one card), fixed in the fixtures.
- 1985/191 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only test run on the machine: 1975/189 plus 10 tests in two new
  suites (`GradeWatcherRemovalTests`, `HeaderMegaphoneTests`) and two new
  `SettingsCopyTests`; nothing removed. Three existing tests were
  rewritten because they pinned the old layout, none loosened to pass:
  `SettingsCopyTests` "sign-in status and ed status render only inside
  the collapsed debug disclosure" (now: debug-only, under their account
  rows, no disclosure), `DashboardSmallFixesTests` "the add and
  announcements buttons have the same 44pt hit area…" (the megaphone is
  now the header's 48pt circle), and `VisualStructureTests` "announcement
  and calendar quick actions have distinct accents" (the megaphone tints
  with its accent through the shared header circle, no separate
  `smoothAnnouncementFill`). A first run overlapped another worktree's
  and failed two unrelated suites (the shared-defaults trap, below);
  the rerun alone was green.
- 1975/189 `v8-launch-prep`, 2026-10-10: `v8`'s 1539 plus 436, nothing
  removed. By commit, so a later drop can be traced: source links +25;
  the 10-minute reminder +17; the sign-up rule +43, and +16 when it was
  reworked to stay out of the sync; reminder wording +8; the
  announcements list +36 and its window fix +4; ask's search +27 and
  excerpts and follow-ups +54; saved due-date edits +28; ask and Ed +29,
  ask's own text +19, source chips +19; the Settings copy +6, ten small
  fixes +36, the widget +21; Grade Watcher copy +7; Ed rows in the
  megaphone +23; deleting your own tasks +18. Tests that pinned old
  wording were updated to pin the new wording exactly, never loosened;
  the one test whose subject disappeared ("class" against "classes" in
  a Grade Watcher message) was replaced by one for the string that
  replaced it. Four agents ran the suite in four worktrees at once
  while this was being built and saw unrelated suites fail at random;
  that is the shared-defaults trap, and none of those runs is a
  baseline.
- 1539/154 `v8`, 2026-10-09 (later that day): the sign-out review fixes
  (`SilentRenewalCoreTests`, `SwitchSchoolConfirmationTests`,
  `SignInHealthTests` rewritten) and the Ed session-token transport
  (three in `EdWiringTests`).
- 1499/152 `v8`, 2026-10-09: Ed Discussion ingestion (`EdIngestionTests`,
  `EdClientTests`, `EdKindTests`, `EdWiringTests`) and the sign-out fix
  (`RenewalPolicyTests`, `ReconnectPaneTests`, `SignInHealthTests`; two
  tests in `CanvasSessionDeadStateTests` rewritten for the new latch rule,
  none removed).
- 1411/140 `V7`, 2026-09-27: Olisa's 24-hour cookie rule restored
  (`df759f8`, `a16ea07`). Four tests removed on purpose because they pinned
  the "keep cookies forever" rule that was reverted:
  `SessionCookieRotationTests.sessionCookieWithoutExpiryIsRetained` and
  `.explicitExpiryIsAuthoritative`, and `SessionCookieStoreTests`'
  `finalCookieDeletionDoesNotResurrectPersistedValue` and
  `partialCookieDeletionDoesNotResurrectRemovedValue`.
- 1415/140 `V7`, 2026-09-25: `CourseAccentTests` (stable per-class
  colour) with the class-chip picker.
- 1412/139 `V7`, 2026-09-24: Settings trimmed, "1 week before" retired
  (one new test, two moved from `.d7` to `.d2`).
- 1411/139, 2026-09-24: class-filter and recurring-task course adoption.
  Dice and steps prototypes removed with their tests.
- 1407/138, 2026-09-24: session persistence (`fac110d`..`99609c0`), 12 new.
- 1395/138, 2026-09-23, on `V7-polish`.
- 1371/136 `v6`, 2026-09-23: Ed Discussion recon probe
  (`docs/ED_DISCUSSION.md`).
- 1336/130, 2026-09-17: gated Canvas access tokens and stay-signed-in.
- 1253/125 `v5`: expected after reverting the preview-mode removal on
  2026-09-16 (build 9). Not re-verified on `v5` itself.
- 1241/123, 2026-09-15: preview mode removed, 12 tests deleted with it
  (reverted next day).
- Earlier marks:
  - 1252/125 and 1253/125 (2026-09-15)
  - 1250/123 and 1244/122 (2026-09-12, the Smooth merge)
  - 1230/121 and 1193/119 (2026-09-11)
  - 1170/117, 1104/109 and 1068/105 (Grade Watcher rounds 1–3, 2026-09-10)
  - 1032/101 and 1020/98 (2026-09-09)
  - 976/95, 937/92, 853/90, 838/89 and 804/87 (early `v5`)
  - 736/76 and 769/78 (`assistant-ui`)
  - 693/70 (old `v6`), 608/61 (v3.5+v4 merge), 517/55 (`v3.5`)
  - 456/40 (`v4`)
- Deno: 473 passed, 0 failed on `v8` (2026-10-27, later): +2 for the
  `'server'` collector (the in-memory rule and the query's `neq`). The
  deployed `sync` v14 / `discover-websites` v5 source is v12's `a2e2b1b`
  with both patches: 424 there.
- Deno: 471 passed, 0 failed on `v8` (2026-10-27, Deno 2.9.8 `--no-check`,
  `deno check --no-lock` of `sync` clean): the 468 of PR #13 plus 3 for
  `storableText` (NULs and lone surrogates). The deployed `sync` v13 is
  v12's source `a2e2b1b` with the same patch: 422 there (419 plus 3).
- Deno, pending: 428 passed, 0 failed on `v8-merge-marco` (2026-10-23, the
  merge of Marco's `v8-server-exam-dates`: +9 in `db.test.ts` and
  `profile.test.ts` for `examDates`, the first run of them under real
  Deno; Deno 2.9.8 `--no-check`, and `deno check --no-lock` of every
  function's `index.ts` clean under 2.1.4). The merged tree is not
  compiled in Swift and `sync` is not redeployed with it (v13, of
  2026-10-27, is v12's source plus the NUL guard only, so the exam dates
  wait for v14).
- Deno: 419 passed, 0 failed (2026-10-23, `v8`, the window-kind rules of
  `docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md` Phase 2: announcements and Ed
  posts exempt from the complete-set rule, a 120-day age-out on read,
  the live read paginated in pages of 500 against the project's
  PostgREST `max_rows` of 1000, per-document rejection on upload, a
  150-per-class cap on window-kind downloads; 13 new tests, 4 edited
  because they pinned the extension retiring announcements; Deno 2.9.8
  `--no-check`, and the 2.1.4 type check clean; deployed as `sync` v12
  the same day).
- Deno before it: 406 passed, 0 failed (2026-10-22, `v8`, the Chrome extension's
  backend: pairing, linked devices, encrypted sync blobs, the `collector`
  rule and the `file` kind; in the cloud container with Deno 2.9.8 and
  `--no-check`, because `deno task test`'s type-check fails under 2.9.8 on
  three pre-existing `setTimeout` `Timeout`-vs-`number` errors in
  `quota.ts` and `ask/index.ts`, identical before the change. The four
  touched functions pass `deno check --no-lock`. The migration and
  `rls.test.sql` have not run: no Postgres in the container.)
- Deno before it: 370 passed, 0 failed (2026-10-20, the semester fix; 366 after the
  section-details change the same day, 350 before it; in the cloud
  container with Deno 2.9.7 and `--no-check`).
  `deno check` is clean under Deno 2.1.4 (`--no-lock`, the edge runtime's
  generation) and under 2.9 reports three pre-existing `Timeout` is not
  assignable to `number` errors (`quota.ts`, `outcomes.ts`), which are
  the newer toolchain's `setTimeout` types and not defects. The container
  cannot reach `penncoursereview.com`, so the live Penn Labs shape was
  checked against Penn Labs' own serializer source and the fixture, not a
  live call.

Nothing under `backend/` is exercised by `swift test`, and the live backend
path has only ever been exercised by hand on a device.

## Layout

| Path | What |
|---|---|
| `LowHangingFruitKit/Sources/LowHangingFruitKit/` | Pure model + parsing + persistence. No SwiftUI. |
| `LowHangingFruitKit/Sources/LowHangingFruitUI/` | Views and `AppState`. Imports the Kit. |
| `…/LowHangingFruitUI/Resources/` | Bundled media. Load via `bundledImage(_:ext:)` (`Bundle.module`) — a bare `Image("name")` resolves against the *main* bundle and silently renders nothing. |
| `App/` | iOS/macOS app target, entitlements, assets |
| `LHFWidget/` | Home/Lock Screen widget extension — a **separate process** |
| `backend/` | The Supabase project: SQL migrations, Edge Functions, `PROTOCOL.md` (the contract the app and server are both written against) |
| `backend/bench/extract-facts/` | The Phase 0 model bench for the composed-day plan (`ROADMAP.md` → Next): runner, scorer, phone converter, synthetic labelled corpus. `corpus/phone/` and `results/` are gitignored because they hold real course text. |
| `docs/` | Design docs and plain-language explainers |
| `ROADMAP.md` | The plan: release blockers, next features, parked experiments. Read with this file at the start of every session. |
| `smooth-prototype/` | Marco's dependency-free HTML/CSS/JS tester for the Smooth redesign. Isolated from the app; `python3 -m http.server 4173 --directory smooth-prototype`. |
| `chrome-extension/` | The Smooth Chrome extension (MV3, plain ES modules, no build step): a collector and encrypted sync helper for the phone. `docs/CHROME_EXTENSION.md` is its design record; `node --test chrome-extension/test` is its gate. |
| `project.yml` | xcodegen source of truth for the Xcode project |

## Architecture

### Three storage tiers — pick deliberately

Documented at length in `docs/persistence-explained.md`. The short version:

1. **SwiftData ledger** (`Persistence/StoredAssignment.swift`, `AssignmentStore.swift`)
   — the student's own record of work: assignments, completions, grade
   observations, manual work. Loss here is unrecoverable, so this tier never
   deletes.
2. **App Group `UserDefaults`** (`Persistence/SharedDefaults.swift`, reached as
   `UserDefaults.lhf`) — preferences: cheap to re-enter, meaningless off-device.
   Per-course settings live here in `CoursePreferences`.
3. **Keychain** (`SessionCookieStore.swift`) — session cookies and the Canvas feed
   URL (it embeds a per-user token, so it is a bearer credential). Device-bound
   via `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. **Never sync these.**

### The ledger is the point

The app used to hold assignments in memory and do `canvasItems = fetched` — a
wholesale replace — so a rolling Canvas feed or one flaky fetch erased work the
student had already seen and completed. `reconcile()` now *edits*: it upserts,
flags vanished items `isGoneFromFeed` rather than deleting, and refuses a
suspiciously empty fetch. Aging is deliberate (gone **and** 14 days overdue;
undated, still-in-feed, and finished items never age out).

When touching this, assume the invariant is "**nothing the student did is ever
lost**" and work backwards from there.

### Course identity

The Canvas course code (`"PHYS 151"`) is the key that selection, reminders,
grades, dedup and `CoursePreferences` all use. `CourseCode.parse` derives it from
Canvas's descriptor (`PSYC 1010-005 202430 Intro to Psych`). A failed parse falls
back to the raw descriptor, which is both an ugly label *and* a key nothing else
agrees with — so parsing bugs are identity bugs, not cosmetic ones. Renaming a
course is deliberately cosmetic only.

### Update gate

`LowHangingFruitKit/Sources/LowHangingFruitKit/Update/` (`AppVersion`,
`UpdatePolicy`, `UpdateManifestClient`, `UpdatePolicyCache`) and the
`LowHangingFruitUI` trio `UpdateGate.swift` / `UpdateRequiredView.swift` /
`UpdateAvailableBanner.swift` are a forced-update version gate: on launch and
foreground it fetches one small public static manifest and can show an
undismissable wall below `minimumVersion` or a dismissible banner below
`latestVersion`. The contract is **fail open** — any fetch failure, unset
manifest URL, or unparseable version leaves the last-known verdict untouched
rather than inventing a block, because a broken version check must never be
the thing that locks a student out of their own ledger.

**It is live.** The manifest is the `update-manifest` orphan branch of this
repo, served at
`raw.githubusercontent.com/OlisaNW247/penn-dashboard/update-manifest/lhf-update.json`.
An orphan branch because a shipped build has that URL compiled into it and can
never be told a new one, so the path must not move when feature branches merge;
and because GitHub's web UI can edit it from a phone, which is the only way to
lift a bad block.

`minimumVersion` and `latestVersion` are kept **equal** — every release is
mandatory, so `UpdateAvailableBanner` never fires in practice. **Since
2026-10-27 nobody bumps them by hand.** `.github/workflows/update-floor.yml`
(script and tests in `scripts/update-floor/`; `node --test
"scripts/update-floor/*.test.mjs"`) asks Apple's public lookup every 30 minutes
and raises both to the live version once it has been live six hours. It never
lowers the floor and writes nothing on an odd lookup. It only runs from the
default branch, `main`. To pause it (a new build crashes), set the repository
variable `UPDATE_FLOOR_HOLD` to `true`; set it **before** hand-lowering the
floor, or the next run raises it straight back. It was written because
students were still on builds below 3.2.0 after the floor was raised by hand
on 2026-10-25.

The manifest may also carry an optional `feedback` object (3.3.0+, the
dashboard's feedback card, What the app does). It is decoded with `try?` so
a bad one can never cost `minimumVersion`, and older builds ignore the key.

The rest of the lock, in builds after 3.2.1: below the floor `RootCore` renders
only the wall (not an overlay, so `ContentView`, its sheets and its sync loop
are gone), the store clears pending and delivered notifications, and writes
`lhf.updateRequired` so the widget shows "update smooth". Backend functions
refuse a present `X-Smooth-Version` below the floor with 426
(`backend/supabase/functions/_shared/version.ts`, fail open);
`LHF_REQUIRE_VERSION_HEADER=true` also refuses requests with no header, and
should be set only once the floor is at or above the first build that sends
it. `delete-account` is never gated, and functions the Chrome extension calls
never require the header. The macOS menu-bar extra (`LHFScenes`) is outside
`RootCore` and keeps syncing behind the wall: a known gap.

The floor must never be above what is actually downloadable. A floor above
what the App Store will serve is the one unrecoverable mistake here: the wall's
button leads to a version that still fails the check, and everyone is stuck. The
30-day ceiling in `UpdatePolicyCache` only rescues people who are offline.

Two things that surprise people. The gate cannot reach builds that shipped
without it — 1.2.1 and earlier never fetch the manifest, so no floor retires
them; only a future release can. And local builds are `3.0.0` (`project.yml`), above any floor
that is safe to publish, so the wall never appears in normal development: to see
it, build with `MARKETING_VERSION=1.0.0` (that is how the live path was verified
end to end) or pass `-LHFForceUpdateWall`.

### ask: the model, the hedge, and the loop that tunes them

`backend/supabase/functions/ask/index.ts` streams the answer. Primary
model `openai/gpt-4.1-mini` (`LHF_MODEL`), no reasoning field; if it has
produced no content delta by 5 s, `z-ai/glm-5.3-flash` at
`reasoning.effort: low` (`LHF_ASK_FALLBACK_MODEL`) starts alongside and
whichever streams first wins, the other aborted; a primary that fails
or ends empty before any content hands over outright; once content has
flowed nothing switches. Olisa's rule: never more than a ten-second
wait. Every request writes one row to `ask_outcomes` -- outcome, tokens
including reasoning, chars, deltas, first-delta and total latency,
pre-race and race time, the model that answered and why (`detail`), and
a `probe` tag for synthetic traffic -- never the question or answer.
The pre-race reads (auth, quota, enrolment, profiles, catalog) are
timed (`ask: timing {...}` in the function log), overlapped, and capped:
quota fails open at 1.5 s, auth at 3 s.

`ask-canary` serves the same `handleAsk` with probe overrides on
(`probe: { model, maxTokens, reasoning, provider, contextTrimChars,
fallbackModel, disableFallback, hedgeAfterMs }`), so a candidate change
is measured before it touches `ask`. The loop runs from any Node 22
shell with the Management API token: `node
backend/scripts/deploy-function.mjs ask-canary --also ask` deploys,
`node backend/scripts/ask-probe.mjs --slug ask-canary --runs 20 --set
mixed --tag <tag>` fires 14k-token syllabus prompts and exits non-zero
on any empty or errored run, and a `select ... from ask_outcomes where
probe = '<tag>'` through `POST /v1/projects/<ref>/database/query` reads
the result. Deploying `ask` itself is a production change and needs a
person's go. The 2026-09-22 promotion was 55/55 on the canary (first
word median 1.8 s, p95 3.9 s, max 6.5 s) and 5/5 on production.
Since 2026-11-05 the probe also has two sets from the 2026-11-02
recording, `history` (the wrong schedule answer as an earlier turn, then
"you should've said that in my original question") and `meeting` ("Do I
not have cis 2620 class today?" against an Ed post saying no lectures),
each graded by regex and counted at the end, and `--history-file <path>`
(a JSON array of `{role, content}`) sends any pair as `history` with any
set; `--model` compares candidates on them. **Run on 2026-11-05 from a
GitHub runner** (`.github/workflows/ask-probe.yml`, `workflow_dispatch`,
registered on `main`, dispatched with `ref: v10`; the repository secret
`LHF_PROBE_SECRET` holds the header value): `meeting` 10/10 answered from
the Ed post, 0/10 from the schedule, first word p50 1.9 s; `history` 10/10
answered, 0/10 confused, and every reply corrected the earlier turn ("No,
CIS 2620 does not have lectures this week, including today… from the
latest course staff post on Nov 1"), which the bare question ("you
should've said that in my original question") names neither course nor
day for, so `history` reaches the server and the model reads it; none
apologised, so the `acknowledged` regex read 0/10 and should be widened or
read as "corrected". `cachedTokens` 14,848 of 14,974 on every run after
the first: the byte-stable prefix holds. The runner exists because a
cloud session cannot run the probe at all (Traps, the network-secret
entry). Candidate models need `LHF_PROBE_MODELS` set on the project
(`_shared/probe.ts`, `probePolicyFromEnv`), which Olisa set to
`anthropic/claude-haiku-5.5` the same day.
**Haiku 5.5 on the canary, 2026-11-05** (the owner's plan: the tree on
Claude Haiku, billed to his Anthropic credit; `gpt-4.1-mini` is retired by
OpenAI on 2027-01-14). Ten runs per set with `probe.model`: `meeting` 10/10
from the post, `history` 10/10 with the correction acknowledged every time
(gpt-4.1-mini: corrected but never acknowledged), `citations` identical
counts to gpt-4.1-mini (sources 10/10, title 10/10, Meyerson 3/3), `mixed`
10/10; answers two to four times longer, and better: one flagged three
conflicting late-policy copies in the pool, one noted the asked-about
midterm had passed. The catch is latency: first word mean 3.7 to 5.1 s and
max 9.8 s against 1.4 to 1.9 s today, with 600 to 1,000 completion tokens
(hidden reasoning) and **zero cached tokens on 23,000-token prompts**
(gpt-4.1-mini caches 14,800 of 15,000). `probe.reasoning {effort: low}`
plus `hedgeAfterMs 30000` changed little (first word 3.6 to 4.7 s mean,
7.1 s max; about 530 completion tokens), so the time is the provider
reading an uncached prompt, not thinking. Three server changes follow
(not deployed): Anthropic `cache_control` on the stable prefix for
`anthropic/` models, `{effort: low}` by default for them with an
`LHF_ASK_REASONING` override, and `LHF_HEDGE_AFTER_MS` for the 5-second
hedge, which would otherwise fire on most Haiku requests. The decision
waits on a canary run with caching live; billing the owner's Anthropic
credit is an OpenRouter bring-your-own-key setting, not code.

**2026-11-05: the code half of moving the primary to
`anthropic/claude-haiku-5.5` (written, tests green, NOT deployed; the model
switch itself, `LHF_MODEL`, is a person's call).** The canary showed three
things and each has a change: (1) Haiku cached 0 of ~23,000 prompt tokens
because Anthropic caches only where asked, so for an `anthropic/*` model
`withCacheBreakpoint` (`_shared/prompt.ts`) puts one `cache_control:
{ type: "ephemeral" }` on the last `system` message (COURSE PROFILES), the
end of the stable prefix; history, the date line, excerpts and the question
follow it, and any other model's body is byte-identical to before (pinned
by a golden in `test/ask_model_tuning.test.ts`). (2) `reasoningFor` now
gives `anthropic/` models `{ effort: "low" }` like `z-ai/`; `LHF_ASK_REASONING`
(a JSON object, malformed ignored with one warning) overrides the primary's
shape for any model, and `probe.reasoning` still beats both. (3)
`LHF_HEDGE_AFTER_MS` (an integer 1,000 to 30,000, else 5,000) replaces the
fixed hedge delay, because Haiku's first word takes 3 to 6 s and the owner's
rule is ten seconds, not five; `probe.hedgeAfterMs` still wins. Nothing the
phone sends changed. After deploying, read `usage.cachedTokens` on a canary
run: it should be well above zero from the second request on.

**2026-11-02: the citation contract and the recording fixes went live,
at Olisa's go.** `ask-canary` v8 (deployed with `--also ask` from `v8`
`dfb9d7f`, so it serves the new `prompt.ts`) answered the 20-run
`citations` probe (tag `cite-def`) 20/20, first word p50 3.3 s, p95
6.1 s; `<sources>` block 20/20, a known title in the detail 20/20 (the
2026-10-25 baseline against the old prompt: 3/6), kind `ed` 15/20, and
7/7 midterm answers named Meyerson, the newer post's room (baseline 2/2;
all 7 also mention Towne, the room it replaced). Production `ask` then
went to **v13** from the same tree. The canary is gated on the
`LHF_PROBE_SECRET` function secret, which the project did not have until
that day (every probe was a 404); Olisa holds the value, and the probe
shell must export the same one. It is never written into the repo.

### ask: retrieval is on the phone

The server does no searching. `ask` answers from the context document
and whatever passages the phone sends in `excerpts`, and the context
document tells the model to say it isn't in the app's records unless an
excerpt states the answer. So a passage the phone's search misses is an
answer nobody can give, and "ask can't find it" is nearly always a
client problem. The pieces, all exercised by tests:

- **Search** (`CourseSearch`, `BM25Index`, `QueryExpansion`,
  `CourseMatcher`). BM25 over 160-220 word passages, titles indexed,
  lone digits kept ("exam 2"), singular and plural on one stem, a small
  query-only synonym table, the course scope and kind boosts applied
  *before* the cut, and one unscoped retry when a scoped search finds
  nothing. The index is rebuilt in memory at launch; nothing to migrate.
- **What is sent** (`BackendAssistantResponder.retrievedExcerpts`). Up to
  eight passages of 1,500 characters, three per document, cut at a word
  boundary; Ed posts and announcements carry "posted Oct 3"; image-only
  Ed posts are skipped. It was four passages cut at 700 until
  2026-10-10, which dropped the tail of nearly every passage. Since
  2026-10-25 (blind, `docs/TREE_IMPROVEMENT_PLAN.md` items 1 and 3) the
  block always opens with one line giving the student's local date, time
  and zone ("The student's local date and time: Friday, October 23, 2026,
  9:15 PM (America/New_York, UTC-04:00). …"), built from `askedAt` and
  never the clock, so it is never empty any more; a passage keeps its line
  breaks (continuation lines indented two spaces) instead of being
  flattened to one line; and `HTMLText` separates table cells with " | ",
  so a grading table reaches the model as a table. In the same change
  the context document renders due times in the student's zone
  (`2026-09-04T23:59:00-04:00`, `AssistantContextDocument.build(…,
  timeZone:)`, `AssistantContext.timeZone`, `.current` at the UI layer
  only), which `docs/PRIVACY.md` now discloses.
- **"What's new" questions** (`RecencyIntent`, 2026-10-20, compiled green, not yet on a phone). BM25
  has no idea what "recent" means: asked "what have been the recent staff
  posts on Ed for my cis 2620 class", the phone sent the posts whose text
  said "staff" (Aug 28 to Oct 7) and left out the two newest (Oct 12 and
  Oct 18), so the model reported nothing newer than Oct 7 and, asked
  about "the past week", still named Oct 7. Now a question with a recency
  word (recent, latest, newest, lately, what's new, any news) or a time
  phrase beside a posting noun (today, yesterday, this/past/last week,
  past N days, this month, with post/announcement/update/news/said/staff/
  ed/discussion/message/board) makes `excerptBlock` put the newest dated
  Ed posts and announcements in scope first, newest first, inside the
  window when one was named (the three newest regardless when the window
  is empty, so the model can say when the last post was), and BM25 hits
  fill the rest. Detected on the follow-up-merged query, so "what about
  in the past week" after that question is a 7-day window. A question
  with neither leaves the block byte-identical. The wrong fix is a
  recency boost in BM25 itself, which would push a week-old post above
  the syllabus for "what is the late policy". Since 2026-11-05 the
  keyword reading is the first classifier inside `AskTimeFrame` (below);
  `RecencyIntent` is unchanged and its callers get the same answer.
- **Follow-ups** (`FollowUpRetrieval`). A question that names no course
  searches within the course the nearest earlier question named (up to
  four back), and a question of six words or fewer is searched with the
  one before it. Since 2026-11-02 (blind, the owner's "improve this
  immediately" on a recording where the tree said "I don't have the
  original question you asked") `history` carries the conversation's last
  three exchanges, capped at 6,000 characters (`ConversationHistory`,
  `AssistantContext.history`), after the cache breakpoint; `question` is
  still exactly what was typed. The policy sentence changed in the same
  commit. The same recording showed "do I not have CIS 2620 class today?"
  answered from the weekly schedule while an Ed post from the day before
  said "no lectures this week": BM25 shares no word with that post, so
  `RecencyIntent` now has a `.meeting` kind (class, lecture, lab, office
  hours beside cancelled, "do I have", today, tomorrow, this week…) that
  puts the class's newest posts from the last 14 days first, at most four,
  under a note telling the model a post overrides the schedule and that
  "no post mentions a change" is the honest form of "nothing announced".
  Both compiled green on the GitHub runner the same day (3414/329, Test
  baseline). **On a phone 2026-11-02** (Marco's iPhone 17 Pro, the `v8`
  Debug build at `d434db8`, production `ask` v13): "Do I not have cis
  2620 class today?" came back "you do have quiz", the content of the
  2026-11-01 Ed post ("No lectures this week but quiz on Monday"; the
  2nd was a Monday), where the recording had answered from the weekly
  schedule. So the `.meeting` kind sent the post. Whether the answer
  carried the post's chip is not reported. The follow-up ("you should've
  said that in my original question") was **not asked**: an earlier
  version of this line said it was and had failed, a misreading of
  Marco's chat message, corrected the same hour. `history` on a phone is
  still unproven. Marco's wider verdict the same day: the model still
  reasons poorly about *when*; a question about today or this week should
  put recent posts first, a general question should lean on the syllabus
  (`docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`).
- **The time frame of a question** (`AskTimeFrame`, 2026-11-05, blind, not
  compiled; steps 1 and 2 of `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`
  Part 3). `LowHangingFruitKit/Assistant/AskTimeFrame.swift` classifies a
  question, on the follow-up-merged query like `RecencyIntent`, into
  `classMeeting(range?)`, `dueOn(range)`, `recentNews(windowDays)`,
  `policy` or `specific`, and resolves "today / tonight / tomorrow /
  yesterday / this week (to Sunday) / next week (Monday to Sunday) / this
  weekend / a weekday / past N days" to whole local days in the student's
  zone (`context.timeZone`), never UTC: a start `Date`, an exclusive end
  and the `yyyy-MM-dd` first and last day. `RecencyIntent`'s word lists
  are consulted first and unchanged (`recencyIntent` maps back), so the
  news and meeting picks fire exactly as before. `dueOn` is classified and
  deliberately not acted on: its excerpts are byte-for-byte a plain
  search's (a test pins it); it is there for the later step that filters
  the work list by day. `CourseSearch.search` takes `intent:` and `now:`
  (both defaulted, so every other caller scores as before): for
  `classMeeting` and `recentNews` an Ed post or announcement's score is
  multiplied by `0.5 + 0.5 * 0.5^(ageDays / 4)` on `shownPostedAt` (a
  floor of one half so a lone old match still reaches the model); for
  `policy` and `specific` there is no decay and a syllabus passage with a
  policy word is boosted 1.5 instead of 1.35. The decay is per intent on
  purpose: a global recency boost would put a week-old post above the
  syllabus for "what is the late policy" (`AskTimeFrameRegressionTests`
  pins that a policy ranking does not depend on post dates). Steps 3 to 6
  (per-intent slot budgets, a computed schedule line, dated labels, the
  server prompt) wait on the decision of how the weekly schedule reaches
  the phone. Nothing leaves the phone differently: only the choice and
  order of passages changes. The Mac has not compiled any of it.
- **What the phone holds** is the limit. Canvas Files (slides, readings,
  any PDF not named "syllabus") are not ingested by the phone, only the 40
  newest pages get their bodies, and announcements reach the pool only
  since 2026-10-23 (Known gaps). The extension fills some of that in
  (`file` documents, every page) for a student who pairs a laptop. On
  2026-10-24 the pool held a real syllabus for 28 of 63 courses, a stub
  for 18 and none for 17: half the classes have no policy text to
  retrieve, which `docs/TREE_IMPROVEMENT_PLAN.md` ranks as the
  first-order problem. The collection code is the course-material sync,
  which Marco has said not to touch (`parked/ask-course-sync-fixes`).
- **Where and when each section meets** is the one thing the server adds
  on its own (2026-10-20; deployed the same day at Olisa's word, `sync`
  version 9 and `ask` version 10, about 13:40 UTC; the catalog rows
  refetch with rooms on each install's next manifest call). `sync` already fetched each enrolled course's registrar
  sections from Penn Labs' public Penn Courses API (the public mirror of
  Path@Penn) into `catalog_courses.components`; it now keeps each
  meeting's `room` and each section's `instructorsBySection`, and `ask`'s
  COURSE STRUCTURE block renders a "Sections:" sentence per course: every
  section's days, times, room and instructors, the student's own section
  marked "(the student's section)" (from `courses.section`, the number in
  the site label), at most 8 sections per component with the student's
  always included. A stored row written before this has no `room` key on
  its meetings, which `dbRowToCatalogRow` detects by key presence (a
  present `room: null` is a real online section) and `catalogNeedsFetch`
  refetches on the next manifest, so every enrolled course re-reads
  within about an hour of the deploy. The same afternoon the fetch was
  changed to name the semester (`academicSemester`, `396e464`, 14:29 UTC;
  Traps: Penn Labs' `current` had rolled to Spring 2027) so a row from
  another semester is refetched and never served. That commit was not
  deployed until 2026-10-22 (`sync` v9 and `ask` v10 were from 13:35
  UTC on the 20th, an hour before it, and every row refetched at 14:21
  UTC that day was `2027A`), which is why on the morning of 2026-10-22
  the tree gave CIS 2400's lecture as 12:00 to 1:29 in NBS AUD, Spring
  2027's slot, when the fall section meets 1:45 to 3:14 in AGH 106B
  (Penn Labs' `2026C` entry, read from Olisa's Mac). **Deployed with
  Olisa's go at about 14:55 UTC on 2026-10-22 as `sync` v10 and `ask`
  v11**; the rows flip to `2026C` on each install's next manifest call. The system instructions say the
  block never holds an exam room: those come from announcements and Ed
  posts, which the phone's search has to find. Nothing new leaves the
  phone; the section number was already sent.

### Facts and structured sources (2026-11-04, `v10`; backend live 2026-11-05, redeployed 2026-11-06 as `sync` v22 / `extract-facts` v6 with `finish_fact_extraction` applied)

The composed-day plan (`docs/DAY_PLANNER_RESEARCH_2026-11-03.md`; the
decisions behind it are in `docs/HANDOFF_V10_2026-11-04.md`) has two halves,
each behind its own compile-time kill switch in `FeatureFlags.swift`, both
`true`:

- **`structuredCanvasSources`, phone only, no model, any school.**
  `CanvasStructuredSourcesClient` reads Planner items, missing submissions
  and, per course, modules at item grain, assignments with `all_dates`,
  discussion topics and dated pages with the student's own session;
  `CanvasStructuredSourcesReconciler` turns that into plain
  `CanvasStructuredSignals` (completions, dismissals, section dates, rows);
  `AppState+StructuredSources.swift` is the only applier. Rows are upserted,
  never reconciled. Completions are an additive set; dismissals are replaced
  by each run whose planner endpoint finished in full (so un-dismissing in
  Canvas restores the card) and only added to otherwise; section dates are a
  map in `UserDefaults.lhf` (`structuredCompletedItemIDsV1`,
  `structuredDismissedItemIDsV1`, `structuredDueOverridesV1`), consulted when
  the dashboard pool is built and never written as the student's own edits.
  `WorkItemIdentity` / `WorkItemAlias` / `WorkItemMatcher` /
  `WorkItemMergeRecord` are the identity layer (research Addendum C, item 1):
  one work item known by several aliases (feed uid, Canvas assignment id,
  module item id, Gradescope id), matched by id first and by title and date
  proximity second.
- **`appliedFacts`, needs the backend.** The manifest request carries
  `factsSince` (`factsCursorV1`); the answer's `facts` go into
  `AppliedFactStore`, and every dashboard rebuild runs `FactApplication`
  (`Facts/FactApplication.swift`, pure: no store, no clock) over them.
  `AppState+AppliedFacts.swift` writes the result back. Server side:
  `extract-facts` and `_shared/factsExtraction.ts` (prompt, schema and checks
  are Phase 0's `_shared/facts.ts`), the `course_facts` migration, and
  `backend/PROTOCOL.md` → "Facts and `extract-facts`".

**Two stores, on purpose.** The facts live in `AppliedFacts.store`, a
SwiftData file of their own (`AppliedFactStore`, the `GradeHistoryStore`
pattern), never in the ledger's schema. The structured sets live in defaults.
Neither touches `Assignments.store`.

**Precedence, in the order `FactApplication` applies it:**

1. A fact the student rejected (`undo`) is dropped first, before supersession,
   so it neither applies nor suppresses an older fact.
2. The student's own action outranks a fact (a completion, a hand-edited
   date); only an explicit `confirmed` lifts that.
3. Canvas outranks prose where they already agree (the source already moved
   the date or dropped the item): the fact is `redundant`, not applied.
4. The newest fact per (target, type) wins, computed over everything still
   live, not only over what would otherwise apply.
5. A target resolves only among rows of the fact's own course; an unresolved
   or ambiguous pointer, an extractor `needs_review`, a medium-confidence
   `cancel` and a detail-less reschedule go to `needs a look` and are never
   applied. The output type cannot say "complete" or "delete": the strongest
   effect is hide from todo and tag.

Reschedules are substituted into the dashboard pool's copy of the row, never
written onto the ledger row (the feed rewrites `dueAt` every sync). Only a
new task is written to the ledger: a `.canvasAnnouncement` row with a
`fact-<documentID>-<seq>` sourceID.

Since 2026-11-05 (blind, not compiled) the tree's work list reflects the
same results: `AppState.applyingTreeOverrides` gives the context document
and the on-device pool the section date and an applied reschedule's date
(read from `factDisplay.movedTo`, no second evaluation), and a cancelled
item stays in the document with the status `cancelled` (a fourth word beside
done / nothing to submit / outstanding). The student's own date edit is
still withheld from the document (PRIVACY.md) and carried by the on-device
pool as before. Canvas dismissals are not applied to the tree's list.

### Stay signed in (Penn only)

Canvas signs students out from time to time, and reconnecting means PennKey
(and often Duo) again. Stay signed in removes that: the app saves the
student's PennKey username and password and re-fills Penn's login form
itself.

- **How it turns on (since 2026-10-23; the owner's call, never compiled,
  never run on a device).** There is no toggle and no second password
  prompt. At Penn, the visible Canvas login shows a one-line disclosure
  above Penn's page ("Signing in securely saves your PennKey on this device
  so Smooth can reconnect. Disconnect at any time in Settings."), and
  `PennKeyLoginCapture` watches that page for one submission of Penn's
  own login form: main frame only, `https` on `weblogin.pennkey.upenn.edu`
  or `idp.pennkey.upenn.edu`, under `/idp/`, with the form's action
  checked the same way. It observes and never alters the submit or the SAML
  hop. The submitted pair is held in memory only, in the pane's own
  capture object, **for at most 10 minutes**, and is dropped on a failed or
  cancelled navigation, a form error, the pane going away, or the timer.
  It is saved to the Keychain **only after `connectCanvas` has verified the
  session** (`enableStayLoggedIn`, which now returns whether the Keychain
  write succeeded and never switches the feature on when it did not). A
  login whose submission the page never reported (SSO) simply leaves
  nothing to save, and the confirmation page says Canvas is connected on
  the current session and that automatic reconnection needs a PennKey
  password sign-in. The
  vault (`PennKeyCredentialsSheet`, titled "the vault" since 2026-10-18)
  remains, but only as a repair tool behind "update password" after Penn
  rejects a saved password; it is not an offer after a login any more. Penn
  only: other schools get no capture, and `OnboardingView` builds the
  capture only for `CanvasInstallation.penn`. The legacy "offered" flag
  (`hasOfferedStayLoggedIn`) is no longer written, and
  `AppState.noteStayLoggedInOffered` has no production caller; the flag is
  kept because the login-is-missing inference at `init` still reads it.
  Before 2026-10-23 this was an opt-in sheet, shown after every
  interactive Penn login while no password was saved, with "not now" always
  available and nothing stored unless the student typed both fields and
  tapped save (the 2026-09-24 removal of the toggle, and the vault look of
  2026-10-18, belong to that design). The owner reversed it to remove the
  retyping and the consent tap, and the privacy promise that came with
  them; the trade-off is recorded in `docs/PRIVACY.md` ("Automatic Canvas
  reconnection"), `docs/appstore/REVIEW_NOTES.md` and the Traps entry about
  access tokens.
- **Where it lives.** `PennKeyLoginForm` (Kit, pure) recognizes the
  identity provider's form and knows how to fill it.
  `PennKeyCredentialStore` keeps the credentials in the Keychain,
  this-device-only, never synced; its `save` updates the existing item in
  place and falls back to adding one only when none exists, so a refused
  write keeps the previous credential instead of deleting it first.
  `PennKeyLoginCapture` (above) is the only reader of what the student
  typed, and it never goes beyond memory until a connect is verified.
- **How it's used.** When the visible reconnect pane or the background
  `CanvasSessionRenewer` hits an expired session, the fill happens through
  one seam. `LoginNavigationObserver` auto-fills and submits the IdP form
  in the visible pane. The renewer does the equivalent with one JavaScript
  submission of that same IdP credential form per attempt, never more than
  one. It never resubmits the SAML response form the browser posts back to
  Canvas afterward: that form is exactly what the login WebView's
  universal-link guard already has to rebuild by hand (see the Canvas
  Student trap below), and resubmitting it would double-POST it.
- **Failure handling.** One rejected password disables auto-login outright
  rather than retrying, so a typo or a changed password can't lock the
  PennKey account; Profile → accounts then shows "update password".
- **Duo: the credential never reaches it; the app taps its buttons.**
  The stored credential only ever reaches the IdP's password field, never a
  Duo prompt. Since 2026-11-02, in a FOREGROUND attempt only, the hidden
  renewer injects `DuoPromptAutoTap` on `duosecurity.com` hosts: it taps
  "Yes, this is my device" / "Trust browser" (Duo's 30-day trust re-issue)
  and "Send me a push" (also through "Other options"), once per page load,
  and reports only the words `push` / `trusted`. It never reads or writes
  an input and never touches a passcode field. After a push the attempt
  waits up to 120 s, the status line says "approve the duo push on this
  phone", and approving it in Duo Mobile is the student's one tap. A push
  that nobody approves ends `.needsDuo` (latches `autoLoginAwaitingDuo`,
  the "duo needs you" line). A background attempt never taps push
  (`backgroundDuoStandDown` and `backgroundMayUseCredentials` unchanged).
  `-LHFForgetDuoTrust` (DEBUG) deletes Duo's cookies and the live Canvas
  session cookies from the hidden login store (the Keychain copy stays) and
  skips the session probes for that launch. Combined with
  `-LHFAgeCanvasSession`, the launch therefore performs a full PennKey +
  Duo re-login whose push the owner must approve.
- **When it runs (2026-11-02 spacing and keepalive).** Foreground
  attempts are spaced 90 s apart (`CanvasSessionRenewer.foregroundSpacing`);
  the one-hour `cooldown` gates the background slot only, which is what
  stops a background attempt from refusing the student's own open (the
  2026-11-01 banner). Every expired state retries on each foreground
  refresh (`shouldRetrySilentRenewal(expired:...)`; the old requirement for
  a latched verdict and the 10-minute post-timeout interval are gone). The
  foreground cap is 60 s (120 s once a push is sent; background stays 20 s)
  and the saved password may be resubmitted after 10 minutes in the
  foreground (`foregroundCredentialSpacing`) instead of six hours (the
  background keeps six). Keepalive: a foreground recompute probes
  (`shouldKeepAliveProbe`) when the newest Canvas session cookie was
  captured 12+ hours ago, and a background wake makes the same one GET at
  6+ hours, awaited before its fetches; an `.alive` answer re-stamps the
  cookies, which resets Canvas's one-day window, and a `.dead` answer from
  a wake starts no renewal. Push-spam guards: a latched Duo wait
  (`autoLoginAwaitingDuo`, dated by `autoLoginAwaitingDuoSinceV1`) no longer
  ends silent recovery for good; the foreground may try again once per cold
  open or once the latch is over 60 minutes old
  (`awaitingDuoRetryAllowed`), the background never. After a foreground
  attempt that submitted the password and did not end `.renewed`, the next
  foreground submission waits 60 minutes
  (`CanvasSessionRenewer.failedSubmissionSpacing`, persisted as
  `lastFailedCredentialSubmissionAtV1`), and the once-per-open try does not
  override it. A foreground `.renewed` or an alive probe clears the Duo
  latch, and "duo needs you" shows only over a session believed expired.
  Reaching a Duo host after submitting counts as a push sent (Duo often
  pushes by itself): the cap goes to 120 s at once, and the status line
  follows after 4 s so a remembered device never flashes it. The 24-hour rule itself (`load`, `isStale`,
  `isExpired`, `gatedOnLiveSession`) is untouched.
- **Duo SMS passcodes can autofill from Messages.** Since 2026-10-30 the
  login WebView injects `DuoPasscodeAutofill` (a `WKUserScript`, page
  world, all frames) that, on `duosecurity.com` hosts only, marks passcode
  inputs `autocomplete="one-time-code"` and `inputmode="numeric"`, so iOS
  offers the texted code above the keyboard. It sets attributes only,
  never reads a value; the code goes from Messages to Duo's page through
  iOS's own autofill. Unverified on a device (Known gaps).
- **When it runs.** Whenever the saved Canvas cookie is more than 24 hours
  past its last save (`SessionCookieStore.load`), on launch or on returning
  to the foreground, on a Grade Watcher 401, and, since `v8` (2026-10-09,
  blind), on each foreground refresh while the session is expired and
  `AppState.shouldRetrySilentRenewal` says the cooldown has passed, and on
  background wakes now that the crash below is fixed. **The 24-hour half of
  that is switched off on any phone whose saved cookie set holds a cookie
  with a real expiry date** (found on Marco's phone 2026-10-08; still
  unfixed on `v8` at 2026-10-23, `load` and `isExpired` being unchanged;
  see the analytics-cookie trap), where only a Grade Watcher 401 or the
  foreground retry on an expired session starts a renewal. A background
  renewal runs in `RenewalContext.background` with a 20 s budget and can
  only ever *help*: `.renewed` saves cookies, `.passwordRejected` still
  disables auto-login, and every other outcome changes nothing, so a
  hidden WebView stalled on Duo in the background cannot latch the
  session dead. In the foreground `.timedOut` never latches, a
  `.landedOnLoginPage` latches only on the second consecutive landing,
  and `.needsDuo` still latches, because a retry would push a Duo
  notification to the student's phone and only an interactive login can
  grant trust. Every outcome is written to `lastSilentRenewalSummaryV1`
  (outcome, time, context; never a URL or credential) and shown in
  Profile → accounts in plain words, with whether a password is saved
  (and whether Penn rejected it or Duo is waiting) and whether a live
  Duo cookie exists ("duo remembers this phone"; never a date, because
  the cookie seen on a device lives 399 days while Penn's remember window
  is about 30).
  The second blind round (2026-10-09, after a three-slice review of the
  first): every production trigger goes through
  `AppState.startSilentCanvasRenewal()`, which stores the task so the
  background wake can `awaitPendingSilentRenewal()` before telling iOS it
  is done, and `BGTask.expirationHandler` → `abortSilentRenewal()` tears
  the WebView down; the dashboard hides the reconnect banner while
  `isSilentRenewalInFlight`; a `.failed` navigation (offline, captive
  portal) is `.timedOut`, never a login landing
  (`CanvasSessionRenewer.failedNavigationOutcome`); the background's
  "Duo has asked" stand-down is its own persisted flag
  (`backgroundDuoStandDownV1`, lifted only by `.renewed`, an interactive
  login or a newly saved password); the renewer's hour cooldown is seeded
  from `lastSilentRenewalAttemptAtV1` (so `-LHFAgeCanvasSession` now also
  clears that key); and a token mint or Grade Watcher success resets the
  landing streak (`noteCanvasSessionProvenAlive`). The runbook for the
  device check is `docs/SIGNOUT_VERIFICATION.md`.
  Every successful pass through Duo re-issues Duo's 30-day
  `browsertrust` cookie, so a student who opens the app at least monthly
  should never see Duo again. Since `v8` the Canvas login pane's pre-login
  purge keeps that cookie (`CanvasInstallation.preLoginPurgeDomainHints`);
  before, every manual reconnect deleted it, which is the most likely
  reason students with a saved password still saw Duo and the banner
  (`docs/SIGNOUT_INVESTIGATION.md`). Disconnecting still purges Duo.
- **Removal.** Disconnecting Canvas deletes the saved password, and with it
  any captured pair still in memory (the pane's `onDisappear` finishes the
  capture).
- **Verified on a device, 2026-09-27, in the foreground.** On Marco's
  phone, with a real PennKey and Duo, `-LHFAgeCanvasSession` renewed in 8
  seconds, hands-free, and Duo re-issued its trust. Olisa's phone renewed
  the same way on its own that afternoon. A renewal during a *background*
  wake has never happened on any phone, because background wakes crash
  first.
- **Verified again on 2026-11-02 on `v9`, through Duo.** With the hidden
  store emptied of Duo trust and Canvas session (`-LHFForgetDuoTrust`),
  the renewer filled the password at +4 s, reached Duo at +9 s, was back
  on Penn at +13 s and on Canvas at +27 s; `canvasSessionConfirmedDeadV1`
  and the awaiting-Duo latch both read false afterwards. Two earlier runs
  that day failed for reasons outside the code: a stale build from another
  worktree was on the phone, and its own password submission four minutes
  earlier put v9's run inside the 10-minute credential spacing, so v9
  refused to type the password and parked on the form for 60 s. Always
  wait ten minutes between hidden-login tests.

## Traps that have already bitten

- **A switch-off that races a network call in flight** (found 2026-11-11 by
  the v11 test pass, read from the code, never seen on a phone). Turning
  the agent connection off (or disconnecting Canvas) sends `delete` while a
  snapshot `put` may still be in flight; a put replaces the server's row
  whole, so if it lands second the work list is back on the server after
  the student was told it was deleted (the agents are revoked either way).
  Likewise the drafts pass re-checked the opt-in only after `listDrafts`,
  then awaited the outcome reports and applied the list, which could put
  back drafts, the cache and notices the opt-out had just cleared. Now the
  snapshot pass deletes again when it finds the opt-in off after its put,
  and the drafts pass checks again right before applying. Both passes'
  gates are one pure rule, `AgentPassRules.shouldStart`, pinned with a fixed
  clock. The wrong fix is making the switch wait for the pass: it must
  answer at once.

- **Field-by-field leniency is undone one level up by a plain array**
  (found 2026-11-11 by the v11 test pass, `docs/V11_TEST_PHONE_2026-11-11.md`).
  `AgentDraft` decodes every optional field with `try?`, but the drafts
  list decoded as `[AgentDraft]`, so one element with no `id` (or an id that
  is a number, or a value that is not an object) threw for the whole array,
  the pass's `try?` turned that into "no drafts", and the outcome reports
  the pass re-sends were skipped too. Nothing on the phone said why. Now
  `AgentDraftList` decodes element by element. The wrong fix is making `id`
  optional: a draft with no id cannot be matched to an attempt record.

- **A view's `.task` cancelling the course-material sync read as "manifest
  failed"** (2026-11-10, diagnosed by the backend session, blind fix). The
  server logged Marco's manifest calls as 200 in 4.4 s; the phone recorded
  "manifest failed · partial 5 · pages 5". The chain runs from
  `ContentView`'s `.task`, SwiftUI cancels that task when the scene changes,
  and a cancelled task cancels the URLSession requests it awaits, which
  `BackendClient.send` maps to `.transport`. `refreshCourseKnowledge` now
  runs the work in one task held in `AppState.pendingCourseKnowledgeSync`
  that later callers join (the `startSilentCanvasRenewal` pattern), and the
  summary says `manifest failed (cancelled | transport | http N | decoding
  (<path>))`. The wrong fix is a retry inside the same cancelled task.
  **Proven on Marco's phone on 2026-11-10 at 13:15 US Eastern**, the first
  open of the merged build: `manifest ok · uploaded 45` after days of
  `manifest failed`, and the assignment-PDF pass then ran for the first
  time: `planned 9 · fetched 9 · pooled 8 · skipped 1` (PHYS 0151: Problem
  Set 7, HW6 and HW7 with their numerical solutions, two tables, two
  worksheets); `get_assignment` for Problem Set 7 returned the full problem
  text through the agent connection a minute later.
- **"manifest failed" on the phone can be a 200 on the server, and the
  Management API's logs moved** (2026-11-10). Marco's summary said the
  manifest failed for days, which reads as a `sync` bug. The function log
  said 200 both times, and the same request replayed by a throwaway user
  decoded cleanly, so the phone gave up on its own (most likely a cancelled
  task; `docs/MANIFEST_FAILURE_2026-11-10.md`). The wrong fix is changing
  `sync`, or retrying the manifest (a cancelled task cancels the retry). To
  read the logs: `GET /v1/projects/<ref>/analytics/endpoints/logs` with
  `select … from logs where source = 'function_edge_logs'` (or
  `'function_logs'`), fields through `log_attributes['response.status_code']`
  and the like, never `select *`, with `iso_timestamp_start` and `_end`.
  `from function_edge_logs` answers "Table does not exist", which cost three
  queries. `response.headers.content_length` is the compressed size.
- **A deleted draft file still downloads through a signed URL handed out
  earlier** (2026-11-10, found by `agent-e2e.mjs`). After a draft moved to
  submitted, its object was gone from `storage.objects` and `file_path` was
  cleared, yet the same signed URL (even with an extra query parameter)
  answered 200 for 20 s more, and 400 only after its 120-second life ended.
  The deletion is right; Storage's edge serves an issued URL until it
  expires. The wrong fixes are "the remove failed, retry it" (it did not
  fail) and asserting the URL dies at once in a probe. The real bound is the
  URL's life, which is why it is 120 seconds and why PROTOCOL.md says so.

- **Supabase's runtime strips `/functions/v1` from the path it hands a
  function, so a root derived from the request path is wrong for every
  browser** (2026-11-09, the first claude.ai sign-in). `agent-auth` built
  its nonce cookie's `Path` and the authorize page's status URL from
  `url.pathname` up to `agent-auth`, which inside the runtime is
  `/agent-auth`, while the browser sat at
  `<front>/functions/v1/agent-auth/authorize`. The page polled
  `/agent-auth/status` on the front (a 404 there) with a cookie scoped to
  a path it never visited; Marco approved twice on his phone (two
  `approved` rows, `auth_code_hash` null) and the page never moved. The
  dev tunnel and the handler tests both used the full public path and hid
  it. Fixed by deriving the root from `LHF_AGENT_PUBLIC_BASE`'s path, which
  is what every caller sees; deployed alone as `agent-auth` v3 from a
  scratch worktree at the deployed commit, so the undeployed hardening did
  not ride along. The wrong fix is a path rewrite in the front: a direct
  caller of `supabase.co` would still get the stripped root. The tell: an
  approval that lands in the table while `status?go=1` never does.
- **Supabase's gateway serves an Edge Function's HTML as `text/plain` with
  a sandbox CSP** (2026-11-08, the first production probe of `agent-auth`).
  The function sends `Content-Type: text/html; charset=utf-8` and its own
  CSP; what `<ref>.supabase.co` returns is `content-type: text/plain`,
  `content-security-policy: default-src 'none'; sandbox` and `nosniff`,
  so a browser shows the authorize page as source. The dev tunnel never
  showed it because it never went through that gateway, and the Deno tests
  cannot see it. It is Supabase's anti-phishing rule for their own domain,
  not a bug of ours, and custom headers pass through untouched, so
  `agent-auth` also sends `X-Smooth-Content-Type` and `X-Smooth-CSP` and the
  connector front restores the real headers on `/agent-auth` responses
  (never on `/mcp`). The wrong fixes: serving the page from the front
  itself (two copies of the page to keep equal) or sniffing the body for
  `<!doctype html>` (the marker is explicit and costs nothing).
- **A card's swipe `DragGesture` attached with `.gesture` steals the
  scroll** (2026-11-10, Marco: "if you're clicking on an assignment and
  you try to scroll, it's buggy"). `AssignmentCardView` and `DoneView`
  put `DragGesture(minimumDistance: 18)` on every card inside the
  dashboard's `ScrollView`. Their `onChanged` returned early for vertical
  movement, which looked like "vertical belongs to the ScrollView", but
  the gesture had already claimed the touch, so a scroll that began on a
  card stuck or stuttered, and an opened card covers most of the screen.
  Fixed with `.simultaneousGesture` plus a direction decided once per drag
  (`CompletionSwipe.Axis`), so the scroll always gets the touch and a
  drifting scroll never moves the card. The wrong fix is a bigger
  `minimumDistance`: it only delays the theft and makes the swipe late.
- **"Unextracted" in SQL is not "pending", and the index's cap must look at
  now, not at the oldest date** (2026-11-05). After the round-4 deploy a
  count of PHYS 0151 documents with no `course_fact_extractions` row at
  their hash said 44, and the hand trigger answered `attempted 0 …
  remaining 0`: all 44 were `assignment` rows, which `FACT_ELIGIBLE_KINDS`
  skips because the description is already structured data. Only eligible
  kinds are ever pending, so a "nothing to extract" answer on a course
  full of old assignments is correct, and the only way to see a prompt
  change live is to wait for a new announcement or Ed post. Separately,
  `buildItemIndex` sorted oldest-due first and cut at 200, so a recycled
  site's 2025 rows could push the current weeks out of the model's view;
  it now orders by distance from now, undated last. The wrong fix would
  have been raising the cap: the prompt has a 12,000-character document
  cap for a reason, and a bigger index is the stale half of it.
- **A Canvas module completion is only "done" for some requirement types**
  (2026-11-05). `completion_requirement.completed == true` on a
  `must_view` item means the student opened it, and the reconciler
  counted every `true` as a completion, so opening an assignment in
  Canvas marked it done in Smooth. Only `must_submit`, `must_mark_done`,
  `min_score` and `must_contribute` complete a card now. Pair of it: a
  Canvas-derived completion had no way back (`structuredCompletedItemIDs`
  only grew, and `markActive` did not touch it), so a swipe back to
  active was re-completed on the next rebuild. The student's "mark
  active" now records an override; a Canvas un-tick retires the id only
  after a run that read the planner, the missing list and that course's
  modules in full, for a row inside the planner window. The wrong fix:
  replacing the set with each run's result, which drops ids on every
  partial read.
- **Deleting server-side facts does not retract them from a phone, and a
  rejection must be a verdict on the key, not on the row** (2026-11-05).
  A fact's id on the phone is documentID+seq, so clearing `course_facts`
  and re-extracting gives every phone a second copy at new seqs (this is
  why round 4 was deployed without re-extracting PHYS 0151). And a
  student's `undo` used to reject one fact id, so a typo edit to the post
  (new hash, old facts pruned), a second post saying the same thing, or a
  re-extraction re-applied the cancel. A rejection now suppresses every
  fact with the same (course, type, target) whose `postedAt` is not later,
  and pruning keeps rejected rows. Retry of a finished extraction was the
  server-side door to the same duplication: delete, insert and update were
  three statements, so a run that died after the insert was retried five
  minutes later with new seqs; `finish_fact_extraction` does the three in
  one transaction (migration `20261105090000`).
- **A network secret saved on the functions host strips every client
  Authorization header from the cloud sessions** (2026-11-05). The canary
  probe needs two headers: `x-lhf-probe-secret` (the gate) and
  `Authorization: Bearer <anonymous JWT>` (the function's own sign-in).
  Saving the probe secret as an environment network secret for
  `ynetfjixexksxqrrkwsg.supabase.co` opened the gate and then every call
  to that host, the probe's and a plain `curl` to `/auth/v1/user`,
  answered as if no Authorization had been sent (`no_authorization` for a
  fresh valid JWT and for a bogus one alike). The proxy that injects the
  credential drops the client's own Authorization on that host; the
  proxy README says nothing about it. The deploy session of 2026-11-02
  probed fine on the same environment because no such secret existed
  then. Fix: the probe runs on a GitHub runner (`ask-probe.yml`), where
  the secret is a repository secret and nothing sits between the script
  and Supabase; and the environment secret should be removed. The wrong
  fix is a second credential for Authorization: the JWT changes per
  anonymous user.

- **A Supabase management token starts with `sbp_` and comes from
  supabase.com/dashboard/account/tokens, not from the project's API keys
  page.** The facts deploy (2026-11-05) lost two attempts to this. The first
  token string was corrupted in transit and the Management API answered HTTP
  401 "Invalid access token". The second was a project *publishable* key
  (`sb_publishable_...`), which is a different credential for a different
  API, and answered 401 "JWT could not be decoded". A flat 401 means the
  string itself is wrong: a valid token from an account outside the
  organisation would list no project rather than fail. The token now lives in
  `~/lhf-bench/supabase.token` (mode 600), which
  `backend/scripts/deploy-function.mjs` reads. The wrong fix is to keep
  retrying or to widen the account's access; look at the prefix first, and
  never paste the string into a chat, a log or a doc.

- **A new SwiftData model goes in its own store file, never in the ledger's
  schema** (decided 2026-11-04 for `AppliedFact`). Adding `StoredAppliedFact`
  to `LedgerSchemaV1` looks like the natural home ("the ledger is where
  per-item state lives") and the wrong fix is to do it and write a
  `LedgerSchemaV2` migration. The ledger's migration path has never opened a
  real pre-existing on-disk store (Known gaps), failure there is a silent
  fallback to an empty ledger, and the widget opens `Assignments.store` with
  its own one-entity container that would then disagree with the app about
  the file. A facts feature must not be able to put the student's record at
  risk. `AppliedFactStore` is a file of its own (`AppliedFacts.store`) with
  its own versioned schema, the `GradeHistoryStore` pattern; the cost of the
  separate file is nothing. The same reasoning kept `FactItem` as a plain
  value the engine reads rather than a new ledger column.
- **Canvas-derived completions, dismissals and dates are not student edits**
  (decided 2026-11-04). The tempting fix for "Canvas says this is done" is
  `setCompleted`, and for "the section's date is Nov 8" is a write into
  `dueDateEdits`. Both are wrong. `userCompleted` and `dueDateEdits`
  carry no provenance, `dueDateEdits` is synced between devices and pruned by
  id family, and a later sync could not tell Canvas's value from the
  student's choice; a Canvas-written entry would ship to their other devices as if they had
  chosen it. `AppState+StructuredSources.swift` keeps additive
  sets (`structuredCompletedItemIDsV1`, `structuredDismissedItemIDsV1`) and
  a map (`structuredDueOverridesV1`) in `UserDefaults.lhf`, read when the
  pool is built; the student's tick, un-tick and edit stay theirs and win by
  construction (`effectiveDueDate` reads the edit first). Likewise
  `applySubmissionState` is a full replace and is the wrong tool for an
  additive signal.
- **Pooled assignment text carried the student's own submission state.**
  `CanvasCourseContentClient` wrote a "Status: submitted | not submitted"
  line into the assignment document it uploads to the shared pool, so one
  student's submission state reached every classmate's copy. Found
  2026-11-04 while wiring facts, and removed there (the assignment-document
  test now asserts the pooled text has no "Status:" line). Already-pooled
  documents keep the old text until their next revision. This is the area
  Olisa owns; it was landed and flagged rather than parked because it is a
  privacy fix to a rule `docs/PRIVACY.md` states.
- **The 24-hour clock said signed out while Canvas said yes, and a
  background attempt had spent the hour the foreground needed.** Read off
  Marco's phone on 2026-11-01, on the App Store 3.4.0 (17): the "needs a
  refresh" banner over a cookie set Canvas still accepted. The saved
  `canvas_session` was a day past its last save, so `isExpired` read true
  and `canvasSessionExpired` went true with no server round trip. At 12:25
  a background wake had run a 20-second renewal attempt and recorded
  `landedOnLoginPage`; that timestamp seeded the one renewer cooldown
  shared by both contexts, so the open inside the hour got
  `.notAttempted`, nothing was in flight, and `ContentView` showed the
  banner at once. The launch grade fetch then succeeded, Canvas rotated
  the cookie, and the banner cleared by itself (the "sometimes clears"
  report of 2026-10-08). The tells: `lastSilentRenewalSummaryV1` ending in
  "background" with `lastSilentRenewalAttemptAtV1` under an hour old,
  `confirmedDead` and `awaitingDuo` both false, and a fresh `capturedAt` on
  `canvas_session` minutes later with the renewal summary unchanged.
  Fixed on `v9` (`docs/SIGNOUT_2026-11-01.md`): when the clock is the only
  reason, `refreshCanvasSessionExpiredState` leaves the flag alone and
  asks `GET /api/v1/users/self` with the folded jar including the
  clock-stale saved cookie (`SessionCookieStore.loadIncludingClockStale`,
  probe-only); `.alive` re-stamps the Canvas session cookies, `.dead`
  proceeds as before, `.unknown` changes nothing. Background and
  foreground attempts gate on separate persisted slots
  (`lastBackgroundSilentRenewalAttemptAtV1`), a background timeout is
  `.timedOut` on any host, and the banner needs a verdict (confirmed dead,
  login missing, a rejected password, Duo waiting, a failed foreground
  attempt, or a dead probe). The wrong fixes: raising 24 hours (the rule
  is Olisa's proven trigger and stays byte for byte), or dropping the
  clock for the server alone (the `fac110d` trap). Canvas's own cookie
  lives one day from the last request (`session_store.rb`,
  `expire_after ||= 1.day`), so a daily user's grade fetch keeps it alive;
  the rule trips exactly after a day away, when the session is often fine.
  Proven on Marco's phone 2026-11-02: an aged launch logged `session
  probe: alive, re-stamped 1 cookies` one second in, with no banner. Note
  for the next device check: `-LHFAgeCanvasSession` clears both cooldown
  slots before `init`'s one-time slot migration runs, so that launch can
  never show the migration; read the plist after an ordinary launch.

- **Two `swift test` runs at once share one scratch defaults domain, and a
  run killed half-way poisons the next one.** Under the test runner
  `UserDefaults.lhf` lands in the `swiftpm-testing-helper` domain on the
  Mac, one domain for every worktree. On 2026-10-27 seven worktrees were
  testing at once; a usage-limit cutoff killed several runs mid-suite,
  and from then on `ProfileTabTests` and `SyllabusExamDashboardTests`
  failed in a third worktree, in isolation, with another suite's course
  preferences (`ADDU 1200`, `SYLDASH 96xx`) and a flipped announcement
  switch left behind. The in-process guards (scratch suites, backup and
  restore) cannot see another process. The tells: a failure naming a
  course code from a different test file, and `defaults read
  swiftpm-testing-helper coursePreferences` showing fixture names. Fix:
  wait until `pgrep -f LowHangingFruitKitPackageTests` is empty, run
  `defaults delete swiftpm-testing-helper`, then test again; and never
  trust a full run that overlapped another worktree's. The wrong fix is
  editing the failing test to tolerate the leak.
- **A persisted "onboarding not done" flag is a lock-out, not a
  navigation state.** `restartOnboarding(for: .canvas)` used to write
  `hasCompletedOnboarding = false` to disk so `RootView` would show the
  sign-in walk, and the walk's Canvas step had only a back chevron to
  the school picker. A student who tapped "reconnect canvas" with no
  signal, without their Duo phone, or who force-quit mid-login woke up
  on the first-run walk on every relaunch, their ledger intact but
  unreachable. Four auditors found it independently on 2026-10-25
  (hardening plan A2). Since 2026-10-27 a reconnect from the banner,
  Profile → accounts or the grades screen is a memory-only
  `isReconnecting` cover over the dashboard (`fullScreenCover` on iOS, a
  sheet on macOS) with an xmark close on every step, and a force-quit
  lands on the dashboard; only "start over" (`.full`) still clears the
  flag, and preview mode still takes the old root swap. The wrong fixes:
  a skip on the first-run Canvas step, which must stay required, and
  removing the preview link, which is App Review's only way in. Two
  tells for next time: a flag another launch reads must never be
  written to express where the UI is right now; and a cover that keeps
  the dashboard mounted must re-run whatever the old root swap re-ran on
  remount (here `refreshSessionSourcesAtLaunch`, from
  `.onChange(of: isReconnecting)`), or the reconnect looks done and
  nothing refreshes until the next five-minute tick.
- **A slug built from outside names is not a unique key, and
  `Dictionary(uniqueKeysWithValues:)` turns the first collision into a
  crash.** `GradeCategoryMapBuilder.mirroringCanvas` gave every Canvas
  assignment group the id `"map:" + slug(name)`, where the slug is the
  lowercased alphanumeric runs of the name, and `GradeEngine` keyed
  `Dictionary(uniqueKeysWithValues:)` on it. Two groups named "Homework"
  and "homework", or "Quiz (EC)" and "Quiz - EC", or the two
  "Assignments" groups a Canvas course copy leaves behind, share an id,
  and the dictionary traps. The automatic sync runs the grade fetch at
  launch for every selected course, in Release, with the grades UI
  hidden, and `recordHistory → breakdown` runs the engine on the result:
  so the app died a few seconds after every open, for every student in
  such a course, with nothing on screen and no way to reinstall out of
  it. It shipped in every build since Grade Watcher existed and was
  found by the 2026-10-25 audit the day before the 2026-10-26 launch made
  it visible (`docs/LAUNCH_CRASH_2026-10-26.md`). The tells: a crash
  that follows the dashboard by a few seconds, is per course rather than
  per phone, and survives a reinstall. Two wrong fixes: dropping one of
  the colliding groups (its weight and items vanish from the grade,
  silently), and changing the id scheme for everyone (student edits and
  the server's suggested mappings are persisted keyed on the bare id, so
  a non-colliding name must keep exactly `"map:" + slug`). The right
  shape: suffix only the collision with the Canvas group id, and make
  every dictionary keyed on Canvas, Gradescope, syllabus or server ids
  first-wins (`uniquingKeysWith:`), because a trap on outside data is
  never the right failure mode.
- **Canvas answers 401 for "not allowed", not only for "signed out".**
  On 2026-10-23 the owner paired the Chrome extension, sync worked both
  ways, and 40 minutes later the collector had uploaded nothing. Every
  Canvas fetch in the collector read any 401 as a dead session and threw
  the whole run away; but a course that hides its Files (common), Modules
  or Pages answers `401 {"status":"unauthorized", "user not authorized
  to perform that action"}` to a perfectly live session, so one such
  course discarded every course's material. The phone's
  `CanvasCourseContentClient` has the same rule (any 401/403 is
  `sessionExpired`) and survives only because it never asks for Files.
  The extension now judges a 401/403 by asking `/api/v1/users/self` once
  per run: alive means that endpoint is forbidden (that course is not
  fully synced; files are skipped), dead means out. An HTML page or a
  redirect off Canvas is still "out" at once. The wrong fix is reading
  the body's wording, which Canvas has changed before; the session check
  asks the question that matters.

- **An identity lookup on every call can take every function down.**
  Since 2026-10-22 `requireUser` (`_shared/auth.ts`) looks the caller up
  in `device_links` to resolve a paired Chrome extension to its phone. Its
  first version failed every request on any lookup error, which is right
  for a real error, but `ask` is redeployed from `v8` often, and one
  deploy before `20261022090000_chrome_extension.sql` was applied would
  have answered 502 to every phone. A missing table (`42P01`/`PGRST205`)
  now means "not linked", which is exactly true; every other error still
  fails closed. The wrong fix would have been falling back to the token's
  own id on any error, which silently makes a linked device a stranger.
- **The complete-set rule belongs to whoever collected the document.**
  The `sync` upload retires every live document of a fully-synced course
  the client did not list. The phone never holds announcements, pages
  past 40 or files, so once the extension uploaded them the phone's next
  hourly sync would have retired them all. `course_documents.collector`
  (2026-10-22) limits a phone's report to `collector = 'phone'` rows; the
  extension's report retires any collector, so it must list every
  document it holds after applying `download`, as the phone does, or it
  would retire the server's own `website` crawls.

- **A "flagged, never deleted" doc comment was a delete.** Announcement
  rows hidden because their post vanished get `isGoneFromFeed`
  (`markGoneFromFeed`), copying the flag a vanished feed item gets, and
  its doc comment said "never deleted". The flag's other reader said
  otherwise: `AssignmentStore.isAgedOut` (run by `reconcile` through
  `pruneAgedOut` on every Canvas sync, over every source) deleted any
  unfinished flagged row 14 days after its date, and a test
  (`AnnouncementDeletionTests`, "a gone row ages out like a gone feed
  item") pinned the deletion as intended. After that nothing could undo
  it: `markPresentInFeed` restores a flag, not a row, and the post's id
  is in `processedAnnouncementIDs`, so the extractor never produces the
  task again. A wrongly flagged row (a truncated fetch, a class that
  returned nothing) became a permanently lost task two weeks later. For a
  feed item the same rule is harmless, because the feed lists it again;
  an announcement row has no feed to re-derive it from. Found in review,
  2026-10-18, by reading the predicate instead of the comment. The fix
  exempts `.canvasAnnouncement` (Canvas, `ed-` and `syllabus-`) from aging
  by name, in the store and in the widget's copy of the predicate
  (`LedgerWidgetReader`, which also hides a flagged announcement row now,
  since aging no longer will), and the test now pins non-deletion and
  restoration. The wrong fix is trusting the flag's doc comment, or the
  test, over `isAgedOut`: when a rule says "flag, don't delete", find
  every reader of the flag, not just the writer. Two guards beside it
  make a wrong flag rarer (a class that returned nothing is not judged;
  two misses in a row), but a rarer wrong flag was never the fix.
- **`xcodegen generate` deletes Info.plist content** unless it lives in
  `project.yml`'s `info.properties`. The widget dependency must be
  `platformFilter: iOS` — case-sensitive; `platforms:` is silently discarded.
  Don't regenerate unless a build actually demands it.
- **iOS names an app from `CFBundleDisplayName`; macOS does not.** The Mac
  build called itself "LowHangingFruit" for every version of the Smooth
  rename, in the application menu beside the Apple logo, in About, and under
  its icon, while the phone said Smooth — because nothing on macOS reads
  `CFBundleDisplayName`. The menu bar, About box and alerts read
  **`CFBundleName`**, which was still `$(PRODUCT_NAME)`; Finder, Launchpad
  and the Dock read neither, they read the **file name of the .app bundle**,
  which is `PRODUCT_NAME` itself. So the rename took all three keys, and the
  fix is not complete with any two of them. The keys had to go in
  `project.yml`, not just `App/Info.plist` — the Mac archive is the one lane
  that must run `xcodegen generate`, for the per-SDK entitlements override,
  which is precisely the step that rewrites the plist (see the trap above).
  Renaming `PRODUCT_NAME` is safe for the ledger because every path that
  holds student data derives from the bundle id or the App Group, neither of
  which moved; what it does break is a script hard-coding the built product's
  path, and it leaves an existing Mac user's pinned Dock tile stale.

- **Tests share `UserDefaults.standard`.** Any test touching selection or
  completion must normalize on the way in *and* out, or it fails the *next*
  suite. Use a scratch suite (`UserDefaults(suiteName:)` + `removePersistentDomain`).
- **`UserDefaults(suiteName:)` succeeds for any string**, entitlement or not. The
  real test for a usable App Group is asking `FileManager` for the container.
- **Without the App Group entitlement the ledger degrades to memory** and the app
  looks completely normal until a relaunch loses everything. A "storage"
  section in Settings used to surface this; it dropped out of the page in a
  Settings merge before `V7` and its dead code was deleted on 2026-09-24,
  so from then until 2026-10-10 **nothing warned the student**. The
  dashboard now shows "not saving on this phone" (`StorageHealth`). See
  Known gaps.
- **`AVAudioSession` is never configured by default**, and `AVPlayer` then
  activates it as `.soloAmbient`, which stops the user's music. `SplashView`
  used to set `.ambient` + `.mixWithOthers` for its clips (which had **no
  audio track**; muting was never the fix). The splash and that line are
  gone from the tree (checked 2026-10-22: no `AVAudioSession` use remained),
  so the dictation controller (`VoiceDictationController`), the one thing
  that now touches the session, remembers whatever category it finds, sets
  `.record` only while listening, and puts the old one back with
  `.notifyOthersOnDeactivation` on every stop path. Anything that plays
  audio in future has to live with that or coordinate with it.
- **Regex patterns needing real Unicode characters must not be raw strings.**
  `#"...\u{2013}..."#` passes the escape through literally, the pattern fails to
  compile, and `try?` turns that into a silent wrong answer.
- **`swift test` compiles the macOS slice.** iOS-only API (`PageTabViewStyle`,
  WidgetKit, `AVAudioSession`) must sit behind `#if os(iOS)` / `canImport` or it
  breaks the test build.
- **An unsandboxed macOS test run resolves the App Group container WITHOUT the
  entitlement** (learned 2026-08-24) — `swift test` on a dev Mac would reach the
  real Mac app's ledger, shared defaults, and widget snapshot.
  `SharedDefaults.isTestRunner` guards all three choke points. Never remove
  those guards.
- **Preferences go through `UserDefaults.lhf`**, never `UserDefaults.standard`.
  Tests must save and restore through the same accessor or they are not reading
  what `AppState` writes.
- **Credentials never go in defaults.** Session cookies live in the Keychain
  (`SessionCookieStore`); so does the Canvas feed URL (`ICSFeedURLStore`),
  because `…/feeds/calendars/user_<token>.ics` is a bearer credential. This is
  why `canvasICSURL` is absent from `SharedDefaults.legacyKeys`.
- **`Path.addLines` moves, it does not connect.** Building a filled outline as
  `addLines(leftEdge)` then `addLines(rightEdge.reversed())` produces two
  separate open polylines, not one closed region, because the second call does
  a `move(to:)` to its first point. Filling that yields two zero-area slivers.
  The shape still *draws* — as a pair of hairlines with the page showing
  between them, which reads as a pale object with dark edges rather than as
  nothing — so it survives code review and previews and is only obvious on a
  device screenshot. Walk the second edge with explicit `addLine(to:)`
  (`BranchBackdrop.taperedPath`).
- **A prompt-cache prefix must be byte-stable or it is not a cache.** Anthropic
  caching is a *prefix match*: one changed byte anywhere invalidates everything
  after it, silently, with no error and no symptom except the bill. So
  `AssistantContextDocument` never reads a clock, never emits a relative date
  ("in 3 days"), sorts every collection, and pins its formatters to
  `en_US_POSIX`/UTC. The wrong fix — and it looks completely reasonable — is
  "put today's date at the top of the document so the model knows what day it
  is": that changes the prefix every day, and with a timestamp, every request.
  The current date belongs in the user message, after the `cache_control`
  breakpoint. Verify with `usage.cache_read_input_tokens`; a persistent zero
  means something upstream is varying.
- **Inverting black-on-white artwork for dark mode makes a negative.**
  The "chill" Buddha was drawn in dark mode with `.colorInvert()` +
  `.blendMode(.screen)`, which lights the shadows and darkens the face.
  Dark mode now draws `chill-dark.png` (the enclosed paper kept, ink and
  border-reachable paper transparent, flood-filled as below) as a template
  tinted light blue (`smoothCobaltInk`). Likewise the pastel accents are fills, never text:
  use their `…Ink` partners (`courseAccentInk(for:)`) for type.
- **Knocking a flat background out of artwork is a flood fill, not a colour
  key.** `Resources/persimmon.png` is the app logo with its cream plate
  removed, and the obvious approach — make every cream pixel transparent —
  destroys it: the seams *between* the calyx lobes are the same cream as the
  plate, so keying on colour punches holes straight through the calyx and the
  lobes lose the separation that makes them legible at 26pt. Fill from the
  image border instead, so only cream reachable from the edge goes. The same
  logic catches a subtler case — an *excluded* shape's enclosed detail (a
  leaf's cream vein) is equally unreachable from the border, so it survives as
  a stray mark floating where its leaf used to be, and has to be culled by
  asking which shape encloses it. There is no PIL, ImageMagick or numpy on the
  dev Mac; `sips` resizes and converts but does none of this. A short
  CoreGraphics script run with `swift file.swift` is the tool.
- **The Canvas assignment id is in the ICS event's URL *fragment*.** Canvas's
  `to_ics` (`app/models/calendar_event.rb`) writes every assignment event's
  URL as `/calendar?include_contexts=course_<id>&month=…&year=…#assignment_<id>`
  — never `/assignments/<id>` — and its section-override branch rewrites the
  UID to `event-assignment-override-<overrideID>` and the summary to
  `"<title> (<section>) [<code>]"` while leaving that URL alone (its own
  source says `# TODO: event.url`). So the fragment is the only id an
  override row carries, and the number in an override UID is an *override*
  id, a different id space: join on it and the wrong work reads as done.
  `Assignment.canvasAssignmentID` reads the fragment; the diagnostics
  report's `via=fragment` is the proof it worked. Confirmed on a real phone
  2026-09-09 after every PHYS 0151 lab row showed `via=none`.
- **`PersimmonMark`'s `size:` argument does not constrain it.** Its body is a
  `GeometryReader` that ends in `.frame(maxWidth: .infinity, maxHeight:
  .infinity)`, so the view expands to fill whatever space its parent hands
  it; `size:` only sizes the image drawn *inside* that already-expanded
  frame. Passing `size: 64` into an unconstrained `VStack` slot renders a
  full-screen persimmon, not a 64pt one — a caller must also apply an
  explicit `.frame(width:height:)`, exactly as the file's own `#Preview`
  does. The wrong fix would have been either hunting for a magic `size:`
  value that happens to look right in one place, or editing `PersimmonMark`
  to drop the `GeometryReader`/fill-to-frame behavior — every existing
  caller relies on that behavior and already pairs it with its own explicit
  frame. This is invisible in code review and in Xcode previews, where the
  surrounding layout happens to be bounded anyway, and only showed up on a
  device screenshot.
- **An unsized `Color.clear` expands to fill, and `minHeight:` is a floor, not a
  ceiling.** `OnboardingView.skipButton` returned a bare `Color.clear` for steps
  with no skip action, and `topBar` wrapped it in
  `.frame(minWidth: 44, minHeight: 32)`. `Color.clear` has no intrinsic size, so
  it took every point of height on offer, inflated the top bar, centred the back
  chevron a third of the way down the screen and pushed everything below it with
  it. The symptom pointed elsewhere entirely — the Canvas WebView rendered as a
  thin band under a screenful of empty background, which reads as "the login
  pane isn't filling" — so three separate fixes went looking for missing height
  inside the panes (`.frame(maxHeight: .infinity)` on the pane, a
  `safeAreaInset` restructure of the chrome, a fill on `OnboardingView.body`)
  and none of them touched the cause. The height was never missing; an invisible
  view was eating it. Size the placeholder at the source
  (`Color.clear.frame(width: 44, height: 32)`). Two tells worth remembering:
  `backButton` was never affected because it uses fixed `width:height:`, so the
  asymmetry between the two ends of one bar was the clue; and temporary
  `.border(Color.red)` on three views found this in one build cycle after three
  cycles of reasoning had not. When a layout bug survives two fixes, stop
  reasoning and draw the frames.
- **Never commit real Canvas/Gradescope data** — user ids, feed-token URLs, cookies.
- **A `static func` on a SwiftUI `View` is main-actor isolated, and Swift 6
  enforces it at run time.** `GradeCourseCardView.decidedText` is a pure
  string rule that tests call directly; the `{ $0.lowercased() }` closure
  inside its `map` inherited the View's isolation and, on swift-testing's
  executor, died in `_dispatch_assert_queue_fail` -- `swift test` exits
  with "signal code 5" and no "Fatal error" line, and the crash report's
  main thread shows only an idle run loop (read the `triggered` thread from
  the `.ips`). Three earlier tests in the same suite passed because they
  returned before the closure was formed. Mark such helpers `nonisolated`;
  do not mark the test suite `@MainActor`, which hides the trap and leaves
  the next background caller (a widget, a notification body) to find it.
- **Seeding a persisted flag through `UserDefaults.lhf` in a test is not
  hermetic even with backup-and-restore.** `FirstLaunchHoldDashboardTests`
  wrote `canvasSessionConfirmedDeadV1 = true` for the duration of each test
  and restored it after; that looked like the sanctioned pattern. But every
  `AppState.init` in every concurrently running suite that landed inside
  that window read a dead Canvas session, engaged the first-launch hold,
  and hid its own overdue fixtures -- ten assertions in four unrelated
  suites (dedup, Done tab, ledger scenarios, cookie store) failed at once
  with no grade code in their stacks, after two green runs of pure
  scheduling luck. The tell was the timing: every failure at 1.3-1.8s, the
  window that suite ran in. A flag another suite's `init` reads needs a
  per-instance seam (`forceCanvasSessionConfirmedDeadForTesting()`), not a
  shared-domain write. Restore-on-exit protects the *next* suite, never the
  ones running *alongside*.
- **An installed Canvas Student app steals the login WebView's return hop.**
  Confirmed 2026-09-12: with Canvas Student on the phone, "connect
  Canvas" opened the Canvas app and never connected; deleting Canvas
  Student fixed it. WebKit treats a main-frame navigation as a universal
  link candidate when it traces back to a user gesture (the identity
  provider's page was loaded by the user's Duo tap, and that permission
  propagates to navigations the page starts) and the destination host
  differs from the current main-frame host. The SAML return from
  idp.pennkey.upenn.edu to canvas.upenn.edu is exactly that, and Canvas
  serves the app-association file on canvas.upenn.edu, so iOS hands the
  hop to Canvas Student. Nothing in Locust opens a Canvas URL on purpose;
  the code had not changed in a month; the phone had. A programmatic
  `WKWebView.load(_:)` is never an app-link candidate, so
  `LoginNavigationObserver` cancels a cross-host arrival at the guard host
  and re-issues it itself (`appLinkGuardHost`). The wrong fix is
  cancelling and reloading `navigationAction.request`: WebKit never puts
  a POST body on that request, so the SAML POST would arrive empty. The
  guard rebuilds the POST from the identity provider's form in the page
  before re-issuing it, and allows the navigation unchanged when it cannot.
- **`NLEmbedding.sentenceEmbedding(for:)` blocks the calling thread while
  iOS downloads the asset.** On a fresh install (2026-09-12, the first
  Smooth build, the app deleted and reinstalled for the icon) the first
  question in ask showed the streaming cursor for two minutes and nothing
  else. Not the network: the phone's 60 s URLSession timeout would have
  printed the fallback message. `CourseSearch.rerank` asked Apple's
  NaturalLanguage framework for the English sentence embedding, on the
  main actor, synchronously, before the request was even built, and on a
  device that has never loaded that asset the call waits for a system
  daemon to fetch it, with no timeout and outside any URLSession. The
  tell: a stuck cursor that outlives every network timeout, on a device
  that just had the app reinstalled or was just restored. The embedding is
  a bonus on top of BM25, so `SentenceEmbeddingProvider` hands it out
  only once it is already loaded and starts the load on a background task
  the first time anyone asks; retrieval itself now runs off the caller's
  actor. The wrong fix is moving the whole search to a background queue:
  the student still waits minutes for an asset that may never arrive.
- **A jsonb column outlives the TypeScript type that wrote it.**
  `catalog_courses.components` rows written on 2026-09-07 had no
  `meetings`; the next day's code iterated `component.meetings`, the stored
  rows were read back untouched, and every manifest naming that course
  returned 500 for a day — silently, from the app's side, because the
  upload is gated on the manifest and the only symptom was
  `last_full_sync_at` never filling. Normalize jsonb at the read boundary
  (`dbRowToCatalogRow`), let a legacy row force a refetch
  (`catalogNeedsFetch`), and never let an enrichment step fail the exchange
  it decorates (`handleManifest` catches the catalog step). Deno tests
  cannot catch this: they only ever see rows the current code wrote.
- **A thinking model's reasoning counts against `max_tokens`, and the
  server never forwards it.** `z-ai/glm-5.3-flash` streams its reasoning as
  `delta.reasoning`; `_shared/openrouter.ts` forwards only `delta.content`.
  On a real phone (2026-09-14) "when's my next exam?" with a 14.5k-token
  prompt of real syllabi reasoned until the 1200-token cap and emitted no
  content: the server returned 200 after 35 s having sent exactly one
  line, `done`, and the student saw an empty bubble. Two repros with
  synthetic prompts of the same size reasoned briefly and answered, so
  size alone does not trigger it; real course text does. The tells: the
  `ask-trace` line `7 stream finished: 1 lines, 0 deltas … completion
  1200`, and `pg_stat_statements` showing the quota RPC never slow (it was
  the first suspect). `reasoning: { enabled: false }` was rejected by
  OpenRouter with 400 on its first live call and the 400 body was not
  logged then (it is now, `ask: upstream failure detail`) -- because `glm-5.3-flash` is an
  always-thinking model; OpenRouter rejects every attempt to disable it.
  Resolved 2026-09-22 by measurement on `ask-canary` (see the ask section
  under Architecture): `reasoning: { effort: "low" }` cuts its thinking to
  ~6 tokens but a third of requests still took 8-66 s to the first word
  with zero reasoning tokens -- provider time-to-first-token, which no
  parameter reaches -- so the primary is now `openai/gpt-4.1-mini`
  (1.9-3.0 s every time, and right about "tomorrow" where the cheaper
  models were wrong) with `glm-5.3-flash` at low effort as a five-second
  hedge. The client's `BackendAssistantResponder` still hands an empty
  `done` to the on-device answerer as the last resort.
- **"Byte-stable" never meant "UTC".** The ask context document rendered
  every due time in UTC and the user message carried `Current date:` as a
  UTC instant, both chosen so the prompt-cache prefix never varied. The
  cache only needs the same bytes for the same student, and a student's
  zone is as fixed as their work list; UTC bought nothing and cost the
  model the calendar day: an 11:59 pm Eastern deadline read as the next
  day and from 8 pm Eastern "today" was already tomorrow (read 2026-10-24,
  fixed blind 2026-10-25). The tell was that no probe ever asked an
  evening question: `ask-probe.mjs` sent `new Date()` from a UTC shell.
  The wrong fix is a zone line inside the cached document; the student's
  local date and time go in the excerpts block, after the breakpoint,
  where a change costs nothing.
- **A 504 from `/rest/v1` can be the API gateway, not Postgres.** The
  2026-09-13 20:47 "database stall" was `sb_gateway_version: 2` timing out
  after ~5 s (`origin_time: 5126`, 29-byte body
  `{"message":"Gateway Timeout"}`) on the hop to PostgREST, with Postgres
  idle, no restart, no errors, and the RPC's max ever 23 ms. Before
  blaming the database, pull `edge_logs` for the request id and read
  `origin_time`, then `pg_stat_statements` for the query; the management
  API's logs endpoint returns nothing for windows wider than a few
  minutes, so query narrow windows (since 2026-10-25 the path is
  `/v1/projects/<ref>/analytics/endpoints/logs`; `logs.all` answers "has
  been removed"). Also from that day, a misdiagnosis worth
  keeping: every ask logged "record_ask_usage exceeded 4000ms deadline"
  while the row still landed, and this file blamed the write running
  after `yield done`. Measured on 2026-09-22, the write lands in 125-440
  ms; the warning came from the timeout promise's own `setTimeout`, which
  nothing cleared when the request won the race, and
  `EdgeRuntime.waitUntil` kept the isolate alive long enough for it to
  fire. Fixed by clearing that timer in `finally` (`quota.ts`,
  `outcomes.ts`). The tell that should have caught it sooner: the warning
  fired on every request at exactly the deadline, never at a
  request-shaped time.
- **A recycled Canvas site carries the previous year's due dates, and one
  of them can define the whole term.** `GradeCountPredictor.term(for:)`
  anchored the term on the earliest due date across a course's items, and
  `Term.elapsedWeeks` clamps to the term's own length, so CIS 4500 read
  "week 14 of 14" on 2026-09-15 — the third week of the semester — while
  every other course read "week 1 of 14". The site was reused: three items
  still carried 2025 dates ("Met Instructor" 2025-10-14, "Class
  Participation" and "Ed Participation" 2025-12-09) ahead of the real work
  starting 2026-09-11. The term now starts after the last gap wider than
  the term's own length, since two items more than a whole term apart
  cannot belong to the same term. The first attempt used a tuned 8-week
  threshold and its own new test caught the flaw on the first compile: the
  last 8-week-plus gap in that course is the eleven weeks between the
  September homework and the December final, so it anchored on the final
  exam and claimed the semester begins in December. When a rule needs a
  magic number, check whether the quantity it is really about is already
  in scope — here it was `weeks`, the parameter one line away.
- **Penn restricts student Canvas access tokens.** The app can mint a 120-day
  Canvas access token from inside the student's own login and use it for
  `/api/v1` fetches (`CanvasAccessToken.swift`, `CanvasAccessTokenMinter.swift`,
  `CanvasAccessTokenStore.swift`, `accessToken:` on the Canvas clients), but
  Olisa's own Canvas settings page shows "+ New Access Token" greyed out, with
  the tooltip "Your Canvas administrators have chosen to limit your ability to
  generate your own access token" (canvas.upenn.edu/profile/settings) — the
  tell to check for on any other Penn account before assuming this works. A
  mint would 403 for every Penn student, so `FeatureFlags.canvasAccessTokens =
  false` gates the whole path off rather than deleting it, for the day Penn
  issues an OAuth developer key (what the Canvas Student app uses) or lifts
  the restriction. `CanvasDiscoveryClient` must stay cookie-only regardless of
  that flag, because bearer tokens are only honoured on `/api/` paths
  (`lib/authentication_methods.rb`) and discovery hits non-API pages. The
  wrong fix in both directions: storing nothing and living with the daily
  re-login the app already had before this work is simply the *previous*
  state, not a fix owed here; and scraping the password back out of the
  login page's DOM to synthesize a token is the fix that was considered and
  rejected — it defeats the whole point of a scoped, revocable token by
  handing the app a full credential anyway. (That rejection stands for
  minting a token. The broader rule it came from, that the app never reads
  what the student types into Penn's page, was **reversed by the owner on
  2026-10-23**: no more retyping into a second sheet, and a PennKey is
  kept only from a sign-in Canvas has just verified, in memory for at most
  10 minutes first, then the Keychain, this-device-only, nothing leaving
  the phone. See "Stay signed in" above. Marco wrote the change; it is
  uncompiled, so read the old wording as history and the new as intent
  until a phone has signed in with it.)
- **The 24-hour cookie rule is what keeps a student signed in; removing it
  signed Marco out.** `fac110d` (2026-09-24) dropped
  `SessionCookieStore.load()`'s rule that treats a no-expiry Canvas cookie
  as dead 24 hours after its last save. The reasoning looked sound: the
  server, not a local clock, should decide when a session is dead, so keep
  the cookie until Canvas rejects it. But that rule is the *trigger*: it is
  what flips `canvasSessionExpired` and runs `CanvasSessionRenewer` on the
  next open, while the app is on screen and the hidden WebView runs at full
  speed. Without it the renewer only ran after a Grade Watcher 401, and on
  2026-09-26 one such attempt on Marco's phone filled the saved password
  and then sat on Duo until the 30 s timeout. That read as `.needsDuo`,
  latched `autoLoginAwaitingDuoV1` and `canvasSessionConfirmedDeadV1`, and
  showed the reconnect banner. Olisa's phone, still on a 2026-09-21 build
  with the rule, never signed out. The tells, read off the phones with
  `devicectl`: the two flags true on one phone and false on the other,
  and Duo's `browsertrust` cookie re-issued at each successful renewal.
  Restored for Penn byte for byte from `39b2fff` (`df759f8`), including
  the connect pane's `login/saml` start URL and cookie filters, and the
  failed-connect no-op (`a16ea07`). The wrong fix: trusting the server
  and dropping the clock, as above. Because background wakes crash (next
  trap), the 2026-09-26 failure was a renewal with the app open, not a
  background stall; whether Duo's trust had lapsed or its page was just
  slow that day is unknown.
- **Every background refresh crashed from 2026-08-24 until `v8`, invisibly**
  (fixed 2026-10-09, blind: the launch handler is now `{ @Sendable task in
  … }` into a `nonisolated` static, and background renewals never latch;
  the history stays here because the wrong fix is still tempting).
  `LHFBackgroundRefresh.register()` hands `BGTaskScheduler` a launch
  handler with `using: nil`, so iOS runs it on its own background queue.
  The closure inherits main-actor isolation, and Swift 6 checks that at
  run time, so the app dies on entry (`SIGTRAP`, `_dispatch_assert_queue_fail`,
  thread queue `com.apple.BGTaskScheduler (com.lhf.lowhangingfruit.refresh)`)
  before any work happens. It is the same trap as the `decidedText` entry
  above. Nobody sees it, because the app is closed at the time. The tell
  is the `.ips` reports on the phone (`Smooth-<date>.ips` under
  `systemCrashLogs`, five on Marco's phone from 2026-09-24 to 09-27). The
  consequence that matters: "Olisa's proven logic" has only ever been
  renew-on-open; no background refresh or background re-login has ever
  run. The wrong fix is to fix the crash alone. That turns on background
  re-logins, the one path never tested, whose hidden WebView may stall on
  Duo and latch `needs Duo`. Fix it together with a foreground-only guard
  on `CanvasSessionRenewer` (`ROADMAP.md` → Now).
- **A background wake that starts a renewal and does not await it has
  not run a renewal.** The first `v8` fix made `BGTask` wakes renew: the
  fresh `AppState()`'s `init` sees the expired cookie and fires
  `Task { await attemptSilentCanvasRenewal() }`, then `run()` does its
  syncs (which return in a second or two when the cookie is dead, because
  there is nothing to sync with) and calls `setTaskCompleted`. iOS then
  suspends the process with the renewal mid-navigation, or mid password
  submission, and nothing is saved or recorded; the next wake starts over
  and, six hours on, submits the password again. Found by review before
  any device saw it (2026-10-09). The fix is a stored task
  (`startSilentCanvasRenewal` / `awaitPendingSilentRenewal`) plus a
  teardown on expiry; the wrong fix is a timer in `run()`, which would
  race the renewer's own 20 s budget. From the same review: a `.failed`
  WebKit navigation (offline) fell through the host classification with a
  nil URL and came out as `.landedOnLoginPage`, so two tunnels an hour
  apart could latch a live session dead; and the one-hour attempt
  cooldown lived only in memory, so two relaunches bypassed it. The
  general tell: a "blind" commit's riskiest paths are the ones no test
  can drive (`BackgroundRefresh.swift` is iOS-only and never compiled by
  `swift test`); review those by hand before the device does.
- **Canvas's announcements API ends its window 28 days after it starts,
  unless told otherwise.** `end_date` defaults to `start_date` + 28 days.
  `CanvasAnnouncementsClient` sent only `start_date`, which was correct by
  accident while every caller asked for the last 14 days. On 2026-10-10
  the megaphone list widened its start to 60 days, and on Marco's phone
  the new log filled with exactly two announcements, 46 and 39 days old,
  and nothing newer: the request had become "60 to 32 days ago". Worse,
  the Announcement Watcher was silently dead, because nothing from the
  last 14 days reached extraction any more. Tests could not see it: the
  stub returned whatever it was handed. The tells, read off the phone:
  `announcement-log.json` holding only old records while
  `processedAnnouncementIDsV1` held newer ids. Fixed by passing `until:`
  (tomorrow) from `syncAnnouncements`; the regression test's stub now
  honours the window the way Canvas does. The wrong fix is shortening the
  look-back to 28 days. The same bug sat in `CourseKnowledgeCollector`
  (200 days back, no `until`, so its window ended about 172 days ago and
  it never collected an announcement; Marco's phone, same day: 106 course
  documents, none of kind `announcement`) until 2026-10-23, when the owner
  had the sync touched (`9540751`, 120 days through tomorrow); the first
  phone sync on that build uploaded 63 of this term's posts at 18:09 UTC.
- **Apple Intelligence rewrites the on-device answer under `swift test`.**
  `OnDeviceLanguageModel.compose` runs Apple's on-device model whenever
  `SystemLanguageModel.default.availability` is `.available`, and on a Mac
  with Apple Intelligence on (Marco's, macOS 26.6.2) that is true inside
  the test runner too. So `AskKnowledgeWiringTests` "cites the syllabus it
  quoted" sometimes got a paraphrase instead of the grounded text: on
  2026-11-06 one run of 3688 answered "Late work in CIS 2400 loses 10% per
  day after the third day and is not accepted after three days" for a
  grounding that says only "three late days for the semester", took 9 s,
  and failed `contains("three late days")`; the suite alone then passed.
  The tell: a test on the on-device responder that takes seconds instead
  of milliseconds, and an assertion message quoting words the fixture
  never had. `compose` now returns nil under `SharedDefaults.isTestRunner`.
  The wrong fix is loosening the assertion: the deterministic text is the
  contract. Worth more than the flake: the paraphrase invented a policy
  ("10% per day") the sources do not contain, which the `validated(_:against:)`
  check let through. Nobody has looked at that check since; it is in Known
  gaps.
- **Every worktree's test run shares one defaults domain.** On 2026-10-10
  four agents ran `swift test` in four git worktrees at once and
  unrelated suites failed at random: `CourseContentDashboardTests` saw
  `"SCEN-G 100"` where it had written `"SCEN-A 100"`,
  `AnnouncementWatcherWiringTests` and `AskKnowledgeWiringTests` failed
  once each and passed on the next run. Under the test runner
  `UserDefaults.lhf` is the test process's standard domain, and that
  domain belongs to `swiftpm-testing-helper`, not to a checkout, so two
  runs in two directories write the same keys. It is the shared-
  `UserDefaults` trap again, across processes this time, which is why
  `--no-parallel` did not help. The tell is a failure in a suite the
  change never touched, with another checkout's values in the message.
  A verification run has to be the only test run on the machine; the
  counts in Test baseline were taken that way. The wrong fix is
  retrying until green and calling it verified.
- **"Ed and announcements aren't being scraped" was a deleted Canvas
  session, not a scraping bug.** On 2026-10-18 Marco reported that
  neither Ed posts nor Canvas announcements were arriving. Both were
  fine in code. Everything that reads Canvas with the student's login
  (announcements, course materials, Ed's launch) hangs off one chain,
  `refreshCanvasGrades` → `refreshCourseIntel` /
  `refreshCourseKnowledge`, and that chain returns early when no
  Canvas cookies are saved. On 2026-10-10 the Grade Watcher screen
  (`GradeWatcherView.performRefresh`) removed the saved cookies after a
  session-expired fetch, and with nothing saved,
  `SessionCookieStore.isExpired` reads false: no "needs a refresh"
  banner, no renew-on-open, and a dashboard that still looked alive
  because the calendar feed needs no login. The tells, read off the
  phone with `devicectl`: `edTabCheckedAtByCanvasCourseV1` frozen at
  2026-10-10 and no `debugRenewalLogV1` entry after that day. The
  missing Grade Watcher button (2026-10-15) was the same cause. Removing
  Grade Watcher (2026-10-18) removed that purge from every Release path,
  and Profile → accounts now shows "sign in to canvas" whenever Canvas
  is connected with no saved login. The wrong fix is chasing the
  scrapers; the purge-without-banner behaviour belongs to the sign-in
  code and was left for Olisa (Known gaps).
- **Stale cards from old Ed posts were a window problem, three layers
  deep, and not a bad class or a bad kind of task.** On 2026-10-18 the
  owner's todo, all and prev filled with tasks nobody could still do or
  needed to: "Take quiz covering assignments 1 and 2" (an Ed post from
  Sept 14, already taken), "Attend the weekly rotation quiz" (a
  start-of-class reminder), mostly from CIS 2620's Ed; "none of these
  previous ones are honestly helpful". Three things stacked.
  (1) The Ed documents the course-material sync pools reach back 120 days
  (`EdIngestion.defaultMaxAge`), while the Canvas pass extracts only from
  the last 14. The Ed pass has the same 14-day window, but on
  `CourseDocument.updatedAt`, which for Ed is the thread's last
  *activity*: a Sept 14 thread somebody replied to on Oct 15 is a
  14-day-old post by that measure. The document carries no creation date.
  (2) The extractors resolve "today" and weekday names against the
  extraction day, not the post's, so a task from an old post can carry a
  date that looks fresh. (3) A task whose date had passed was moved to
  prev as "past", and an undated one never lapsed, so whatever got
  through stayed forever. The fix is a set of visibility rules at rebuild
  time ("Which announcement tasks show", under What the app does), plus
  the Ed pass skipping a post it cannot date. The wrong fixes, each of
  which looks reasonable: filtering by kind (hide every Ed task) or by
  course (hide CIS 2620), which hides real work and leaves the pipeline
  that made the clutter; deleting the stale rows, which the ledger's
  invariant forbids and which `processedAnnouncementIDs` makes permanent
  (the post is marked read, so the extractor never produces the row
  again); parking them in a quieter list, which is what put them in prev;
  and hiding every Ed task whose post is older than 14 days whatever its
  due date, which would take "Project due Dec 1", pinned on Oct 1, off
  the dashboard on Oct 20.
- **An alarm's stop is any dismissal, so it must never mean "turned in".**
  The owner asked for "turned in" and "open in canvas" on the Berserk
  alarm (2026-10-19), and the obvious mapping is stop = "turned in".
  AlarmKit has one stop and one secondary button. Apple's AlarmKit FAQ
  says the stop intent also runs when the alarm is swiped away or the
  side button pressed (one developer reports it doesn't, on 26.2.1:
  developer.apple.com/forums/thread/815064). Either way, a student who
  silences the alarm without handing anything in would have the work
  marked done and taken off the dashboard ten minutes before it is due,
  the exact failure the alarm exists to prevent. So "turned in" is the
  `.custom` secondary, which only an explicit tap reaches, and stop opens
  the assignment. A wrong trigger then costs a Canvas page, not a missed
  deadline. Since iOS 26.1 the stop button's own label is ignored
  (`AlarmPresentation.Alert.init(title:stopButton:…)` is deprecated with
  "stopButton … will no longer be used"), so the system shows "Stop"; a
  stop that opens Canvas is a known, accepted surprise pending the
  owner's verdict on a phone.
- **Penn Labs' "current" semester is the one open for registration, not
  the one in session.** The catalog fetched
  `penncoursereview.com/api/base/current/courses/{code}/`, and around
  2026-10-15 Penn Labs flipped `current` to `2027A` for advance
  registration. Every refetch after that stored Spring 2027 sections
  (rooms, times, instructors) under the fall course's code, and a
  fall-only course (CIS 2620) 404ed and kept its old row, which the
  legacy-row rule then retried on every manifest call. Found 2026-10-20
  within an hour of shipping section rooms to ask, because CIS 2620's
  row never refetched while the five that did all said `2027A`. The tell
  is the `semester` column disagreeing with the calendar. The fix asks
  for the semester explicitly (`academicSemester(now)`, by date in New
  York: A to May 20, B to Aug 15, then C), refetches a row whose semester
  differs, and never serves one (`rowsForSemester`) to ask or to the app.
  The wrong fix is a fallback to `current` when the explicit semester
  404s, which reintroduces the wrong semester silently. The app sends no
  Canvas term (`courses.term` is null for every row), so the date is the
  only signal the server has.
- **A badge computed in `body` turned the merge into a freezing app.**
  On 2026-10-20 the owner reported the phone "lagging and freezing a
  lot" after the merge. `ContentView.unreadAnnouncementCount` read
  `AppState.unreadAnnouncementCount` two to four times per `body`
  evaluation, and since the merge that computed property rebuilt both
  megaphone lists on every read: `announcementPostDates` (a full ledger
  fetch whenever any candidate lacks a post date), the visibility rules,
  and `resolvingAnnouncementDuplicates`, an all-pairs scan whose course
  match ran `CourseCode.parse` (four regex compiles) per pair. `body`
  re-evaluates on every `AppState` publish, and a rebuild publishes about
  eight properties, each of which also queued its own
  `DashboardViewModel.reload`. At beed156 the badge was a read of stored
  arrays; the redesign made it a recompute and nothing measured it. Found
  by a read-only audit of beed156..HEAD, not by a profile. Four fixes,
  blind: the badge is stored and refreshed at data changes; the
  `CourseCode`, `AssignmentDeduplicator.normalize` and
  `ExamDetection.normalizedCourse` regexes are `static let`s; each
  rebuild parses every item's course identity once and buckets the
  comparison pool by it (safe because `announcementCoursesMatch` was
  already a plain equality of `announcementCourseIdentity`); and the view
  model coalesces a burst of publishes into one reload. The wrong fix is
  caching only inside `body`: the rebuild itself was tens of thousands of
  regex compiles per call. The rule: never put a computation that reads
  the ledger or scans all pairs in a SwiftUI `body` or a property `body`
  reads; store it and refresh it where the data changes.
- **Ed posts that "vanish" were deleted by the course-material sync, not
  by Ed.** Marco's megaphone showed no Ed posts for days while Olisa said
  Ed worked, and both were right: on 2026-10-23 Marco's phone read both
  of his Ed classes at 15:05, yet every one of its 35 Ed posts had been
  first stored at 15:05 (unchanged posts keep their old `fetchedAt`), so
  none had survived any earlier run. `CourseKnowledgeCollector` merged
  each re-synced class as a complete set, which removed its `.ed`
  documents, and saved the file at once. Ed's pass, which only starts
  after a hidden launch of up to ~40 s, put them back from
  `priorEdDocuments`. If the app left the screen in that window, or the Ed
  run failed, the file kept no Ed posts and the next run had nothing to
  restore. The fix is `merge(preservingKinds: [.ed])` in the collector: it
  never produces Ed documents, so it has no say over them. The wrong fixes
  look reasonable: saving later in the collector still loses everything on
  a crash between the two saves, and keeping a second copy of Ed posts for
  the megaphone would hide the bug from ask and the upload, which read the
  same file. The tell: an Ed post's `fetchedAt` equal to the latest sync
  for every post at once.
- **A card that stays "not done" after a real submission is usually a
  missing session, not a detection bug.** Marco's PHYS 0151 prelab,
  2026-10-18: handed in, still on the dashboard. Canvas submission state
  has exactly one source, the cookie-authenticated grades fetch
  (`AutoSyncCoordinator.refreshCanvasGrades`), and it returns at its
  first guard (`canUseGradeWatcher`) when no Canvas login is saved, while
  the cookieless calendar feed keeps the dashboard looking alive. The
  phone's state fits that: no saved login from 2026-10-10
  (`edTabCheckedAtByCanvasCourseV1` frozen at 14:23 UTC that day, no
  `debugRenewalLogV1` entry after 22:48 UTC; read by an earlier session,
  and the fix for the missing banner is `parked/missing-login-banner`).
  Whether that was this card's cause is not confirmed: it is not recorded
  whether Marco signed in again, or whether the prelab went to Canvas or
  Gradescope. Gradescope has the same shape and a worse ending: an empty
  Gradescope cookie set (24 hours without a successful sync) flips
  `isGradescopeConnected` off inside
  `AutoSyncCoordinator.syncConnectedServices` with no notice, and only the
  onboarding connect button ever turns it back on, so Gradescope status
  freezes for good (`needsGradescopeConnection` exists and nothing shows
  it). Read the session state first (Commands, the device reads;
  `submissionDiagnosticLines` on a DEBUG build). The wrong fixes:
  loosening `indicatesSubmitted` (a teacher's zero on a missing item would
  read as handed in) and shortening throttles (a fetch that never runs is
  not helped by running it more often).
- **A keyword scan must not read the item's own name.** Gradescope has no
  student API, so `GradescopeHTMLParser` decides "submitted" by scanning
  text for words like "graded", "submitted", "resubmit" and "uploaded",
  and the title cell was part of that text: "Graded Problem Set 3" whose
  status said "No Submission" read as handed in, its reminders
  cancelled. The detail-page check (`isCompletedAssignmentPage`) did the
  same with the page's heading, so fixing the row alone would have been
  undone one request later. Since 2026-10-18 both blank the title first
  (`removingTitle`), except a title that is itself part of a negative
  phrase ("Not"), where blanking would turn "Not Submitted" into
  "Submitted". The wrong fix is a longer negative-word list: it fights one
  title at a time.
- **Two Canvas assignment ids are two assignments, whatever the titles
  say.** `collapseCanvasDuplicates`' title/date pass hid module "Lab 3
  Report" (id 222) behind calendar "Lab 3" (id 111): a 0.667 title match,
  due hours apart. Assignment 222's own submission then reached no card,
  and a swipe on it was carried onto "Lab 3". Since 2026-10-18 that pass
  skips a pair whose ids are both known and differ; a row with no id is
  still matched by title as before. Ticks carried before the fix stay
  (Known gaps). The wrong fix is retuning `isLikelyDuplicate`, which moves
  every other dedup path for a problem that exists only when both ids are
  known. Gradescope rows carry no Canvas id, so the Canvas↔Gradescope
  pairing cannot use this veto.
- **One analytics cookie switches the 24-hour rule off, for good.**
  `SessionCookieStore.isExpired` is "something is saved, and `load()`
  returns nothing", and `load()` keeps any cookie whose own `expiresDate`
  is still ahead, whatever its age. Both harvests save more than the
  session: `CanvasLoginPane.connect()` keeps every cookie on
  `canvas.upenn.edu`, and `CanvasSessionRenewer` keeps every cookie whose
  domain contains "canvas". So Google Analytics' `_ga` (thirteen months)
  and `sso.canvaslms.com`'s `last_known_canvas_host` (a year) ride along,
  and from then on the set is never empty: `isExpired` reads false while
  `canvas_session` itself has been dropped as stale. No banner, no
  renew-on-open, and `hasCanvasCredentials` still true, so the app sends
  Canvas a request with analytics cookies and no session. It is the
  `fac110d` failure through a different door: the renewer only runs after
  a Grade Watcher 401. Read off Marco's phone on 2026-10-08, on the store
  build, with `-LHFSessionDiagnostics`: seven saved cookies, three "still
  fresh" (`_ga`, `_gid`, `last_known_canvas_host`), `isExpired: false`. One
  `-LHFAgeCanvasSession` launch then ran 55 seconds without any renewal;
  the next renewed in 9 seconds through the saved password and Duo's
  trust, started by the 401 and not by the rule. The tells: an aged launch
  with no `canvasSessionExpired false -> true` line in `debugRenewalLogV1`,
  and a "still fresh" count above zero when every session cookie is old.
  Whether a phone is in this state is a race at each harvest (was the
  analytics script done when the cookies were read), which is why one
  phone can have it and another not. The wrong fix is filtering the
  harvests alone: sets already saved on students' phones stay polluted,
  so the rule has to be decided at read time, by whether a fresh session
  cookie is left. Two things this ruled out on the same phone, the same
  day: the saved password was on file and worked, and the Canvas Student
  app (installed, 8.12.1) did not take the hidden renewer's return hop.
  Penn's app-association file now claims only `/canvas/login`.
  **Fixed at read time on 2026-10-27** (hardening plan A3, on
  `fix/duplicate-category-ids`): `SessionCookieStore.load` runs its old
  per-cookie pass and then `gatedOnLiveSession`: a Canvas set that once
  held a session-named cookie (`canvas_session`, `_normandy_session`)
  and has none fresh reads empty, so `isExpired` trips and renew-on-open
  runs; a set that never held one keeps the old rule, so an unknown
  school is never read as signed out; a fresh session cookie returns the
  whole set, analytics included. The harvests still save `_ga` on
  purpose (Olisa's `39b2fff` code, untouched), because the gate heals
  sets already on students' phones and a harvest filter never would. One
  tell above has moved: `debugRenewalLogV1`'s "still fresh" count is now
  taken after the gate, so a polluted phone reads 0 there, and the
  `-LHFSessionDiagnostics` lines, which now mark session cookies with
  `| session`, are what to read. Not yet run on a phone.
- **Nothing under `backend/` can be exercised from `swift test`**; run its deno
  tests separately (`cd backend && deno task test`, `deno task check`).
  `BackendServices.client` is nil under tests and in an unconfigured build, so
  the app is fully on-device there — a green test run proves nothing about the
  backend path.

- **A textually clean merge can put a line in the wrong place, and two
  lines of work can build the same thing under different names**
  (2026-10-20, merging `v8` with `v8-loud-alert-actions`). Both sides
  edited `SettingsPage.swift`: one added two debug sync-summary rows inside
  a "sign-in diagnostics" disclosure, the other deleted that disclosure and
  moved its contents. Git merged without a marker and the two rows landed
  inside the Release-visible "sign in to canvas" row, so a student's
  Settings would have shown them. The tell is that a file merged "cleanly"
  while the thing around the hunk had been deleted on one side; read the
  merged file around every hunk, not only the conflicts. The same merge
  found the owner's rule "announcement and Ed tasks vanish at their due
  time" written twice (`AppState.isExpired` widened, and
  `isHiddenAnnouncementTask`), and the Ed posts read twice (one loop that
  read them as Canvas-shaped announcements, one pass of their own with a
  different find id). Both would have compiled, passed their own tests and
  disagreed on a phone: a task moved by the student would reappear in one
  and not the other, and one Ed post would have made two finds under two
  ids. The fix was to pick one of each, and give the survivor what the
  other had that it lacked. The wrong fix is keeping both "for safety".
  Grep the diff of each side for the same noun before merging.
- **The async `didReceive` delegate form calls iOS's completion on the
  cooperative thread, and UIKit aborts.** Every tap on a Smooth notification
  (a reminder, a loud buzz, one of its buttons) killed the app: five crash
  reports read off Marco's phone on 2026-10-27, dated 2026-10-19 to 10-26,
  builds 12, 13 and 14. The tell is an `.ips` with `SIGABRT` (not
  `EXC_BREAKPOINT`) whose triggered thread is
  `com.apple.root.user-initiated-qos.cooperative`, running `@objc closure #1
  in NotificationResponseDelegate.userNotificationCenter(_:didReceive:)` into
  `_updateSnapshotAndStateRestorationWithAction`, which asserts it is on the
  main thread. The async form's thunk calls the completion handler wherever
  the async body ends, a cooperative-pool thread. Fixed on `release/3.3.1`
  with the completion-handler form, calling `completionHandler()` at the end
  of one `Task { @MainActor in }`. The wrong fixes: marking the method
  `@MainActor` (iOS calls it off-main, so Swift 6 kills it on entry, the
  background-refresh trap) and keeping the async form while hopping inside
  it (the thunk's completion still runs on the cooperative thread).

## Conventions

- **Comments explain *why*, at length, in prose.** Read `StoredAssignment.swift`,
  `SharedDefaults.swift` or `CourseCode.swift` for the register. Thin comments
  that restate the code are worse than none. When a fix is non-obvious, record
  what the *wrong* fix would have been.
- **Commits**: short imperative subject, then prose paragraphs explaining the
  reasoning and what was rejected. End with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Tests are `swift-testing` (`@Test` / `@Suite`), not XCTest.

## Branches

`v11` (2026-11-10): `v10` `4c136b2` plus the Sweeper page (header broom,
per-class lead time and sound) and the scroll fix for cards
(`CompletionSwipe.Axis`). Pushed at Marco's request; not merged into
`v10`. The unpushed `agent/connection-v11` work is separate and has not
been merged into it.
`v10` is the line (2026-11-03): `v9` plus `origin/v8` `7e004c5` plus
`phase0/extract-facts-bench`. Start at `docs/HANDOFF_V10_2026-11-04.md`
(it replaces the 2026-11-03 one). The 2026-11-04 composed-day work
(Phases 1-3) is committed on `v10`.
`design/grey-exams-striped-nosubmit` (2026-11-04 to 11-06): grey exam
cards, "in class" under the due value, source words only in the opened
card, squircle header buttons, no "older hidden" line. Merged into `v10`
(fast-forward) at Marco's go on 2026-11-06. His standing rule: design work
waits on its own branch until he approves it.
Before it, `v8` was the line. Marco's launch-prep work (2026-10-09/10) was merged
into it on 2026-10-10 through pull request 9, at Marco's instruction;
`v8-launch-prep` is the branch it was built on. So `v8` now carries work
most of which has not been on a phone (Known gaps), and whatever ships
from `v8` next ships with it. The rest is history, kept because some of
it holds work that exists nowhere else.

| Branch | What |
|---|---|
| `claude/v11-phone-c7aaf2` | **2026-11-10, off `agent/connection-v11` `2503a3b`, local, not pushed, not merged.** The phone halves of v11 Phases 3 and 4: drafts polled onto the card, the review sheet, `CanvasSubmissionClient` with the attempt store, the "connected" confirmation and dashboard line (What the app does → "Drafts from an agent"). Compiled and tested; never on a phone, never against Canvas. The session that started it merges. |
| `v11` | **The line since 2026-11-10 (about 07:30 UTC, at Marco's "Yes, push to v11").** `origin/v11` was fast-forwarded from Marco's two commits (the Sweeper page, `CompletionSwipe.Axis`) to the merged tree `f8330ab`: all of `agent/connection-v11` (below) plus the night's three session branches. Marco's other thread pushes to it too; fetch before merging and never force-push. New work branches from here. |
| `agent/connection-v11` | **2026-11-08, off `research/agent-connection-v11` (so off `v10` `4c136b2`); pushed to origin under its own name on 2026-11-10 and merged into `v11` the same morning (equal to it at `f8330ab`).** The build session's branch: the Canvas submit spike (`f5da516`), the Phase 1 backend (`7ca84a5`: `agent-auth`, `mcp`, `agent-snapshot`, migration `20261108090000_agent_connection.sql`, the `AgentStore` contract with PostgREST and memory implementations, `scripts/serve-agent.ts`), the docs. A Claude Code sign-in completed end to end against the dev tunnel the same day (research §8). Never push to or merge into `v10` without Marco's approval. |
| `research/agent-connection-v11` | 2026-11-07/08, docs only, off `v10` `4c136b2`: the v11 agent-connection plan (`docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md`, revised to cloud-first and phone-submits on Marco's word), the research write-up (`docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md`) and the brief for the build session (`docs/AGENT_CONNECTION_SESSION_PROMPT.md`). Supersedes `research/agent-canvas-via-smooth` (2026-10-30, also docs only). Nothing built. |
| `v10` | **Current line (2026-11-03 onward).** `v9` (the no-banner sign-in, the onboarding polish, the composed-day research) plus `origin/v8` `7e004c5` (the tree's recency and follow-up work) plus `phase0/extract-facts-bench`. The merge's Swift run is recorded under Test baseline. |
| `phase0/extract-facts-bench` | 2026-11-03, off `v9`: the extract-facts bench, prompt, schema and parser; the model decision (Haiku 5.5, `docs/EXTRACT_FACTS_BENCH_2026-11-03.md`). In `v10`. |
| `v9` | 2026-11-01 to 11-03: the no-banner sign-in and keepalive, proven on Marco's phone; the onboarding polish merged; the composed-day research. In `v10`. |
| `v8-merge-marco` | **The merge of seven of Marco's branches into `origin/v8` at `63b228f`, 2026-10-23; not compiled, not pushed, not yet fast-forwarded into `v8` (the plan is `docs/MERGE_PLAN_MARCO_2026-10-23.md`).** In order: `fix/submission-status` (the module-row id veto and the Gradescope title scan), `fix/canvas-signin-bulletproof` (the analytics-cookie diagnosis and `-LHFSessionDiagnostics`; no behaviour), `v8-launch-prep` (its handoff doc only), `parked/missing-login-banner` (the banner and renew-on-open when the cookie item is gone), `parked/gradescope-unverified-submission`, `v8-server-exam-dates` (needs a `sync` deploy from `v8`, v14 or later, before the app sees anything) and `codex/automatic-canvas-login` (the PennKey saved automatically after a verified sign-in; the vault becomes a repair tool; the owner's reversal of 2026-10-23, see Stay signed in). Not merged: `parked/launch-submission-refresh` (would also post turned-in and grade notices at launch on `v8`) and `parked/ask-course-sync-fixes` (conflicts with the 2026-10-23 announcement window). Docs conflicts resolved by keeping both sides with their dates. Deno 428/0 here; Swift predicted 2723, unverified. Safe to delete once it has compiled and been fast-forwarded. |
| `v8-merge-loud-alert` | **The merge of `origin/v8` (Olisa, 10 commits of 2026-10-19, through `55a9203`) and `origin/v8-loud-alert-actions` (Marco: `75dc7aa`, `e3f9af8`, `5cdb4cc`), 2026-10-20; fast-forwarded into `v8` at `4aab3eb` once it compiled green. Safe to delete.** Decisions made by the overseer: one Ed task pass (Marco's, given Olisa's posting day, twin check, quota stop and a summary), one past-due rule for announcement tasks (Marco's `isHiddenAnnouncementTask`; `isExpired` back to the `.event` rule), Olisa's retry cap, quota stop, back-off and summaries kept in the Canvas loop, Grade Watcher stays hidden, Marco's `project.yml` kept. Rows the brief `announcement-ed:` reading wrote stay as inert `.canvasAnnouncement` rows. |
| `v8-launch-prep` | **Marco's launch-prep work, on `v8` at `e2672eb`** (2026-10-09/10): source links on cards, the 10-minute reminder, assignment names in reminders, the sign-up backlog rule, the real announcements list with Ed rows, the ask search / excerpt / follow-up / citation work, the copy cut, saved due-date edits, deleting your own tasks, the widget fixes and ten small fixes. It does not change sign-in or the sync: `sync()`, `syncGradescope` and `connectCanvas` are byte-identical to `e2672eb`. Compiled for iOS; only the first four items have been on a phone. Merged into `v8` on 2026-10-10 (pull request 9); kept as a branch because these notes cite it. |
| `v8-announcements` | **Pushed to origin 2026-10-18 as one commit on `v8` at `beed156`; not merged into `v8`.** Grade Watcher hidden (flag off, code and the grade fetch kept), the megaphone in the header, Olisa's sign-in lines back under canvas in DEBUG builds, "sign in to canvas" when no login is saved, announcement and Ed tasks as cards (per class, hidden once past or stale, deletion-flagged, deduped), the megaphone sheet redesigned (found cards and the past 7 days of announcements under one class filter), exam cards from feed / announcements / syllabus, the loud 10-minute alert (with the time-sensitive entitlement), and "the vault". `v8-loud-alert` and `v8-exams` were folded in as patches, so those two branches hold nothing extra. Its four local WIP commits were squashed into that one commit before the push. 2230/206 green. The last build installed on Marco's phone predates the sheet and the rules; the current build waits on the phone being reachable. Sign-in and sync files are byte-identical to `v8`. |
| `v8-loud-alert-actions` | **Pushed to origin 2026-10-19 as one commit `e3f9af8` on `v8-announcements` at `75dc7aa`; no PR, not merged. The AlarmKit alarm (with its custom sound) is a second commit, pushed the same day.** "Berserk mode": "turned in" and "open in canvas" buttons on the loud 10-minute alert, with the notification delegate installed at launch, and on iOS 26 a real AlarmKit alarm in place of the buzzes (What the app does → Profile → reminders). A build from before the review fixes was installed on Marco's iPhone on 2026-10-19 at 15:21. Separate from `fix/submission-status`, which branches from the same commit. Sign-in and sync files are byte-identical to `75dc7aa`. |
| `fix/submission-status` | **Pushed to origin 2026-10-19 as one commit on `v8-announcements` at `75dc7aa`; no PR; merged into `v8-merge-marco` on 2026-10-23 (not compiled).** Why submitted work can read "not done" (Traps, the three 2026-10-18 entries; Known gaps, "Turned-in state"). Lands two accuracy fixes with their tests: module rows with a different Canvas assignment id no longer collapse into a calendar row (`AssignmentDeduplicator`), and a Gradescope assignment's name no longer counts as its status, on the list row or the detail page (`GradescopeHTMLParser.removingTitle`). Also pins section-override rows through `isCompleted` and corrects the `submittedCanvasAssignmentIDs` doc comment. `syncGradescope`, `sync()`, `connectCanvas` and every sign-in and sync file are byte-identical to `75dc7aa`. Mac tests and an iOS Debug compile only (Test baseline); never on a phone. |
| `parked/launch-submission-refresh` | **Parked, do not merge without Marco's say (Olisa's too: it moves his sync).** One commit `56d27b9` on `75dc7aa`, pushed to origin 2026-10-19 (no PR), 2233/207 green on its own: the iOS dashboard runs the session half of its refresh once at a cold launch, so a submission made since the last refresh is seen at once instead of after the first 5-minute tick. It also brings a full Gradescope scrape, the course-knowledge/Ed sync and the silent-renewal checks forward to launch, as a resume already does, and `fix/canvas-signin-bulletproof` edits the same `ContentView.refresh`. |
| `parked/gradescope-unverified-submission` | **Was parked; merged into `v8-merge-marco` on 2026-10-23 (not compiled).** One commit `5847e02` on `75dc7aa`, pushed to origin 2026-10-19 (no PR): a Gradescope detail page that fails to load (timeout, 5xx) keeps the row's last known "submitted" instead of turning it back to not done (`GradescopeClient.FetchReport`, `preservingUnverifiedSubmissions`). It edits one line of `syncGradescope`, the sync Marco said not to touch. 2240/206 green on its own. |
| `v8-server-exam-dates` | **Local, 2026-10-18, one commit on `75dc7aa` (the `v8-announcements` commit, pull request 10's head); not pushed; merged into `v8-merge-marco`, see that row.** (Merged into `v8-merge-marco` on 2026-10-23, Swift not compiled; Deno 428/0 there. The deploy note below still stands: `sync` v13 is live without it, v12's source plus the NUL guard; a deploy from `v8`, v14 or later, would carry this, with Olisa's go.) The exam dates `extract-profile` already stored now reach the app: `sync`'s manifest carries `examDates` per course (`profileRowToWire` and `isoDayOf` in `backend/supabase/functions/_shared/`, `backend/PROTOCOL.md`), `CourseProfileWire` and `CourseGradingProfile` keep them (decoded leniently, an older server or an old saved knowledge base still loads), and `SyllabusExamRows` prefers a dated server exam over the on-device parse under the same `syllabus-...` id. 2270/208 green; compiled for iOS (Debug, generic device); never on a phone. **The backend half needs a deploy before the app sees anything, and nobody has approved one.** It touches one function, `sync` (`node backend/scripts/deploy-function.mjs sync`): the other functions import the edited `_shared` files but do not call the changed code. A deploy is a production change to the live Supabase project, so it needs Marco's explicit go, and Olisa should be told first because `sync` is the call every install makes. The Deno tests for it were written but not run (no Deno on this Mac); the new cases were run only under Node 24 with a `Deno.test` shim. |
| `olisa-grade-watcher-beta` | Local, 2026-10-15, superseded: Olisa's `ba75e97` plus a grades button and a "beta" tag, uncommitted in `.claude/worktrees/olisa-latest`. Grade Watcher was removed three days later, so nothing there needs merging. |
| `parked/ask-course-sync-fixes` | **Parked, do not merge as is.** Fixes to the course-material sync written on 2026-10-09 and set aside when Marco said not to touch the sync: a half-failed sync no longer erasing documents, a 403 on one course no longer aborting all, 120 page bodies with the front page first. Its commit message lists what an independent review found still open, including one regression and two server-side prerequisites. |
| `parked/missing-login-banner` | **Merged into `v8-merge-marco` on 2026-10-23 (not compiled); it had been parked since 2026-10-18, written for Olisa to review.** On `v8` at `beed156` (2026-10-18). When the saved Canvas cookies are removed entirely (Grade Watcher's rejected fetch, the DEBUG "simulate canvas logout"), `SessionCookieStore.isExpired` reads false, so `canvasSessionExpired` stays false: no refresh banner, no renew-on-open, the saved PennKey password never used. Marco's phone sat signed out from 2026-10-10 to 2026-10-18 that way. The fix adds `canvasLoginEverCaptured` to `AppState` (persisted, set on a login or a renewal, cleared by disconnect, inferred once for older installs from a saved password, the stay-signed-in offer or saved cookies) and ORs a "login is missing" rule into `refreshCanvasSessionExpiredState`; `isExpired` is deliberately unchanged. 1994 tests / 190 suites green with `swift test --no-parallel`; the iOS Debug build succeeds; not run on a phone. |
| `v9` | **Current line (2026-11-01 onward).** `origin/v8` at `019e1a5` plus the probe-before-expired sign-in fix: the 24-hour cookie rule no longer decides "signed out" on its own, Canvas is asked first (`CanvasSessionProbe`), background and foreground renewals keep separate cooldown slots, a background timeout is `.timedOut`, and the refresh banner needs a real verdict. `docs/SIGNOUT_2026-11-01.md` is the record. 3420/328 green; on Marco's phone since 2026-11-02, where an aged launch answered `session probe: alive` with no banner (the cooldown-split and disconnect-during-probe checks are still unit-tested only). Since 2026-11-02 (`e9a2c71`) it also holds the owner's no-banner rule: the sign-out banner is gone for good, replaced by a quiet status line the clock can never trigger; silent re-login runs on every open; keepalive probes; the hidden renewer taps Duo's trust and push buttons itself. `ec926a9` merges Marco's `onboarding-polish-2026-10` (PR 19) into it. 3442/329 green; the no-banner build is on Marco's phone, device checks pending. New work branches from here. |
| `v8` | The line from 2026-10-02 to 2026-11-01; 3.4.0 (17) shipped from it. `V7` plus Ed Discussion ingestion (`docs/ED_DISCUSSION.md`), the sign-out fix, the Chrome extension's Swift half, the announcements-for-ask work, and, since 2026-10-23 21:23 (`fb3ed94`, Olisa's `v8-merge-marco`, `docs/MERGE_PLAN_MARCO_2026-10-23.md`), seven of Marco's branches (`fix/submission-status`, `fix/canvas-signin-bulletproof`, `v8-launch-prep`, `parked/missing-login-banner`, `parked/gradescope-unverified-submission`, `v8-server-exam-dates`, `codex/automatic-canvas-login` = PR #11) plus three fresh patches (`launch-refresh-rework`, `course-sync-salvage`, `ed-tabs-restore`). Its author did not compile it; compiled on Marco's Mac the same night: 2736/246 with one stale structure test (Test baseline). PR #13 (`fix/megaphone-every-class`) merges this tip and is the next thing to land. |
| `fix/megaphone-every-class` | **2026-10-23, off `v8` `a480eb1`, local only, for Olisa's review.** The megaphone fixes Marco asked for (every class, finished-twin finds, the keep-check, Ed staff posts by judgment), the `extract-announcement` relevance field and empty-answer fix (not deployed), and `fix/ed-posts-durable` merged in. Write-up: `docs/ED_AND_MEGAPHONE_PLAN.md`. 2719/246 green; not yet run on a phone. Built app kept at `build/megaphone/Smooth.app` in its worktree (`.claude/worktrees/megaphone`). |
| `fix/ed-posts-durable` | 2026-10-23, off `v8` `a480eb1`, local only (`d4b9a04`), merged into `fix/megaphone-every-class`. Ed posts are no longer deleted by the course-material collector or by a failed `/tabs` lookup. |
| `V7` | The line from 2026-09-23 to 2026-10-02. Contains all of `v6`, `v5`, `V7-polish` and `v8-features`: the session-persistence work, the Settings trim, the todo · all · prev switch and class filter, multi-school sign-in, and (2026-09-27, `df759f8`/`a16ea07`, from the since-deleted `v7-olisa-session`) Olisa's `39b2fff` session logic restored for Penn. 3.0.0 (11) was archived from `ddef468`. New work branches from here, and lands back here. |
| `v8-ann-rules` | **Local, 2026-10-18, off `v8-announcements` at the WIP commit `80c21ec`; not merged or pushed.** The announcement-task visibility rules (past tasks leave the dashboard instead of moving to prev, undated tasks age out after 7 days, same-day class reminders are not cards, the Ed pass reads only posts from the last 14 days). Written to be merged into `v8-announcements` as a patch, and applied there on 2026-10-18, so it holds nothing extra. 2207/203 green on its own; compiled for generic iOS (the phone was unreachable), not installed. |
| `origin/v8` (as of 2026-10-08) | Olisa's Ed Discussion work (four commits, 2026-10-02), on top of `origin/V7`; not merged. It rewrites the staleness line inside `SessionCookieStore.load` and adds a `.ed` service, so a sign-in fix that edits `load` will conflict with it. `origin/V7` is also one commit ahead of the 3.0.0 (11) source (`9769286`, DEBUG owner rows in Settings). Marco's note of 2026-10-08, kept for its dates; since 2026-10-10 `v8` is the line and carries all of it (see its row above). |
| `v8-dice-toggle` | `V7` as of 2026-09-24 with the dashboard's dice "pick one for me" button (`PickAssignmentSheet`, `DashboardViewModel.pickCandidates`). Kept on purpose, not for merging as-is; see `ROADMAP.md` → Tried and parked. |
| `v8-features`, `V7-polish` | Feature branches, fully merged into `V7` (fast-forward). Safe to delete. |
| `update-manifest` | **Orphan branch, never merge.** Holds `lhf-update.json`, the live update policy the shipped app fetches from raw.githubusercontent.com; edit it from GitHub's web UI to lift or set a version floor. |
| `v6` | The line from 2026-09-16 to 2026-09-23: `v5` plus the gated Canvas access-token plumbing and stay-signed-in. In `V7`. |
| `v5` | The **App Store submission line** that uploaded 3.0.0 builds 7–9 (2026-09-06 to 2026-09-16): `assistant-ui` + `v3.5` + the ask knowledge engine, the backend, the Locust onboarding, the update gate, the Smooth redesign and dark mode. In `V7`. |
| `codex/redesign-v5`, `codex/fire-dark-mode`, `codex/smooth-header-layout`, `codex/assignment-pop-empty-celebration` | Marco's design branches (Smooth redesign, "after sunset" dark mode, header and completion polish); `docs/DARK_MODE_HANDOFF.md` and `docs/SMOOTH_INTRO_AND_APP_POLISH_HANDOFF.md` are his notes. Merged into `v5`. |
| `assistant-ui`, `onboarding-walk`, `update-gate` | ask and "the tree"; the Locust intro and onboarding walk; the update gate alone. All folded into `v5`. |
| `v3.5`, `v4`, `v3`, `claude/v4-github-repo-kvu0e0` | The 2.x era: the SwiftData ledger, Grade Watcher, readings-only courses, iCloud Tier 2, background refresh, the Mac tier, per-course reminders, semester rollover. Carried uploaded (never live) 2.0.x builds. In `v5`. |
| `origin/v2.5` | Former ship line, 1.1.1 build 3, Grade Watcher gated off. |
| `main` | Old: 1.0.0 App Store prep. Not the ship line. |
| `v2.75` | Unmerged macOS sidebar/landscape work that exists nowhere else. |

`claude/*` branches on the remote are agent working branches from August;
none is a ship line.

## Known gaps

- **The agent connection is live and proven with one real client; the
  phone half of drafts, the submit itself and ChatGPT are not** (state on
  2026-11-10; `agent/connection-v11`, plus `claude/v11-backend-645aa0` on
  top of it, neither pushed). Live: the connector front
  (`smooth-agent.vercel.app`, 2026-11-08), `agent-auth` v5, `mcp` v3,
  `agent-snapshot` v3 with the hardening and drafts migrations
  (2026-11-10). Proven: Marco's claude.ai connected on 2026-11-09, his
  iPhone approved with the typed code, and Claude read his courses and work
  list; `backend/scripts/agent-e2e.mjs` walks the whole server path against
  production with a throwaway user, drafts included since 2026-11-10 (13 of
  13 steps: propose text and file, list and download, seen, declined,
  submitted, 409, opt-out). **Written and not deployed** (branch
  `claude/v11-backend-645aa0`): the sign-in page's "Connected to Smooth"
  state (Marco's ask) and explicit annotation hints on the read tools; no
  migration, `deploy-agent.mjs` then `agent-e2e.mjs`. **Untried:** the
  `smooth://link` tap from a phone, ChatGPT (whose plan rules are
  unconfirmed; `docs/CONNECTOR_LISTING_CHECKLIST_2026-11-10.md`), the Phase
  3 phone half (polling, the "drafted by Claude" chip, the review sheet),
  the submit spike (`-LHFSubmitSpike`, never run against Canvas), and what a
  model actually sends as `file_base64`. A finished draft's signed URL keeps
  serving the file for the rest of its 120 seconds (Traps). The assignment
  PDFs Claude needs to read a problem set are pooled by the phone since
  2026-11-10, but that pass has never run on Marco's phone because his
  manifest fails on the phone side (next entry). `agent-auth` never ships
  ahead of its migration (`deploy-agent.mjs` applies them first). The plan's
  "Open asks for Marco" (2026-11-10) is the list, and its first item is to
  tell Olisa about the 2026-11-10 sync changes.
- **Marco's course-material sync fails at the manifest on the phone,
  while the server answers 200** (2026-11-05 onward; read 2026-11-10,
  `docs/MANIFEST_FAILURE_2026-11-10.md`). Both manifest calls of
  2026-11-10 (03:53 and 05:45 UTC) were 200 in about 4.5 s with
  byte-identical 6 KB bodies, and the same request from a throwaway user
  decodes under every strict rule of `SyncManifestResponse`. So
  `BackendClient.send` throws after the server is done, most likely
  because the calling task is cancelled (the 11-05 run's "cancel…" error,
  every later Canvas call failing, `partial 5`). The reason sits only in
  memory (`trace.manifestError`); the summary line says `manifest failed`.
  Not fixed: the phone should write the error case into the summary, then
  hold the sync in an `AppState` task that a view's cancellation cannot
  reach. Handed to the dashboard-investigation session. Until then nothing
  uploads from his phone and the assignment-PDF pass never runs there.
- **The phone halves of Phases 3 and 4 are built, compiled and tested
  (2026-11-10, `claude/v11-phone-c7aaf2`, merged here), never on a phone and
  never against Canvas.** Phase 2 (the phone side) is on Marco's phone and
  worked; the phone halves of Phases 3 and 4 (drafts on the card, the review
  sheet, `CanvasSubmissionClient`, the attempt store, the "connected" state)
  are **built, compiled and tested (2026-11-10), never on a phone and never
  against Canvas** (What the app does, "Drafts from an agent"). Before any
  real submit: a Canvas sandbox course and assignment (text, URL and file) for
  the first run, never a graded assignment; open questions there: whether
  Canvas accepts the JSON body with `X-CSRF-Token` from URLSession at all (the
  spike never ran), whether `_csrf_token` is in the saved jar or only in the
  preflight's `Set-Cookie`, what Penn's upload slot answers (inst-fs 201 with
  an id, or a redirect), and whether `can_submit` is sent. Known limits: only
  the newest draft per item shows; a draft for an item not on the dashboard
  has no card and no notice; a definite failure (a 422, a refused upload) ends
  the draft for good, and the student asks the agent for another.
- **A finished item whose completion is Canvas's alone has no swipe back
  in prev** (since 2026-11-06, `AppState.completionIsLockedByCanvas`,
  `DashItem.canMarkActive`). Before that the swipe was offered, did nothing
  (`overrideStructuredCompletionIfItWasTheOnlyReason` withdraws the
  override when Canvas says submitted) and the row hung mid-swipe because
  `DoneCardView` latched `didUndo` (Marco's phone, test report finding 6).
  A planner-tick or module completion can still be swiped back. Open: a
  student who wants to re-do submitted work has no way to make it active,
  by design; and the fix is unseen on a device.
- **"open in canvas" reaches the Canvas Student app through the
  `canvas-courses://` scheme, confirmed on Marco's phone 2026-11-06.** Marco
  had reported it "hasn't been" opening the app. With the 3.4.1 (18) Debug
  build and the console attached, four taps on a PHYS 0151 card each
  printed `LHF-LINK canOpenURL canvas-courses: false` (expected: the scheme
  is not in `LSApplicationQueriesSchemes`, which only gates `canOpenURL`)
  and `LHF-LINK scheme canvas.upenn.edu/courses/1949400/assignments/syllabus`:
  the universal link was refused (Penn's association file claims only
  `/canvas/login`) and `open(_:)` of the scheme URL opened Canvas Student,
  which Marco confirmed ("it takes you to it, which it did properly").
  `CanvasAppLink.result(for:)` is shared by cards, megaphone rows and, since
  2026-11-06, ask's answer links (which went to Safari by policy before).
  What failed for him earlier is unexplained; the two candidates stand: a
  card whose stored URL has no `#assignment_<id>` fragment keeps a
  calendar-shaped URL that `appURL` rejects and opens Safari by design, or
  an older build. The DEBUG `LHF-LINK` lines stay for the next report.
- **The 2026-11-05 bug-hunt fixes (facts, structured sources, silent
  re-login, backend) are on Marco's phone and looked right to him, and the
  `finish_fact_extraction` migration is not applied in production.** The
  Debug build from `8d2dd35` (3.4.0 (17)) was installed over the store copy
  on 2026-11-06 at 16:26 UTC: clean launch, no crash report, both session
  flags false, `factsCursorV1` 23, structured sources
  `completions=11 dueOverrides=14 missing=1`. Marco used it the same day
  and reported nothing wrong (2026-11-06, "I don't notice anything wrong
  with it"); that is a general pass, not a ticked list, so a cancelled
  card, a hand-edited date beating a fact, and a real re-login have still
  not been seen one by one. `docs/V10_BUG_HUNT_2026-11-05.md` → Status lists the 29
  items fixed and the 5 parked (per-user extraction cap; Olisa's Chrome
  extension items 29-31 and 33). Before the next `extract-facts` or `sync`
  deploy, run `node backend/scripts/deploy-facts.mjs --step 1` (it now
  applies both facts migrations, then deploys both functions); deploying
  the functions alone would make every extraction finish throw. The
  sign-in half (items 11-17) changes what a bounced login form means
  (`PennKeyLoginForm.credentialErrorWords` is a guess until the real
  identity-provider error element is captured on a device, read with
  `innerText` and visible nodes only), latches "cannot renew silently"
  only after three positive credential-less landings, and aborts the
  renewer on disconnect and school switch. Watch for on a phone: a
  wrongly disabled saved password after a Duo denial, and the sign-in row
  on a non-Penn install. Not fixed: the megaphone's changed row has no
  undo (item 5, half); Profile's "save pennkey" row does not reappear after
  a Keychain save failure when an older credential is still saved (item
  17).
- **Phases 1-3 of the composed day run on Marco's phone; the tree's
  applied-facts work and the time-frame resolver are installed there but
  unexercised.** On 2026-11-05 at 20:15 UTC the Debug build from `08b2e77`
  (today's `v10`, 3.4.0 (17)) was installed over the previous Debug build
  and launched; at 20:16 UTC `verify-facts-on-phone.sh` read
  `rows=0 completions=10 dismissals=0 dueOverrides=14 missing=1`,
  `structuredCompletedItemIDsV1` 12 (up from 11 the night before, so Canvas
  reported one more completed item; the set is additive), `factsCursorV1`
  still 23 (no new facts on the server), and no crash report newer than
  2026-10-26. The hourly course-material sync had not yet run on the new
  build at that read, and the phone left the cable before a second one. The
  last summary, from the previous build at 19:04 UTC the same day, was
  `manifest failed · uploaded 0 · errors 19 · first failure other ·
  couldn't read the tabs of 3 canvas course(s): cancel...`, against
  `manifest ok · errors 5` at 02:17 UTC: the same open sync item as Olisa's
  `errors 7`, now with a failed manifest once; not investigated (Olisa's
  sync). Still to do by eye on that build: `undo` on a fact-touched card,
  a hand-edited date winning over a fact's date, and the four tree
  questions in `docs/HANDOFF_V10_MARCO_2026-11-05.md` step 4.
  Earlier history of this entry:
  On 2026-11-04 at 20:15 UTC the Debug build from `034767b` (3.4.0 (17))
  was installed over the store copy on Marco's iPhone 17 Pro and launched;
  `verify-facts-on-phone.sh` then read
  `rows=0 completions=11 dismissals=0 dueOverrides=14 missing=1`,
  `factsCursorV1` absent (expected then: no manifest with facts fields yet),
  no crash report, Canvas session alive. So the structured-sources fetch and
  reconcile work against real Canvas; whether the 11 completions and 14
  section dates show correctly on cards has not been checked by eye. The
  card/megaphone fact changes are proven only by fixtures. The migration SQL, `rls.test.sql` and
  `claim_fact_extraction.test.sql` passed in a Docker Postgres on
  2026-11-04 (`backend/scripts/sql-check.sh`). A live probe on 2026-11-04
  showed OpenRouter accepting the exact production request for
  `anthropic/claude-haiku-5.5` (strict `json_schema`, `reasoning: low`,
  `provider: {data_collection: "deny", allow_fallbacks: true}`, no
  `require_parameters`), routed via Azure, returning `{"facts": []}` with 258
  reasoning tokens for $0.0002.
- **The facts backend is live (deployed 2026-11-05, 01:20-01:45 UTC, with
  Olisa's go and a personal access token from his account; the evening of
  2026-11-04 US Eastern) and has produced six facts, two of them wrong in
  kind.** `docs/DEPLOY_FACTS_2026-11-04.md` ends with the run record. The
  `sync` function is at version 17 and `extract-facts` at version 1; the
  secrets check found `OPENROUTER_API_KEY` set and `LHF_FACTS_MODEL`,
  `LHF_FACTS_DISABLED` and `FACTS_COURSE_MONTHLY_LIMIT` unset, so the
  defaults apply. The first extraction was triggered by hand for PHYS 0151
  (course 1949400), because extraction is scheduled only by a document
  upload and no phone had uploaded since the deploy: ten documents, all
  `done`, none rejected, about $0.0067 in total, 999-6264 ms each. Six facts
  came back (2 `new_task`, 3 `note`, 1 `needs_review`) and all six quotes
  were found verbatim in their documents. Two things are wrong:
  1. **Two `new_task` facts are tasks the owner does not want:** `new_task
     high "Final exam"`, supported only by the quote "Final exam:", and
     `new_task high "optional: Midterm 2 point redemption session in DRL
     A1"`. Marco's rule (2026-11-04): an announcement becomes a task only
     when it has clear action words, an assignment that needs to be
     submitted. Three prompt drafts were benched the same night
     (`docs/FACTS_PROMPT_OWNER_RULE_2026-11-05.md` has the tables, the
     drafts live in `docs/facts-prompt-drafts/`). Round 1 passed the gate
     (0 false tasks) but cut task recall from 71% to 47%, because Canvas
     module lines read "<Name> (file). Due <date>", a noun phrase and a
     date with no verb, which a strict "action words" rule rejects; round
     2 fell to 36% and added a false cancel. Marco ruled that a due date
     counts as action words, and **round 3 is what runs now**: deployed
     2026-11-05 02:03 UTC as `extract-facts` version 2 and `sync` version
     18 (`sync` bundles the same prompt, since it extracts right after an
     upload), then round 4 (stale posts: no reschedule or review flag
     from a post older than a week, no task for work already past) as
     `extract-facts` v5 and `sync` v21 at 21:13 UTC the same day, with
     Marco's go, after 702 Deno tests and three gate-passing bench runs
     (`docs/FACTS_PROMPT_OWNER_RULE_2026-11-05.md` → Round 4). Round 3 was
     deployed after 686 Deno tests and two bench runs with 0 false tasks
     and 0 false cancels, task recall 64% and 57% (the same prompt differs
     on 12 of 121 documents between runs, so single-run numbers are
     noisy). PHYS 0151's six old-rule facts were then deleted and the whole
     course re-extracted under round 3 (27 documents, 17 facts, $0.0178):
     one task (the final exam), 13 targeted notes, 3 review items, and the
     two unwanted tasks gone.
  2. **A stale document raises review noise.** The `needs_review` fact came
     from a September document ("Quiz 5 ... Sep 19th") read against today's
     index. No fix yet.
  Phone side, **proven 2026-11-05 02:17 UTC**: the phone's course-material
  sync is hourly and had last run at 01:15 UTC ("skipped: not stale"), so
  the app was relaunched when the hour was up; the manifest ran
  (`lastCourseKnowledgeSyncSummaryV1`: ok · courses 6 · manifest ok ·
  uploaded 0 · errors 5) and `factsCursorV1` read **23**, the highest seq
  on the server, so all 17 PHYS 0151 facts reached the phone in one pull.
  `structuredCompletedItemIDsV1` stayed at 11, so applying facts wrote no
  completion. Later that day Marco looked at the PHYS 0151 cards and reported the
  Midterm 2 notes and the Dec 14 final-exam task both showing. `undo` and
  the rule that a manual date edit wins over a fact remain untried on a
  device. The sync's `errors 5` (fetched 1,
  partial 5) predates this work and is the same open item as Olisa's
  `errors 7`.
- **Phones on the live backend now receive facts, and the kill switches are
  the only brake.** `LHF_FACTS_DISABLED=1` stops new extraction without
  touching stored facts; the phone flag `FeatureFlags.appliedFacts` needs a
  build (`docs/DEPLOY_FACTS_2026-11-04.md` -> "Kill switches"). The
  management token is in `~/lhf-bench/supabase.token` (mode 600) and stays
  there for the follow-up deploys (the tightened prompt, the `ask` model
  move); Olisa revokes it from his dashboard when those are done.
- **Known limits of the facts engine** (from the implementers, 2026-11-04):
  - A `module:<hash>` fact target cannot resolve to a `module-item-<id>` row
    and lands in `needs a look` until module documents carry item ids (the
    per-item module documents, research Addendum C item 8, are not built).
  - A fact-created row from an Ed post reads `announcementOrigin == .canvas`.
  - A newer `reschedule` does not withdraw an older `cancel` on the same
    item (different types).
  - The engine cannot tell when Canvas edited a date after a post.
  - A cancelled item already overdue appears nowhere (todo hides it, all
    excludes overdue, prev is completed-only).
  - When the Canvas rate-limit bucket drops under the floor, every later
    course in that run is skipped.
  - The `claim_fact_extraction` caps (60 per course per day, 400 per course
    per month, 5000 per month overall) are plain-sum reads and can overshoot
    by in-flight claims.
  - A student's AI-assist switch does not stop course-level extraction of
    posts a classmate uploaded (`docs/PRIVACY.md` now says so).
  - Not built: the build-map first read (research Addendum A), Phase 4 (the
    day view) and Phase 5 (feedback).
- **The Duo push path is proven once, on one phone** (2026-11-02, Marco's
  iPhone, `-LHFForgetDuoTrust -LHFAgeCanvasSession`, Debug build of `v9`):
  the hidden WebView reached Penn's form, filled and submitted the saved
  password, landed on Duo's Universal Prompt, was handed back to Penn and
  then Canvas in 27 seconds, hands-free apart from the push. The hidden
  store held no Duo trust cookie and no Canvas session cookie at the
  start, so this was a full password-plus-Duo pass. Not yet seen: a Duo
  prompt that waits a long time for the push (the 120 s cap), the "duo
  trust tapped" line (Duo returned in 4 s, so no button was needed or the
  tap left no log), and the same pass on a second phone. Read
  `debugRenewalLogV1` for "finished: <host> <path>", "login form check",
  "credential fill result", "duo push sent" and "duo push approved"; the
  per-navigation lines are DEBUG-only and were added for this check.
- **Duo passcode autofill is unverified.** `DuoPasscodeAutofill`
  (2026-10-30) is tested only as a string; whether Duo's Universal Prompt
  field gets matched, and whether iOS then offers the SMS code, needs a
  real Penn login with a texted passcode on a phone.

- **The extension's Ed read is proven only against a fake Ed** (2026-11-04).
  Until that day it had never read Ed at all (every live run `ed: none`,
  see `docs/CHROME_EXTENSION.md` → Status for the cause and fix). The
  harness in `chrome-extension/e2e/` proves everything but a real Ed
  login; the first store install that opens edstem.org and then shows
  `collector = 'extension'` rows of kind `ed` on the server is the live
  proof. Expect few: a phone that reads the same board uploads the same
  ids and hashes first, and the planner skips what the server holds.
- **No anonymous Ed post reached the pool through the extension**
  (checked 2026-10-29: every live `ed` row, 622, has `collector =
  'phone'`). Had one, it would have stayed: `ed` is a window kind
  (`WINDOW_KINDS` in `_shared/manifest.ts`), which no client's complete-set
  report retires, so `5481543`'s claim that the next report retires them is
  wrong. If an extension-collected `ed` row ever predates `5481543`, it
  leaves only by the 120-day age-out or a deliberate delete.
- **3.2.1 (15), the live build, crashes a few seconds after every open for
  any student in a course whose Canvas assignment groups have two names
  that slug alike** ("Homework" and "homework", two "Assignments" groups
  in a recycled site). Reported on launch day, 2026-10-26, by several of
  the few hundred people who installed that day, and by a few before.
  Traced in the code (the slug trap below) to hardening plan item A1; the
  fix is on `fix/duplicate-category-ids` for 3.2.2 (16).
  `docs/LAUNCH_CRASH_2026-10-26.md` is the record and the plan. **Not yet
  proven from a crash report**: Xcode's Organizer needs Marco's Apple ID
  signed in before it lists App Store users' crashes, and no affected
  phone has been read. Treat the first `.ips` that arrives as the proof,
  and look for `EXC_BREAKPOINT` inside `GradeEngine`.
- **The hardening groups of 2026-10-27 have not run on a phone.** Every
  item from `docs/HARDENING_PLAN_2026-10-25.md` that landed on
  `fix/duplicate-category-ids` that day (Release A remainder, Release B,
  Release C, the Kit hardening, the backend track) is compiled, tested
  and reviewed, and none of it has been watched on a device.
  `docs/WHAT_CHANGED_3.2.2.md` lists every change with what to look at
  on the phone; the backend commits are not deployed (Olisa's go, with
  the checklist in that file).
- **The feedback card and Profile row (3.3.0) are compiled but not seen on
  a phone** (2026-10-27: 2933/264 green and the iOS Debug build succeeded
  on Olisa's Mac at `3c23d9d`). Not yet watched: the card appearing once
  the live manifest carries a `feedback` object, × and tap both keeping it
  away for good, and the Profile row opening the form in Safari.
- **The hardened update lock (2026-10-27) is compiled but not seen on a
  phone.** `swift test --no-parallel` (2914/262 green) and the iOS Debug
  build, widget included, both passed on Olisa's Mac the same day. Not yet
  watched: the wall replacing the app with a sheet open, notifications
  cleared, the widget's "update smooth" view (build with
  `MARKETING_VERSION=1.0.0` to see the wall for real). The `update-floor` workflow has not run against the real App Store
  lookup yet (the container cannot reach Apple), and the backend version
  check is not deployed.
- **A class's Ed posts can vanish from the phone and come back**
  (Marco's phone, 3.1.0 (13), read 2026-10-23 off a debug build installed
  over the store copy). He saw only PHYS 0151 in the megaphone. CIS 2620
  and CIS 3990 post only on Ed. At 15:05 that day the phone held 35 Ed
  posts for them, and a replay of the saved data through the 3.1.0 rules
  listed three of them. But the seen set
  (`seenAnnouncementIDsV1`) held only those three Ed keys, none of the
  older Ed rows the first Ed seeding marked. `markAllSeen` keeps an old
  key only while its row is still known, so at some earlier open of the
  sheet the phone held no Ed posts at all, and every one of the 35 had
  been first stored at 15:05. Cause found the same evening: the
  course-material collector deleted Ed posts and saved before Ed put them
  back (see the trap "Ed posts that 'vanish'"), plus a failed `/tabs`
  lookup counting as "no Ed". Both fixed on `fix/ed-posts-durable`, merged
  into `fix/megaphone-every-class`. **First evidence on a phone, 2026-10-23
  18:22:** the previous build's 17:57 run on Marco's phone failed its
  manifest and its whole Ed read (first failure `other · couldn't read ed account: cancelled`), and the
  status line read `restored 6 · dropped 0`; all 35 Ed posts were still on
  disk afterwards, where the old code would have deleted them. Still in
  3.1.0 (13) itself until 3.2.0 ships.
- **`extract-announcement` returned HTTP 502** on Marco's phone at 15:04
  on 2026-10-23, for PHYS 0151's "Midterm 2 information with formula
  sheet added" (posted 10-16). That was its second failure
  (`announcementExtractionAttemptsV1`); a third makes the app give up on
  the post for good, so no task is ever found in it. The run's back-off
  also skipped the Ed task pass for the hour. The function's log was not
  read (no Supabase token on the dev Mac). Probable cause: a thinking
  model spending its whole token cap on reasoning and answering with no
  content; fixed in code on `fix/megaphone-every-class` (`36e3aee`),
  **not deployed**.

- **Automatic PennKey capture: compiled (2885/260 green in PR #13), and
  Marco reports a working PennKey + Duo login through it on his phone
  (2026-10-23, on his own tree, build not recorded); the merged tree,
  where it meets the launch-refresh rework, has not been watched on a
  device until 18:22 that evening, when the 3.2.0 (14) Debug build of the
  merged tree ran on Marco's phone: no crash, Canvas sync alive (20
  announcements), Ed task pass and course-material sync ran.** (Merged on
  `v8-merge-marco` from `codex/automatic-canvas-login`.) Still unseen on
  the merged tree: a
  real PennKey + Duo sign-in through the capture, a password manager's
  autofill (whether its submit reaches `PennKeyLoginCapture`), the
  pre-login disclosure line, the "Canvas connected" page, and a later
  silent renewal with the saved pair (verify with `-LHFAgeCanvasSession`).
  `docs/appstore/REVIEW_NOTES.md` and `DEMO_VIDEO.md` were rewritten on
  2026-10-23 to say the app saves the password itself; the App Store
  privacy label still has to be re-read against that before the next
  submission, and `docs/PRIVACY.md` (Marco's rewrite) is the student-facing
  text. `OnboardingView.canvasStep` no longer short-circuits to a
  "connected" page when Canvas is already connected, so a walk that lands
  on the Canvas phase again re-mounts the login pane (the back chevron from
  Gradescope goes to the new connected phase instead). From the read-only
  review of the merged tree (2026-10-23), accepted and unfixed: (1)
  `PennKeyCredentialStore.save` now does `SecItemUpdate` with
  `kSecAttrAccessible` among the update attributes; if the macOS legacy
  file keychain under `swift test` rejects that, the second save in
  `StayLoggedInTests` ("re-entering a password clears a prior rejection",
  the awaiting-Duo tests) returns false, and the fix is to update only
  `kSecValueData` (iOS is fine either way). (2) The missing-login banner's
  one-time legacy inference (`AppState.swift`, `resolveCanvasLoginEverCaptured`)
  can misread an old install: one that took the old vault offer,
  disconnected on an old build and then pasted a calendar link reads
  "captured" and gets a reconnect banner it cannot satisfy; fresh installs
  write the flag explicitly and are fine. (3) `canvasLoginIsMissing` reads
  the Keychain, which returns nothing before first unlock, so a background
  wake in that window reads "login missing", attempts a renewal and burns
  the hour's cooldown; skip the rule when protected data is unavailable.
  (4) Marco's new copy ("Canvas connected", "Disconnect at any time in
  Settings", the disclosure line) is capitalised and says "Settings" where
  the app says Profile; the copy rule is Marco's own, so it is his to
  settle, not rewritten here.
- **Website crawls were retired by a phone that had not downloaded
  them yet** (seen 2026-10-26, ECON 0100: five `website` rows fetched at
  14:33 UTC and marked gone at 14:54 by a classmate's phone sync), because
  crawled rows took the column's default, `collector = 'phone'`. Fixed
  2026-10-27 at Olisa's go: migration `20261027150000_server_collector.sql`
  (the `'server'` value; the 8 existing website rows restamped),
  `discover-websites` v5 stamps its rows `'server'`, and `sync` v14 never
  lets a client report retire one (`selectLiveDocumentIDsForCourse`,
  `liveIDsRetirableBy`); the crawl retires its own pages. Checked live the
  same day with a throwaway user: a phone's empty complete-set report
  retired the course's phone page and left the server row live, and
  every row it made was deleted after. A real crawl writing `'server'`
  has not been seen yet.
- **Canvas Files reach the extension through `public_url`, not the
  download link** (2026-10-27, not yet seen on the owner's laptop). Until
  then only one course's 53 PDFs arrived: `files.js` fetched
  `/files/:id/download` with credentials, Canvas redirected to a signed
  URL on `instructure-uploads.s3.amazonaws.com`, and that bucket answers
  `Access-Control-Allow-Origin: *`, which Chrome refuses for a request
  carrying credentials (seen in the extension's error panel). Now each
  file costs one Canvas call, `/api/v1/files/:id/public_url`, and the
  returned signed URL is fetched with `credentials: "omit"`. Rejected: a
  host permission for the bucket (shown at install, and cookies there do
  nothing) and keeping credentials through the redirect. The signed URL is
  a bearer link for hours and is never logged or stored. **The fix works**:
  the owner's next run (2026-10-27 12:49 UTC) extracted 50 PDFs, 16 empty
  (scans with no text layer), none failed. It then uploaded nothing,
  because one PDF's text held NUL characters and the server's `sync` answered
  the whole batch with a 500 (next entry).
- **One NUL in one document fails a whole `sync` upload batch** (seen
  2026-10-27 12:57 UTC: `sync error: unexpected [object Object]`, then
  Postgres's `unsupported Unicode escape sequence`). Postgres text cannot
  hold `\u0000` or a lone surrogate, and `validateDocuments` does not
  checked for either, so the error surfaced at the upsert and was not a
  per-document `rejected` entry. Fixed on both sides: the extension cleans
  every document's title and text before hashing (`storableText` in
  `chrome-extension/src/core/canvasDocuments.js`), and since `sync` v13
  (2026-10-27) the server cleans title, course, url and text in
  `validateDocument` (`storableText` in `_shared/manifest.ts`; a document
  that is nothing but NULs is a `rejected` entry), which covers the phone's
  PDF syllabus text too. Seen live the same day: a throwaway user's upload
  of `"a\u0000b \ud800c"` was stored as `"ab \ufffdc"`, and every row it
  made was deleted after. The client's hash is kept as sent, so a phone
  that hashed the dirty text does not re-upload in a loop.
- **PDFs linked from a course's own pages now reach the extension**
  (2026-10-27, not yet run against real Canvas). Most Penn courses hide
  the Files tab, so the Files listing answers 401/403 and only "Physics
  Exam Archive" ever yielded PDFs, while the server held 58 CIS 4500, 17
  PHYS 0151 and 10 ACCT 1010 documents linking them. `collectFiles` now
  also takes the file ids in that course's page, assignment and syllabus
  links (`canvasFileIDsFromLinks`) and File module items, looks each up
  with `/api/v1/courses/:c/files/:id`, and sends PDFs down the same
  `public_url` path; a non-PDF is remembered (`seen[id] = "not-pdf"`) so
  it is not looked up every run, and lookups are capped at twice the
  60-file cap per course. **It works**: the owner's run of 2026-10-27
  (about 14:15 UTC) uploaded 47 PDFs, PHYS 0151's 16 and MATH 1400's 13
  among them (both had none before), from 92 linked lookups with none
  refused; 19 failed and CIS 4500 and ACCT 1010 still have none. The
  likely cause, fixed the same hour and not yet seen live: a page linking
  a file that lives in another course's site, which the course-scoped
  lookup answers with a 404, so a non-OK answer is now asked again as
  `/api/v1/files/:id` and the document links `/files/<id>`. The summary's
  `files` now also says `linkedMissing` (not found either way) and
  `unparseable` (pdf.js could not read it), so the next run tells which.
  It did (2026-10-27, about 17:00 UTC): 186 linked ids, 23 missing both
  ways, 3 refused, 0 unparseable, nothing new to extract. So the earlier
  failures were files Canvas no longer serves to students (deleted or
  unpublished), not a wrong lookup, and CIS 4500 and ACCT 1010 hold no
  PDF the student can open through Canvas; their text carries no
  `http…pdf` link either. Their material, if it exists, lives on an
  outside site, which is the server's website crawl, not the extension.
- **The Chrome extension's Swift half compiled green on 2026-10-23 (2606/237) but has not run on a phone** (written 2026-10-22,
  written in the cloud container with no toolchain): the `file` document
  kind, `client` and `acceptsKinds` on the sync requests and the lossy
  `download` decode (`BackendWire.swift`, 11 tests), and the sync snapshot
  codec and merge (`Sync/`, 16 tests, among them the shared AES-GCM
  vector), and the pairing and sync layer (`Sync/PairingLink`,
  `SyncChangeLog`, `SyncSnapshotBuilder`, `SyncApplyPlan`,
  `LowHangingFruitUI/DeviceSyncClient`, `SyncKeyStore`; 50 test
  functions, 69 cases with the parameterized one expanded), and the app
  wiring (`AppState+DeviceSync.swift`, `PairLaptopSheet.swift`, the
  `smooth` URL scheme in `project.yml` and `App/Info.plist`, tap hooks in
  `AppState`, the pass in `ContentView.refresh()` and at launch, the
  laptop row in Profile; 13 tests in `DeviceSyncWiringTests`). Predicted:
  **2512 + 63 test functions**; trust the Mac's count, not this one.
  An independent read of all of it (2026-10-22) found nothing that should
  fail to compile and one test that would fail (`profileRow`'s order
  check: a section's header closure follows its rows in the source),
  fixed; `canonicalJSON()` was split into typed lets so the type-checker
  is not handed one literal with three closures.
  `swift test --no-parallel` on the Mac is the first gate; a different
  count or a red vector test means the phone and the extension disagree.
  `SyncSnapshot` uses a hand-written JSON serializer and UTC date
  formatter on purpose (key order and `Sendable`), so read a failure there
  as a real disagreement, not flakiness.
- **The Berserk alarm has rung once, on Marco's iPhone (iOS 26.6,
  2026-10-19, a build from before the review fixes).** The first try did
  not ring because alarms were not allowed for Smooth; after he allowed
  them, it rang. The review-fixed build with the song rang the same day,
  so AlarmKit does find a sound in the main bundle on 26.6; the owner:
  "this is perfect for berserk mode". Then on Olisa's iPhone on
  2026-10-20 (the merged build, 2397/214): it rang full screen on the lock
  screen, the song played once (it does not loop), and "turned in" marked
  the card done after unlock. Still unverified,
  and not answerable from the SDK: the Live Activity of 2026-10-20
  (`LHFWidget/BerserkAlarmActivity.swift`, blind: whether the system
  shows it for an alert-only alarm at all, whether the card appears on
  the lock screen beside the full-screen alert or only in the Dynamic
  Island, and whether `AlarmAttributes.metadata` decodes in the extension);
  the takeover screen of the same day (seen working once on Olisa's phone
  at 11:25, "the island showed the tomato card, takeover worked"; not
  recorded: which road in, whether the lock-screen card appears beside
  the full-screen alert, whether `alarmUpdates` raised it with the app
  already open, and which of the three buttons were tried; two limits
  known from the review, both accepted: a sheet the dashboard has open (add, edit date,
  the megaphone) draws above the takeover, which is an `.overlay` on the
  root and not a presentation, so a signal that lands with a sheet up is
  only seen once the sheet closes; the extension's `import AlarmKit` IS
  weak-linked: `otool -L` on the 3.1.0 (13) Release archive's
  `LHFWidgetExtension.appex` printed `AlarmKit.framework ... weak` on
  2026-10-20, so the Home Screen widget loads on iOS 17–25);
  the system "Stop" button (it opens the assignment in Canvas; Olisa has
  not reported trying it); what `schedule(id:)` does with an id that already exists
  and whether `cancel(id:)` throws for one that is gone; that both
  buttons work from the lock screen with `.foreground(.immediate)`;
  whether stop runs on swipe or the side button; whether the lock screen
  shows the due time next to the bare assignment name; and a launch on
  iOS 17–25 (AlarmKit is weak-linked in the Debug build and, checked with
  `otool -L` on 2026-10-20, in the 3.1.0 Release archive of both the app's
  widget extension and, by the same linker setting, the app; a launch on
  such a device is still untried). Disconnecting Canvas does not cancel alarms until
  the next reschedule, so leaving the app straight from Settings can let
  one ring for purged work (the buzzes have the same gap).
- **The loud alert's buttons are proven on the Mac only** (2026-10-19,
  `v8-loud-alert-actions`). Unverified on a device: that a lock-screen
  "turned in" stops buzzes 2 and 3 in time, that a tap which
  cold-launches a force-quit app reaches the dashboard, and that
  `openURL` from a cold launch is honoured (iOS may ignore an open
  issued before the scene is active). Two limits by design: a "turned in"
  for an item the dashboard no longer lists only silences and re-plans,
  it completes nothing; and the alert still fires for work handed in while the app was
  closed, because only a foreground refresh re-plans it (the background
  wake is off limits).
- **Turned-in state: what the 2026-10-18 review left open** (read from
  the code on `fix/submission-status`; none of it seen on a phone).
  Owner answers still unknown: whether Marco signed in to Canvas again
  after 2026-10-10, where the prelab was handed in, and whether his phone
  shows "not saving on this phone".
  - **Cold launch on iOS.** No Canvas or Gradescope status is fetched
    until the first activation or the first 5-minute tick
    (`ContentView.refresh`; its own comment says `onChange(of:
    scenePhase)` skips the initial phase). The ledger seeds what was last
    seen, so only submissions since the last refresh read late. Fixed
    blind on 2026-10-23 (`launch-refresh-rework`, in the Marco merge): the
    launch pass waits for any silent renewal `init` started, then runs the
    chain once, without the notice drains. Marco's
    `parked/launch-submission-refresh` was the source and was not merged
    as written, because on `v8` it would also have run `deviceSyncPass`
    and the turned-in and grade notices at launch. Not yet on a phone.
  - **A flaky Gradescope detail page** turns a submitted row back to not
    done until the next good scrape (`refineCompletionStatus` swallows the
    error; `StoredAssignment` copies the flag on every reconcile). Fix
    on `parked/gradescope-unverified-submission`, merged into
    `v8-merge-marco` on 2026-10-23 (not compiled).
  - **Gradescope disconnects itself for good** after 24 hours without a
    successful sync, silently (Traps). In `AutoSyncCoordinator`, not
    touched.
  - **Reminders and the loud 10-minute alert fire for work handed in while
    the app is closed.** Only a foreground `refresh()` or a swipe re-plans
    them (`NotificationScheduler.reschedule` cancels and re-adds
    everything); `LHFBackgroundRefresh.run()` posts "turned in" notices but
    never reschedules, and the silent-renewal refetch
    (`performSilentCanvasRenewal`) doesn't either. Background code is off
    limits. **Bit Marco on 2026-11-03** (a reminder fifteen minutes after
    he submitted): the fix is planned in
    `docs/REMINDER_SUBMISSION_FIX_SESSION_PROMPT.md` (`ROADMAP.md` → Now);
    `LHFBackgroundRefresh.run()` does replan since the hardening work,
    unverified on a phone, and hits the same 15-minute throttle.
  - **Canvas partial failure.** When one site of a class fails and another
    succeeds, the 15-minute throttle arms for both and the failed one keeps
    its old snapshot (`GradeWatcherStore` `fetchedAny`).
  - **Conservative misses, left alone:** `excused` is never read; an
    external-tool assignment graded by passback with no `submitted_at`
    reads not submitted; a teacher's "missing" outranks a real
    `submitted_at`.
  - **A module row matched only by title** is written `canvasSubmitted`
    but restored as not done at relaunch until the next fetch
    (`AssignmentStore.submittedCanvasAssignmentIDs` reads only
    `canvasAssignmentID`).
  - **Un-ticking does not stick when a hidden twin is ticked**: the twin
    re-carries onto the card on the next rebuild (`carryCompletion`;
    `markActive` clears only the card's own id and `linkedID`).
  - **Submissions don't carry to a displaced twin.** An undated Canvas or
    Gradescope exam hidden behind a dated syllabus or announcement card
    loses its submitted state; `carryCompletion` moves swipes only.
  - **Canvas↔Gradescope fuzzy pairing** can join "Lab 3" with "Lab 3
    Report" (0.667 within 26 hours), so one side's submission marks the
    other done. "HW 5 Part A" / "Part B" sit right at 0.6.
  - **Ticks carried by the old module collapse** before 2026-10-18 stay on
    the calendar row; the ledger cannot tell a carried tick from a swipe.
  - **Is the ledger on disk?** A 2026-10-18 `devicectl` listing of the App
    Group showed no `Assignments.store`, which lives at the container root
    (`AssignmentStore.makeDefault`). With the plist present and the store
    absent, the app is on its in-memory fallback and shows "not saving on
    this phone"; a failed listing (CoreDeviceError 7000) proves neither.
    Settle it on the phone before trusting any completion fix.
- **A failed Canvas announcement read is retried on every sync.** Only the
  Ed pass waits (`edTaskRetryInterval`, six hours, per post). A Canvas
  post whose AI-assist call fails is left unread and asked for again on
  each 5-minute sync, which spends the backend quota `ask` shares. Not
  fixed: the review asked for Ed only.
- **A fetch that is cut short the same way twice is believed.** The
  two-miss rule (`announcementMissesToFlag`) and "a class that returned
  nothing is not judged" stop a one-off truncation, not a deterministic
  one (`CanvasAnnouncementsClient` caps at 50 pages). The flag is
  reversible and the row is never deleted, which is what makes that safe
  enough.
- **Exam cards have been tested on the Mac only** (2026-10-18; compiled
  for the connected phone, never installed). Never read against a real
  syllabus: the extractor, the 60-day and one-day matching rules and the
  year it picks for a date with no year are proven on fixtures. Known
  edges, none of them fixed:
  - A syllabus that stops naming an exam leaves its card. Rewriting the
    line updates it (the id is the exam's identity), but an edit that both
    renames the exam ("Midterm" to "Midterm 1") and moves its date leaves
    the old row beside the new one. Deleting on absence was refused on
    purpose: a failed sync drops whole courses from the material.
  - A title like "Bring a calculator to the exam" is not treated as an
    exam (`leadingExamIdentity`), but is still drawn black, because the
    card's colour only asks whether an exam is named.
  - Syllabus rows join the work list in the ask context document with the
    source label "announcement" (`assistantSourceLabel`; a disclosure
    boundary, left alone).
  - Server exam dates have never been watched against the live `sync`;
    their backend half is deployed (the `sync` at version 17, 2026-11-05,
    was built from `v10`, which contains `v8`). The extraction prompt gives the model no
    current date or term, so a syllabus line with no year gets the model's
    guess of the year. The 150-day cut-off drops a past-year guess, and a
    phone reading backed by a matching weekday beats a wrong guess, but a
    wrong-year guess on a line with no weekday still beats the phone's
    reading: nothing in the line says which year is right.
- **The summary sent with every ask question carries completion state,
  and `docs/PRIVACY.md` says it does not.** Read on 2026-10-10 while
  checking something else; it has been so since `assistant-ui`
  (2026-09-02/06). `AssistantContextDocument.render` writes each work
  item as `course | title | due … | done / nothing to submit /
  outstanding | source`, and `assistantContextDocument()` fills
  `isCompleted` from the student's real completion state. The policy
  says, three times, that completions never leave the phone, and that
  the summary is "built without your name, grades, or completion state";
  the privacy posture at the top of this file says the work list never
  leaves either, and the document is the work list (feed items; manual
  tasks are not in it). Nothing was changed: taking the status out makes
  "what am I missing?" worse and re-bills the cached prefix once, and
  changing the sentence changes a published promise. It is Marco's and
  Olisa's decision, and it should be made before the next release.
- **The launch-prep work is mostly unseen on a device** (`v8-launch-prep`,
  2026-10-10). Marco's phone took builds up to `b5ed8a1` (links,
  10-minute reminder, reminder wording, the first announcements list and
  its window fix) and was then unplugged. Everything after that is
  compiled for iOS and tested on the Mac only: the Settings and banner
  copy, the Ed rows in the megaphone, ask's changes, saved due-date
  edits, deleting your own tasks, the widget, the "not saving" banner,
  the under-an-hour "8m" form. The sign-up rule can only be seen on a
  fresh install.
- **ask's Canvas announcements are blind** (2026-10-23, `9540751`,
  `docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md` Phase 1): until then the
  collector asked Canvas for announcements from 200 days back without an
  `until`, and Canvas ends the window 28 days after it starts (the
  announcements-window trap), so no term's announcement ever reached ask
  (the pool held nine spring posts from one class on 2026-10-23). Now
  120 days back through tomorrow, the document text is the message alone
  (no device-zone `Posted:` line, so every phone and the extension hash
  a post the same), an untitled or empty post never reaches the server,
  a failed announcements request no longer lets a course count as fully
  synced, and `courseKnowledgeSyncVersion` is 5. Compiled green on
  2026-10-23 (2606/237), not yet on a phone; the new `CourseKnowledgeCollectorAnnouncementTests` drive
  the collector through a `URLProtocol` stub whose other routes answer
  `[]`, which no one has seen every sub-client accept. The backend half
  (Phase 2, Deno 419/0) is on `v8` and went live with the `sync` at
  version 17 on 2026-11-05 (built from `v10`, which contains `v8`), but
  nobody has watched a phone retire classmates' announcements through it
  yet (the collector no longer reports the
  course fully synced), but the 1000-row manifest cap and the batch-wide
  rejection remain live. `sync` v12 went live at about 16:00 UTC the same
  day. **Seen working on Olisa's iPhone at 18:09 UTC the same day**: the
  build's first course-material sync uploaded 63 announcements from this
  term (LGST 1010 27, PHYS 0151 20 across its two sites, ACCT 1010 16;
  the CIS classes post on Ed, not Canvas) with no `Posted:` line, no
  empty or untitled document and 63 distinct hashes, and 36 Ed posts with
  the posting-day header. The full-sync stamps did not move, correctly:
  the manifest called every course fresh from the 17:29 run, so only the
  announcements and Ed ran. Note the launch gap: nothing at launch runs
  the Canvas chain; the dashboard's loop sleeps 5 minutes before its
  first refresh and the root view's launch sync is the feed only, so a
  phone that locks inside those 5 minutes syncs only on its next return
  to the foreground (pre-existing, every build). Whether the tree
  answers from the new posts is the next check. This touched the
  course-material sync at the owner's direct request; Marco has not been
  told yet.
- **The recording fixes, on a phone 2026-11-02: the class-meeting half
  passes; the history half is proven on the canary (2026-11-05), not yet
  on a phone.** On Marco's iPhone 17 Pro
  (`v8` `d434db8` Debug, `ask` v13) "Do I not have cis 2620 class
  today?" led with the quiz from the 2026-11-01 Ed post (the recording's
  failure, answering from the schedule, is gone); whether the chip showed
  is not reported. The follow-up question was not asked, so whether
  `history` reaches the server with the earlier turn is known only from
  tests. To check it: read the `history` field of the request from a
  DEBUG build, or run `ask-probe.mjs` with a `history` pair against
  `ask-canary` (needs `LHF_PROBE_SECRET`, which Olisa holds). **Done on
  2026-11-05 from the GitHub runner** (the `ask-probe` workflow, `history`
  set, 10 runs): with the recording's wrong schedule answer sent as the
  earlier turn, all 10 replies to "you should've said that in my original
  question" answered the original question from the Nov 1 post and none
  was confused, so the server reads `history`; what the phone sends is
  what `ConversationHistoryTests` pins and has still not been read off a
  device. The evening "what's due tomorrow" check has not been done yet
  (the phone test ran at 13:12 Eastern). Marco's verdict on the same build: recency is still
  not prioritised by the question's time frame; the research for that is
  `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`.
- **ask tells the model every date in UTC and never says so** (read
  2026-10-24, `docs/TREE_IMPROVEMENT_PLAN.md` item 1). The context
  document renders due times as `…T03:59:00Z` and the user message's
  `Current date:` is a UTC instant, so an 11:59 pm Eastern deadline is the
  next calendar day to the model and from 8 pm Eastern "today" is already
  tomorrow. UTC was chosen for the byte-stable prefix, which a fixed
  per-student zone keeps just as well. **Fixed on 2026-10-25**
  (zone-aware due times in the document, the local-date line at the top
  of the excerpts block; compiled green on 2026-10-27, 2933/264):  an evening "what's due tomorrow" on the phone are the
  checks. Before the fix the on-device answerer, which uses the device
  calendar, was the only path that got the day right.
- **The phone's `discover-websites` call fails whenever more than three
  courses are pending** (read 2026-10-24, plan item 2).
  `AppState+CourseKnowledge.swift` sends the whole `websitesPending` list
  in one call, the server refuses more than three ids with a 400, and the
  `try?` swallows it, so a student in four CIS classes never triggers a
  crawl. On 2026-10-24 `course_websites` held 213 candidates, 3 verified
  and no row ever crawled; CIS 2400 and CIS 2620 have nothing in the pool
  but Ed posts because their syllabi live on external sites. The extension
  chunks by three and is the only caller that ever has. **Fixed on
  2026-10-25** (`WebsiteDiscoveryBatches`, one call per three distinct
  ids, 3 tests; compiled green 2026-10-27, 2933/264, not yet on a phone): after the build is on a phone and one sync has run,
  `course_websites` should show `verified` rows and a `last_crawled_at`
  for the CIS courses; if candidates stay candidates, the next suspects
  are the verification rule (code and term in the first 3,000 characters)
  and the convention guesser (no `github.io`), plan item 2's server half.
- **ask reads only the PDFs linked from assignment descriptions, not
  Canvas Files at large.** Assignment-linked PDFs are pooled by the phone
  since 2026-11-10 (blind, never run against real Canvas; open question:
  PDFKit text, first 20 pages, against the extension's pdf.js text for the
  same file, so the two collectors' hashes can differ). Module files, the
  Files tab and non-PDF types (slides, docs) still are not ingested by the
  phone; only the 40 most recently updated pages get their bodies; module
  items contribute titles only. The extension fills some of the rest in.
- **A half-failed course-material sync no longer erases documents, and
  a 403 is one course's problem** (2026-10-23, `course-sync-salvage`,
  blind, ported from Marco's `parked/ask-course-sync-fixes` without its
  page-body work). Any endpoint error, or the shared announcements call
  failing, puts a course in `Report.partialCourseIDs`: its stored
  documents the run did not re-fetch are kept and it is not reported
  fully synced, so neither the phone's merge nor the server's complete-set
  rule drops them; `usableCourses` (at most one own error) feeds the
  "couldn't read course materials" notice so one bad endpoint does not
  read as a dead sync; the summary line gains `partial P`. Only 401 is
  `sessionExpired` now; a 403 on one course's assignments leaves that
  course partial and the run continues to `store.save`. Known edge, kept
  on purpose: a course with one endpoint that always fails (a Pages tab
  turned off, or a concluded course now answering 403 instead of reading
  as a sign-out) is partial forever, never stamped fully synced on the
  server, and re-fetched from Canvas hourly; its stale documents are never
  pruned. The old `<= 1` tolerance hid that at the price of retiring
  classmates' documents. Canvas sometimes answers a forbidden course with
  401, which this does not cover. The server-side half (paginating the live read) was done
  in `sync` v12 the same day. Six tests, written against a `URLProtocol`
  stub nobody has run.
- **The Ed reader fixes of 2026-10-23 compiled green (2606/237) but have not run on a phone** (`docs/ANNOUNCEMENTS_FOR_ASK_PLAN.md`
  Phase 3, at the owner's direction; the Kit half rode in `9540751`, the
  coordinator in the commit after it). `EdThreadFilter` now drops an
  anonymous thread before the announcement and pinned rules, which makes
  `docs/PRIVACY.md`'s promise true (a missing `is_anonymous` still
  decodes as false, so the promise rests on Ed sending the field, which
  it does today; flipping that default is the owner's call). The read
  pages up to three pages of 100 until the window closes
  (`EdClient.threadsWithinWindow`), so a pinned post beyond the 100th
  newest thread no longer vanishes. A sign-out partway through a run
  restores the unread classes' documents instead of dropping them (every
  match is resolved before any read, so `drop` is only "no Ed match").
  The Ed status line now leads with counts (`matched · read · restored ·
  dropped · first failure`), which is how to find out why CIS 3990's
  posts carry no posting day (ten of its rows on the server predate the
  header's date, so no read of that class has completed since
  2026-10-19). Ran on Olisa's iPhone at 18:09 UTC the same day: 36 Ed
  posts re-read for CIS 2400 and CIS 4500, each with the posting-day
  header. Found in review the same afternoon and fixed blind the same
  evening (`ed-tabs-restore`): a class whose Ed `/tabs` lookup fails is
  "unknown", not "no Ed", so `restoreDropPlan(unknown:storedEd:)` restores
  its stored posts instead of dropping them (three tests in
  `EdRunStopTests`, and `EdRestoreDropPlanTests`). Narrower than it
  sounded: matching is by course code, so the only class this protects is
  one whose code matches no Ed course while its tab request fails; before,
  that run dropped its posts until the next successful lookup. The same
  fix was written a second time that evening on `fix/ed-posts-durable`
  (PR #13), and Olisa's version was kept when the two met (2026-10-23
  late): the rules agree, and his does not count a class with nothing
  stored as restored. The bigger cause of vanishing Ed posts, the
  collector deleting them (the "vanish" trap), is PR #13's and is not in
  `ed-tabs-restore`. Still true:
  pooled Ed posts are downloaded and dropped again every sync on a phone
  whose class has no Ed match, and staff answers inside student questions
  are never captured (no endpoint).
- **A deleted announcement stays in the megaphone until it ages out**
  (since 2026-10-18 its task cards are hidden, for Canvas posts only; the
  list row is not). An Ed post that is deleted is not noticed at all: an
  Ed read replaces a class's documents with its newest 100 threads and a
  failed run drops the classes it had not reached, so a document missing
  from `courseKnowledge` is weak evidence of deletion, and hiding on it
  would hide real tasks. Fixing it means a trustworthy "this read
  completed" signal from the Ed coordinator, which is off limits to this
  line of work. An Ed row's date was the thread's last activity, so a
  bumped old pinned post read as recent; since 2026-10-19 the posting day
  in the document's header is the date (`edPostDate`, for the rows, the
  window and the 7-day lifetime), and the last-activity time remains only
  for a document synced before that (until its thread is fetched again),
  where a Sept 14 thread somebody replied to on Oct 15 can still be
  extracted. Both are blind. The day is noon US Eastern, not a minute.
- **The freeze fix of 2026-10-20 compiled green (2414/217) but has not
  been felt on the phone** (the stored badge, the static regexes, the
  identity buckets, the coalesced reload; see the trap). Whether it cures the lag on the
  owner's phone is unknown: no profile was taken before the change, so
  if the lag persists, take one (`xcrun xctrace record --template 'Time
  Profiler'`) before guessing again. `announcementAssignmentsOnDashboard(for:)`
  still parses the configured course keys per announcement item.
- **The "what's new" excerpt rule has not been asked on a phone**
  (`RecencyIntent`, `AskRecencyExcerptTests`, 2026-10-20): written in the
  cloud container, compiled green on Olisa's Mac the same day (2409/216),
  after the owner showed the tree naming Oct 7 as the newest CIS 2620 Ed
  post on Oct 20. Ask the same two questions on the phone. The "today" window is a day back from the asking moment, and Ed
  posting days are stamped noon Eastern, so "today" can include
  yesterday's post.
- **ask and the widget after the 2026-10-20 merge (blind).** ask's work
  pool now drops what the dashboard hides (`announcementItemsStillOpen`),
  asked of the feed date, so a task the student moved into the future is
  gone from ask once its feed date passes. The widget's ledger fallback
  keeps only the dated half of the rule. A find that passes while the app
  is closed stays in the published widget snapshot until the app next
  republishes.
- **The merge of 2026-10-20 compiled green (2397/214) and built to Olisa's iPhone the same morning, but none of its behaviour has been checked on the phone yet.** It was Written on a
  machine with no Swift toolchain, from re-reading: the conflicts in
  `AppState.swift` (and the `SettingsPage.swift` rows git merged into the
  wrong place, see Traps), the removal of `edAnnouncementsForExtraction`,
  the rewrite of the tests that used it, and `EdAnnouncementTaskMergeTests`.
  Expect compile errors before anything else, and run the first full
  `swift test --no-parallel` alone on the machine.
- **Ed finds from the Canvas loop's one day are inert, not gone.** On a
  phone that ran the 2026-10-19 build, `announcement-ed:{course}:{thread}-{n}`
  rows sit in the ledger as `.canvasAnnouncement` rows of Canvas origin.
  Their processed ids (`ed:{course}:{thread}`) are the ones Marco's pass
  uses, so nothing is read twice and they expire by the ordinary rule; a
  duplicate card is possible only if the same task also arrives by the Ed
  pass with a different title, and the dashboard's twin collapse catches
  the usual cases.
- **An edited due date lives in defaults, not the ledger** (see "What
  the app does" → Cards). It does not follow a row that later collapses
  into a twin, and the term cap, the sign-up rule and the overdue-Canvas
  hold still read the feed date.

- **Ed Discussion ingestion has not completed a sync on a device** (`v8`,
  2026-10-02, blind). The DEBUG "probe ed discussion" row settled the one
  real unknown on 2026-10-09 on Olisa's phone: the launch lands on Ed only
  once the Keychain's Canvas cookies are injected into the hidden WebView,
  and Ed's session is a `localStorage` token (`authToken`), not a cookie
  (a cookie-only `GET /api/user` is 401). The token path
  (`EdSessionTokenStore`, `EdAuth.token`) was wired, compiled and
  re-probed that day: `native whoAmI (token): status=200 courses=19`.
  The backend accepts kind `ed` since 2026-10-10 (migration
  `20261002090000_ed_kind.sql` applied through the Management API's
  `database/query`, `sync` version 7 deployed with
  `backend/scripts/deploy-function.mjs`; Node's fetch needs
  `NODE_USE_ENV_PROXY=1` in the cloud container or the proxy never
  injects the token). A full sync has since run on a device: Marco's
  phone, read on 2026-10-10 with a `v8-launch-prep` DEBUG build, held 27
  `ed` documents across two classes in `course-knowledge.json` (17 and
  10), one of those classes having no other documents at all. Nobody
  has yet checked those against what the two Ed boards show, and the Ed
  status line shows on a DEBUG build under the gradescope row in
  Profile → accounts (it left the normal page on 2026-10-10). The
  feature fails soft throughout: every error is a note in the sync trace
  and the Settings status line, never a thrown error.
- **Nothing has ever been tested against real Canvas or Gradescope data.**
  Every grade, submission and syllabus path is proven against fixtures
  only. This is the highest-value verification outstanding.
- **Stay signed in is proven in the foreground only.** A real PennKey and
  Duo renewed silently on two phones on 2026-09-27. If a student is ever
  signed out again, read `debugRenewalLogV1` off a DEBUG build before
  redesigning. App Store 3.0.0 users were signed out anyway; the
  investigation and the fix are `docs/SIGNOUT_INVESTIGATION.md` and the
  `v8` sign-out commit of 2026-10-09 (blind: Duo-preserving pre-login
  purge, reconnect straight to the Canvas login, background wakes
  un-crashed with a never-latch guard, foreground retries instead of a
  one-shot latch, a sign-in health line in Profile, Gradescope cookies
  re-stamped on sync), plus the second blind round of 2026-10-09 that a
  three-slice review of that commit forced (the background wake now waits
  for its renewal, see the trap below). None of it has run on a device;
  `docs/SIGNOUT_VERIFICATION.md` is the runbook. Known follow-ups, not
  blocking: a saved-password student whose session dies inside the
  six-hour credential cooldown gets GET-only retries whose landings count
  toward the latch; the live foreground `AppState` does not re-read the
  summary a background wake wrote until relaunch; `run()` reports
  `success: true` even when it skipped everything.
- **Background refresh crashed on every wake from 2026-08-24 to `v8`** (see
  the background-refresh trap, now historical). The `v8` fix has not been
  exercised on a device: verify with Xcode's Debug → Simulate Background
  Fetch on a DEBUG build and `debugRenewalLogV1`.
- **Stay signed in is fragile in 3.0.0 (11), the live build** (Marco's
  phone, 2026-10-08: the refresh banner sometimes clears by itself and
  sometimes stays). Three causes, the first proven on the device and the
  other two read from the code (`ROADMAP.md` → Now); the first is fixed
  on `fix/duplicate-category-ids` (2026-10-27, A3) but not yet run on a
  phone, the other two are not fixed:
  1. The 24-hour trigger is off on a phone with a saved analytics cookie
     (the trap above, and its fix at read time).
  2. Any silent attempt that fails to finish is recorded as "confirmed
     dead" and raises the banner: a network error (`SettleWaiter`'s
     `.failed` falls through to `.landedOnLoginPage`), the 30-second cap,
     or the app being left mid-attempt. The flag is persisted while the
     1-hour attempt cooldown and the 6-hour password-resubmission cooldown
     live in memory, so within one process a retry inside six hours of a
     password submission cannot fill the form again and is bound to fail;
     a relaunch resets both and retries properly.
  3. The banner is bound straight to `canvasSessionExpired`
     (`ContentView`), so when the 24-hour rule does trip it shows for the
     whole silent attempt; tapping it aborts that attempt and opens the
     login pane, whose pre-login purge includes `duosecurity` and so
     deletes Duo's remembered device. Marco also reports typing his
     password there by hand although one is saved; not yet reproduced.

  Since 2026-10-09 (`v8`, blind, never on a device): causes 2 and 3 are
  addressed by the sign-out fix above (a failed navigation is `.timedOut`
  and never a login landing, the attempt cooldowns are persisted and
  foreground retries replace the one-shot latch, the banner is hidden
  while a silent renewal is in flight, and the pre-login purge keeps
  Duo's cookie). Cause 1, the analytics cookie, is not fixed: the
  trap's own wrong-fix warning still stands and `load` still keeps a
  cookie by its own expiry (checked 2026-10-23).
- **Background refresh does nothing: it crashes on every wake** (see the
  background-refresh trap). Shipped that way in 3.0.0 (11) on purpose,
  because fixing it alone would switch on untested background re-logins.
  Fixed blind in `v8` on 2026-10-09 (the entry above and the trap); not
  yet seen on a device.
- **Non-Penn schools have only been exercised by tests.** The seven verified
  installations and the custom-address path have never been signed into on a
  device.
- **The `LedgerSchemaV1` migration has never opened a real pre-existing
  on-disk store.** v4 runs four migrations in one launch; the failure mode
  is a silent fallback to an empty ledger.
- **A non-persistent ledger is invisible.** If the App Group container is
  missing, `AssignmentStore` runs in memory and nothing on screen says so
  (see the App Group trap). Needs a small warning, somewhere a student
  would see it, whenever `assignmentStore.isPersistent` is false or saves
  are failing.
- **CloudKit sync is opt-in and default-off** (Profile → sync,
  docs/LAPTOP_INTEGRATION_PLAN.md Tier 2). The schema is CloudKit-eligible:
  every property on `StoredAssignment` carries a default, and every store
  pins `cloudKitDatabase: .none` unless the toggle was on at launch. The
  sync path has had little real-device soak time; treat it as Phase A.
- **The onboarding per-course walk** is covered by tests but has never been
  walked on a device (it needs a real Canvas session).
- **Recurring tasks can be stopped, not edited.** "stop repeating" on an
  opened occurrence removes the rule (2026-10-10); a task saved with the
  wrong title, time or class can still only be stopped and added again.
  A task saved without a class is filed under the class its title names
  (`RecurringTask.adoptingCourse`). Stopping an accepted syllabus
  suggestion removes it like any other, and the next Canvas scan offers
  it again: suggestions are kept in memory, not remembered once accepted.
- **A finished occurrence of a recurring task never shows in prev.**
  Completing one is recorded (a completion-only ledger row,
  `StoredAssignment.completionOnly`) and survives everything, but
  `DashboardViewModel.reload` builds prev from `mergedCoursework` plus
  the one-off tasks, and a generated occurrence is in neither. A
  student's weekly reading ticks vanish from view instead of counting
  toward "N down this week". Found 2026-10-10 while adding "stop
  repeating" and unchanged by it. Not fixed: it changes what prev shows.
- **Preview mode is App Review's only way in, and it was removed once.** The
  only sign-in at Penn is PennKey, which nobody outside Penn can be issued,
  so the "just exploring? preview with sample data" link on the intro's
  first pane (and again at the foot of the Connect Canvas step) is the whole
  of the reviewer's path. Apple's 2.1(a) note says a video is not enough and
  a "demonstration mode" is. It was removed at Olisa's instruction on
  2026-09-15 (3ace7f0), build 8 went up without it, and Apple rejected that
  build under 2.1(a) on 2026-09-16 (submission 067299d2…). The removal was
  reverted the same day for build 9. Do not remove it again, and do not
  gate it behind `#if DEBUG`: the DEBUG `-LHFDemoData` seam is a different
  thing (a launch argument compiled out of release, for
  `capture-screenshots.sh` and the demo video) and it does not help a
  reviewer.

## Overseer / doer split

You are acting as the overseer on this project, not the implementer.
Your job is to plan, delegate, and review — not to write code yourself.

### Division of labor
- All non-trivial file writes, edits, and command execution go through the
  `implementer` subagent. Trivial one-line fixes you spot while reviewing are
  fine to make yourself, but default to delegating.
- Use the `verifier` subagent for an independent check on anything
  security-sensitive, architecturally significant, or where you want a second
  opinion beyond your own review.
- You do the planning, task breakdown, delegation-brief writing,
  acceptance-criteria review, and integration decisions yourself.

### Model tiers and token economy
The overseer runs on the session's top model (Fable); doers are pinned
cheaper in `.claude/agents/` frontmatter — `implementer`/`verifier` on
Sonnet, `mechanic` on Haiku. A cloud session that starts on `main` does
not register those definitions (seen 2026-10-09: "Agent type 'verifier'
not found"); fall back to `general-purpose` with `model: "sonnet"` and
paste the role's rules into the brief. For built-in agents, pass the tier per call:
`model: "haiku"` for `Explore`/searches/surveys, `model: "sonnet"` for
anything with judgment in it. The top model never does bulk reading or
mechanical edits, and doers never make architecture calls.

Token discipline runs both directions:
- Briefs name files by `path:line`; never paste bodies the doer can read.
- Doer reports are a diff, verification results, and open questions —
  no narration, no restating the brief.
- The overseer reads targeted line ranges, not whole files, and sends
  independent agents in one batch.
- Delegation has overhead (~a few k tokens per spawn): a change smaller
  than its own brief is cheaper done directly — that, not laziness, is
  what the "trivial fixes yourself" allowance above is for.

### Before delegating
Break the request into the smallest tasks that can each be verified
independently. For each one, write a delegation brief that stands alone — the
subagent sees NONE of your conversation. Every brief must include:
1. The specific goal and exact scope (what NOT to touch, too).
2. Relevant file paths, current state, and any conventions to follow.
3. Concrete acceptance criteria — how you'll know it's done correctly.
4. What to report back (files changed, how it was verified, open questions).

### After a subagent reports back
Don't accept on trust. Before integrating:
1. Check the result against the acceptance criteria you gave it.
2. Spot-check the actual diff, not just the subagent's summary.
3. If it's wrong or incomplete, send a specific corrective follow-up to the
   same subagent rather than redoing the work yourself.
4. After two failed revision rounds on the same task, stop delegating it and
   say what's going wrong — don't keep looping silently.

### Working style
- Keep a running task list so the state of play is visible.
- Give short status updates between steps, not a transcript of every subagent
  exchange.
- If a task is ambiguous at the planning stage, ask before writing the
  delegation brief — don't pass ambiguity down and hope it guesses right.
- Flag anything security-sensitive, destructive, or architecture-changing for
  explicit sign-off before delegating it.

### The one rule that matters most here
**A change that has not been compiled is not done.** Say so plainly rather
than implying otherwise — from a subagent's report, or your own. Both of this
project's worst days came from resolved-but-uncompiled Swift being pushed.

## 3.4.0: onboarding, school search, swipe undo, AI presentation (2026-10-28)

Marco's PR #16 ("Simplify Canvas onboarding and add dashboard swipe
practice", eight commits on `origin/v8` `63125b6`) was folded into the
release on the afternoon of 2026-10-28, and the release was renamed from
3.3.1 (17) to **3.4.0 (17)** on `release/3.4.0`. It carries the two 3.3.1
crash fixes (duplicate Canvas grading-group ids at launch; the notification
tap) plus the work below. 3.3.1 was stamped but never uploaded; its Release
archive from earlier that day is superseded and must not go up.

**School search.** `SchoolSelectionView` searches 220 bundled US university
Canvas sites by name, campus and acronym, with bounded typo matching
(`CanvasSchoolCatalog` over the generated data, `CanvasSchoolDirectory` for
the manual fallback). The search runs on the phone: no search term or cookie
goes to the public Canvas directory. Typing a Canvas address still works.
The catalog's sources, public HTTP checks and known limits are in
`docs/canvas-directory/`; `scripts/generate-canvas-catalog.py` regenerates it.

**Practice lesson.** After Continue on the "Canvas connected" page of a full
first run, `CanvasCompletionGuide` shows a sample dashboard in two steps: swipe right on a card to complete it,
then tap it or swipe left in "prev" to bring it back. The undo lands
straight on the first feature card (lists); a "You've got it, tap Next"
pause sat between them until 2026-10-30, when the owner cut it because it
did nothing. The `.ready` end state is seen only while the first sync is
still running ("Almost there."). The fixtures live
inside the guide; nothing reaches `AppState` or the ledger, and the login
WebView stays mounted underneath. A failed sync returns to the retained
login view.

**Connect, then confirm.** Once the connect starts, a "Canvas connected"
confirmation (no progress dots; its button reads "Syncing Canvas…" and is
disabled) shows over the still-mounted login pane while the sync and the
credential save run. On success the walk moves to the "Canvas connected"
page, and Continue starts the practice lesson for a full first run
(`beginCanvasWalkthrough`); a Canvas-only reconnect completes directly. The
Sweeper "keep this on" note sits below its toggle now, not above it.

**Undo on Done cards.** `CompletionSwipe` gives `DoneCardView` a left swipe
that undoes a completion through the same persisted `markActive` path as
tapping. Vertical scrolling and short nudges do not trigger it. Either way
only Smooth's completion state changes, never a Canvas submission.

**Gradescope.** One screen, two buttons: "Continue with Canvas only" or "Add
Gradescope". The explanatory paragraph is gone, and so is the repeated "Canvas
is connected" label; the heading sits near the top with the buttons below.
Every preview label now reads "Preview", sits bottom-right, and hides under
the keyboard.

**Assistant.** The empty AI screen has no suggestion buttons and no top-left
logo. "What's due this week?" is placeholder text only; it never fills the
draft. The Smooth mark is the send control. A compact, non-interactive
geometric cluster (`SmoothFormShapes` in `SmoothFormChrome.swift`, the same
one Profile uses) sits top-right and hides while typing or reading a
conversation; the regular-weight rotating greeting is centred below it
(`AssistantView`, `AssistantPresentation`). The composer is rounded and
multiline, the greetings rotate only when idle (paused while typing or in a
conversation, off under Reduce Motion), and answer formatting keeps
paragraphs and source links and drops bold.
`backend/supabase/functions/_shared/prompt.ts` asks for shorter,
phone-readable answers without bold; live since `ask` v13 (2026-11-02,
from `dfb9d7f`, which carries it). `CanvasAppLink` makes assignment-card Canvas links try
the Canvas Student app (`canvas-courses://`, same host/course/item/query)
before falling back to HTTPS; other providers and macOS keep plain links.

**Chat history.** `AssistantHistoryStore` saves each conversation as its own
atomic JSON file under Application Support, `Smooth/ChatHistory/<canvas
host>` (iOS: complete file protection until first unlock), scoped by Canvas
host and never put in iCloud or the paired-laptop sync. Preview and demo
sessions (`isUsingFixtureData`) stay in memory. A top-right history icon
lists the saved chats; reopening one restores its messages and citations and
allows follow-ups, and "New chat" archives the current one. A streaming
answer checkpoints about every 0.75 s and saves on stop or exit; a request
id stops a cancelled stream from writing into a newly opened chat.
`AssistantMessage` and `AssistantCitation` are `Codable` for this.
`docs/PRIVACY.md` gained a "Chat history" bullet. Tests: `AssistantHistoryTests`.

**Sign-in detection: not taken.** The PR rewrote Canvas sign-in detection as
a JavaScript probe of `window.ENV.current_user_id` polled every 2 s and
deleted `CanvasConnectRetryRule`. That rewrite was not merged. v8's detection
(the host marker, `signedInRequiresForeignHost`, `CanvasConnectRetryRule`) is
restored verbatim, because the proven phone behaviour is the standard and the
rewrite was never verified with a live sign-in. "Stay signed in" (PennKey
credential capture, cookie renewal) is untouched. The author's later
"sign-in presentation polish" (hiding candidate Canvas pages before they
render while "authenticated ENV evidence" is checked, `isCheckingCanvasPage`
in `LoginNavigationObserver`) was dropped for the same reason: the sign-in
path is v8's, verbatim, so no ENV-evidence check and no page hiding exist in
this tree.

**Review notes from the 2026-10-28 verifier pass, to fix in 3.4.1 (none blocks
3.4.0).** (1) `AssistantView.init` builds the `AssistantHistoryStore` outside
the `StateObject` autoclosure, so its synchronous directory read and JSON
decode of every saved chat repeats each time `ContentView` re-renders while
Ask is open; SwiftUI keeps the first store, so it is a growing main-thread
hitch, not a bug. Move the construction back inside the autoclosure (the
conversation needs the same instance; give it a factory or let the
conversation own the store). (2) The first-run "Syncing Canvas…" overlay has
no X; it clears only on the pane's success or failure callbacks, which the
trace shows always fire, but on a dead network the student waits out the
60 s URLSession timeouts behind a disabled button. (3) The store's
`errorMessage` is never cleared once set. (4) Opening a saved chat re-saves
it and bumps `updatedAt`, so viewing reorders the list. (5) The empty
streaming placeholder is saved at once; a kill before the first token leaves
an empty answer row. (6) `AssistantSavedChat` has no schema version; a
non-optional field added later makes old chats undecodable. (7) "Add
Gradescope" has no back to the choice screen, only Skip.

DEBUG review flags: `-LHFFullOnboardingReview` replays the full first run
in memory for that launch without touching the saved connections,
`-LHFSkipIntro` (with it) skips the three-beat intro so the school search is
the first screen, and `-LHFCompletionGuideHarness` opens the practice lesson
directly. None of them touches the update wall.

Validation. The PR reported 3,388 tests / 324 suites and a device install of
the lesson, not a live sign-in; those are the author's claims, not this
tree's. Marco's live PennKey sign-in on his phone and the Canvas app hand-off
on a device are still owed (`ROADMAP.md`); the backend deploy happened on
2026-11-02 (`ask` v13).
GATES ON THE MERGED TREE (2026-10-28, 18:30–19:00 UTC, Marco's Mac, PR #16's final
head 80079f0 plus the sign-in restoration): `swift test --no-parallel` 3399 tests /
327 suites (+3 tests, +1 suite over the 9082182 run: `AssistantHistoryTests`), all
passing except the one deliberate `withKnownIssue` in `EdFilterParityTests` that v8
has too (SEC-10, Olisa's extension), and one wall-clock fuzz test
(`FuzzTests.hostileHTML`) that recorded 200–400 s "durations" because the Mac went
into clamshell sleep from 14:33 to 14:44 local during the run; its code is untouched
since v8 and it passed alone on the idle machine afterwards (24 s, budget 60 s;
under a concurrent xcodebuild one case ran 6.3 s against a 5 s budget, so it is
load-sensitive, not a regression). Deno 614 tests passed and `deno task check` green.
The signed iOS Debug build (`generic/platform=iOS`, `-allowProvisioningUpdates`, team
24A3TDB277) succeeded and the product reads 3.4.0 (17), widget included; the phone
was off the cable at the time, so the install waits for it.
