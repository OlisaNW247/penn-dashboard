# Prompt: build Smooth's McGraw Hill direct reader

Paste everything below the line into a new Claude Code session on
`OlisaNW247/penn-dashboard`. Written 2026-11-02 for Olisa, who will run the
session from their phone with no laptop. Marco has a Mac and Chrome.

---

You are building the first version of a **McGraw Hill direct reader** for
Smooth, the iPhone app in this repo. It reads a student's own McGraw Hill
Connect (and later ALEKS) assignments: title, class, due date, done or not.
It reads them from the student's own account, on the student's own phone,
with the student's own session. Nothing leaves the phone.

Read `CLAUDE.md` top to bottom and `ROADMAP.md` first, as CLAUDE.md asks.
Then read `reports/McGraw Hill access for Smooth.md` and the four notes in
`research_notes/McGraw Hill access for Smooth/`. That research is the
starting point. The most useful note for the code is
`smooth_codebase_seams.md`, which maps every seam with file:line references.

## The decision already made

The research found that McGraw Hill's terms of use appear to bar "robots,
scrapers and automatic devices" without written permission, and that Apple
guideline 5.2.2 asks for permission under a service's terms. Olisa, the
owner, has read that and decided to build the direct reader anyway. Record
that decision in `ROADMAP.md` with today's date. Do not argue it again.
Build it so the risk stays controllable:

- **A remote kill switch, off unless the manifest turns it on.** Add an
  optional `readers` object to the update manifest (`lhf-update.json` on the
  `update-manifest` branch), decoded the way the `feedback` object is: with
  `try?`, so a bad value never costs `minimumVersion`. Builds that don't
  know the key ignore it. The reader runs only while the last-known
  manifest says `"mcgrawHill": true`. A missing key, a failed fetch on a
  fresh install or a bad value all mean off. This is the opposite of the
  update floor's fail-open rule, on purpose: if McGraw Hill objects, Olisa
  has to be able to switch every phone off from GitHub's web UI on their
  phone, with no release. **Never edit the `update-manifest` branch
  yourself. Never merge it into anything.** Olisa turns the switch on when
  they decide.
- **A compile-time flag too**, `FeatureFlags.mcgrawHillReader`, beside
  `FeatureFlags.edDiscussion`.
- **On-device only.** Never upload McGraw Hill data to the backend. Never
  pool it. Never put it in the `ask` context document:
  `assistantSourceLabel` in `AssistantContextAssembly.swift` is a switch
  with no `default:` on purpose, so decide its case explicitly and leave
  McGraw Hill rows out. Never add analytics.
- **`docs/PRIVACY.md`** changes in the same commit as the behaviour, as
  CLAUDE.md requires. Use the Ed Discussion section as the template.
- **Preview and demo mode never touch it.** App Review gets in only
  through preview mode.

## How this session works, given no laptop

You are in a cloud container with no Swift toolchain. Here is what replaces
the Mac:

- **The compiler is GitHub Actions.** `.github/workflows/tests.yml` runs
  `swift test --no-parallel` on a macOS runner for every pull request that
  touches `LowHangingFruitKit/**`. It also runs on pushes to `v8`.
  - Work on a branch, `feature/mcgraw-hill-reader`, cut from `v8`.
  - Open a **draft** pull request into `v8` early. Ask Olisa first, because
    a PR is outward-facing.
  - Every push to the branch then compiles and tests the package. Read the
    results with the GitHub MCP tools (`actions_list`, `get_job_logs`,
    `pull_request_read`).
  - A change counts as compiled only once that run is green. Say so plainly
    whenever something is not yet green.
  - The runner builds the package's macOS slice. It does not build the iOS
    app, the widget or anything behind `#if os(iOS)`.
- **The iOS build, installing on a phone, and anything that needs a real
  browser with developer tools need a Mac. That means Marco.** Olisa
  relays to Marco.
  - Whenever you need Marco, write a self-contained brief into
    `docs/mcgraw-hill/MARCO_BRIEFS.md`: a dated heading, exactly what to do,
    the exact commands, and what to paste back.
  - Commit it, then tell Olisa in one line: "brief N for Marco is in
    `docs/mcgraw-hill/MARCO_BRIEFS.md`".
  - Marco's own Claude session will read it, so write it for an agent that
    has this repo and a Mac, not for a person.
- **Olisa can do these from their phone:**
  - answer questions
  - open a URL in Safari while signed in to Canvas, and tell you what they
    sees
  - take screenshots
  - edit a file on GitHub's web UI

  Keep questions short and few. Batch them.

## Phase 0: find out what McGraw Hill actually serves (do this first)

Nothing in the repo knows McGraw Hill's endpoints. The research found one
hobby project's comments. They describe a long-lived `ERIGHTS` cookie on
`newconnect.mheducation.com`, a five-minute `MH_TOKEN` JWT minted by
`POST /caas/heclr/coire/refreshToken`, and an assignments API that takes
that JWT as a Bearer header plus a `person_xid`. Treat all of that as a
rumour until it is seen. The student landing page is reportedly
`newconnect.mheducation.com/student/todo`.

1. **Ask Olisa which of their or Marco's classes use Connect or ALEKS.** Then
   ask how they reach it: a link inside Canvas, or a McGraw Hill sign-in.
   If neither has a McGraw Hill class this term, stop and say so. Nothing
   below can be verified without a real account.
2. **The Canvas side, from Olisa's phone.** Ask them to open this in mobile
   Safari while signed in to Canvas:
   `https://canvas.upenn.edu/api/v1/courses/<course id>/assignments?include[]=submission`
   for the McGraw Hill class. Have them tell you, for one Connect item only:
   - `submission_types`
   - the host in `external_tool_tag_attributes.url`
   - whether `due_at` is set
   - `submission.workflow_state` and whether `submitted_at` is null

   Tell them plainly not to paste ids, names, scores or the whole response.
   Ideally they check it before the item is done, after they finish it, and
   after its due date. That tells you what Canvas already knows, which the
   reader will merge with.
3. **Recon brief for Marco (brief 1).** Marco signs in to Connect in
   desktop Chrome with an account that has a real section. Marco opens it
   from Canvas, the way students do, and records with DevTools → Network
   (Fetch/XHR):
   - the request that lists assignments for a section: method, host and
     path, with ids replaced by `<id>`
   - how it is authenticated: which header or cookie names, never their
     values
   - the JSON field names and value types for one assignment, values
     replaced by their type, plus the field that says done or submitted
     and its possible values
   - what the LTI launch from Canvas lands on, and whether it opens a new
     tab
   - the sign-in page URL and whether there is a CAPTCHA or bot challenge
   - how long the session lasts if left idle (rough is fine)

   Marco saves this as `docs/mcgraw-hill/RECON.md`, redacted as above, and
   pushes it to the feature branch. The brief must say, in bold: never
   commit a cookie, token, JWT, `person_xid`, email, real name, score or
   section id. Real assignment titles are not needed either.
4. If Marco has no McGraw Hill account, write brief 1 instead as a DEBUG-only
   recon screen in the app. It must be compiled out of Release. The screen
   loads Connect in a WebView, records request URLs (ids replaced with
   `<id>`) and the JSON key paths and value types of responses, and writes
   them to a file Marco reads off a tethered phone with `devicectl` (see
   CLAUDE.md → Commands).

Don't write the real client until `RECON.md` exists.

## Phase 1: the parts that need no endpoints (start while recon runs)

These compile on the GitHub runner and need no McGraw Hill account. Each
gets swift-testing tests (`@Test`/`@Suite`), in the register CLAUDE.md
describes.

- **The kill switch:** the manifest's `readers` decoding, the last-known
  cache and the "off unless on" rule. Copy the shape of `FeedbackNotice`
  and the manifest decoding in `LowHangingFruitKit/Sources/LowHangingFruitKit/Update/`.
- **Where a row lives.** Follow CLAUDE.md's rule against new
  `Assignment.Source` cases and new ledger columns: older builds map an
  unknown source to `.canvas`, and a schema change drops an older build to
  an empty in-memory ledger.
  - A McGraw Hill item that Canvas also lists (an LTI assignment) enriches
    the Canvas row instead of becoming a second card. It contributes
    done-state, the student's own due date when it differs, and an "in
    connect" label.
  - A McGraw Hill item that Canvas does not list needs a home. Propose one
    in the PR description, in the shape of the `ed-`/`syllabus-` sourceID
    prefixes on `.canvasAnnouncement` rows. Ask Olisa before writing it.
  - `AssignmentDeduplicator`'s `Match` is hard-wired to two sides
    (`canvasID`/`gradescopeID`). Prefer a separate pass, as announcements
    have, to rewriting it.
- **The overdue trap, now:** if Canvas never records `submitted_at` for a
  finished Connect item, the card stays overdue and the Smooth Sweeper
  alarm rings for finished work. The reader's done-state fixes that. Until
  the reader is on and connected for that class, recognise McGraw Hill
  LTI assignments by the `external_tool_tag_attributes.url` host and leave
  them out of the Sweeper (`NotificationScheduler.loudAlerts`). That
  needs `external_tool_tag_attributes` decoded in
  `CanvasGradesClient`'s assignment type.
- **Session storage:** a new `SessionCookieStore.Service` case and a
  reauth rule modelled on `GradescopeReauthRule`. The rule believes only a
  real login page, seen twice an hour apart, and never disconnects.

## Phase 2: the reader (after `RECON.md`)

Pick the road from what the recon shows, and say why in the PR.

- **Through Canvas (preferred if it works):** the Ed Discussion pattern.
  Find the McGraw Hill tool in the course's `/tabs` and module
  `ExternalTool` items. Launch it in a hidden WebView with the Keychain's
  Canvas cookies injected, as `EdSessionLauncher` does. Save the McGraw
  Hill cookies it lands with. The student types no new password. If the
  launch needs a new window or a user gesture, the hidden launch may not
  work; recon will show.
- **A visible McGraw Hill sign-in:** the Gradescope pattern. A login pane on
  its own persistent `LoginDataStores` entry, cookies saved on sign-in, a
  row in Profile → accounts, and an optional step after Gradescope in
  onboarding. Never read or store what the student types.
- Either way, the client is pure Kit code against the recorded shapes, with
  a fixture built from `RECON.md`'s types, never from real data. If a short
  token has to be minted, mint it per sync and keep it in memory only.
  Throttle to the 15-minute cadence `AutoSyncCoordinator` uses. Fail soft
  everywhere: a McGraw Hill error is a note, never a thrown error that
  breaks the Canvas sync.
- **ALEKS comes after Connect works.** It has its own login at
  `www.aleks.com/login`, and per-student due-date "exceptions" that Canvas
  never sees. That makes it the strongest case for a direct reader, but it
  needs its own recon.

## Phase 3: on a phone (Marco)

When the PR is green, write a brief for Marco to:

1. Build the iOS Debug app from the branch and install it on their phone.
   The commands are in CLAUDE.md → Commands; run the build alone first and
   install only after BUILD SUCCEEDED.
2. Turn the reader on for that build only, with a DEBUG launch argument
   such as `-LHFForceMcGrawHillReader`. Do this in place of the manifest,
   so the live switch stays off.
3. Report:
   - whether the class's items appear once each
   - whether a finished one reads done
   - whether a re-sign-in is ever asked for
   - any crash report (`.ips`)

Record what was seen in CLAUDE.md (What the app does, Known gaps) and
`ROADMAP.md`.

## Rules that are not negotiable

- Branch and PR only. Never push to `v8` directly. Never merge the PR: the
  owners do.
- Commit as Olisa: `git -c user.email="olisanwogugu@gmail.com" -c
  user.name="OlisaNW247"`. End commit messages with the attribution lines
  the session gives you. No model names in commits, code or docs.
- Never commit real Canvas, Gradescope or McGraw Hill data: cookies,
  tokens, ids, names, scores, emails.
- Never deploy anything to Supabase, or touch its secrets or tables. This
  feature has no server part.
- Don't run `xcodegen generate`.
- Keep `CLAUDE.md` and `ROADMAP.md` current in the same commits as the work
  they describe.
- Copy follows Marco's rule: the least text that works, in lowercase like
  the rest of the app ("connect mcgraw hill", "in connect").
- When unsure, ask Olisa one short question rather than guessing. When you
  need a Mac, write Marco a brief.

## What "done" means for this session

The first session is done when all of these hold:

- The Phase 1 pieces are on the draft PR and green on the runner.
- `docs/mcgraw-hill/MARCO_BRIEFS.md` holds the recon brief.
- `ROADMAP.md` records the owners' decision and the plan.

The client waits for `RECON.md`. Report to Olisa in a few plain sentences:
what is green, what is waiting on Marco, and the one thing that would
change the plan.
