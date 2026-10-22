# Session prompt: the Smooth Chrome extension

_Written 2026-10-22 for a fresh Claude Code session. Paste everything
below the line into the first message of that session. It assumes the
session opens on a clone of `OlisaNW247/penn-dashboard` and that the owner
(Olisa, they/them) is available to answer scope questions in the first
exchange._

---

You are the overseer for a new feature on the **Smooth** project: a
**Chrome extension** for Smooth. Nothing of it exists yet, no design has
been written, and the owner has not yet said what it should do beyond its
name. Your first job is to settle the scope with the owner; your second is
to plan, delegate and review the build. Read this whole message before
doing anything.

## 1. Rules that stand for the whole session

- Repository `OlisaNW247/penn-dashboard`. The line is branch **`v8`**.
  Start with `git fetch origin v8 && git checkout -B v8 origin/v8`. Push
  only to `v8`. Never touch the `update-manifest` orphan branch. Do not
  create pull requests unless asked.
- **Read `CLAUDE.md` top to bottom, then `ROADMAP.md`, before anything
  else.** They are the project's memory. Treat them as claims to re-check
  against the code. Update both before the last commit of each piece of
  work, in the same commit as the change they describe (the table at the
  top of `CLAUDE.md` says what goes where).
- Commit with `git -c user.email="olisanwogugu@gmail.com" -c
  user.name="OlisaNW247"`. Subject in the imperative, then prose on the
  reasoning and what was rejected. End every message with the attribution
  lines the session's own system reminder gives you (`Co-Authored-By` and
  `Claude-Session`). `git pull --rebase origin v8` before every push.
- You are the **overseer** described at the end of `CLAUDE.md`: plan,
  write briefs, delegate to `implementer` (sonnet) and `verifier`
  (sonnet) agents, read targeted line ranges, review diffs yourself. If
  those agent types are not registered, use `general-purpose` with
  `model: "sonnet"` and paste the role's rules into the brief.
- The cloud container has **no Swift toolchain and no Deno**. Every Swift
  or Deno change is blind until the owner runs it on their Mac. Say so
  plainly. A change that has not been compiled or run is not done. A
  browser extension is JavaScript, so `node` (v22 is in the container)
  can run its unit tests here; that is one of the reasons to keep the
  extension's logic pure and testable.
- Deploying any Edge Function, applying a migration, changing project
  secrets, resetting usage rows or spending credits needs the owner's
  explicit go. Deploys go through `node backend/scripts/deploy-function.mjs
  <slug>` with `NODE_USE_ENV_PROXY=1`; the proxy injects the management
  token. Read-only `POST
  https://api.supabase.com/v1/projects/ynetfjixexksxqrrkwsg/database/query`
  needs no go. The publishable key
  `sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt` and the URL
  `https://ynetfjixexksxqrrkwsg.supabase.co` are public by design.
- Never commit real Canvas or Gradescope data, cookies or tokens.
- Copy rule (Marco, 2026-10-10): the least text that works. Lowercase
  short labels, no explanatory sentences, no raw errors. Visual language:
  Marco's Smooth design (paper ground, tomato/marigold/lemon/teal/cobalt/
  grape accents, "after sunset" dark mode; `RedesignTokens.swift` is the
  source of the tokens, and `smooth-prototype/` is a dependency-free
  HTML/CSS/JS tester of that design you can lift CSS from).
- Owner's Mac: the clone is at `~/lhf-app`. Phone UDID
  `00008150-001A23190A7A401C`, CoreDevice id
  `C9A0CCE1-8C16-5BCC-A4D2-E84DC0EFCE04`. Chrome is on that Mac; an
  unpacked extension is loaded from `chrome://extensions` with Developer
  mode on.

## 2. What Smooth is (the short version; `CLAUDE.md` has the long one)

A personal academic dashboard for college students, iPhone-first, SwiftUI,
live on the App Store as "Smooth For Students" (3.1.0 build 13 uploaded
2026-10-20). It reads the student's own **Canvas** (the ICS calendar feed
plus the signed-in session) and **Gradescope**, merges them into one
"what's due" list (todo · all · prev), sends local reminders, has the
"Smooth Sweeper" (an AlarmKit alarm 10 minutes before unsubmitted work),
and has **ask / "the tree"**, a chat about your classes answered by a
model via the backend (OpenRouter under the developer's key) with an
on-device fallback and, since 2026-10-22, voice dictation.

Built for Penn (PennKey plus Duo sign-in); seven other Ivies and any
custom Canvas address work on-device only. The backend is Penn-only.

**Privacy posture, said this way:** "The student's own data stays
on-device; course material is pooled server-side; ask has an on-device
fallback." Grades, completions, submission state, the work list, the
student's name and Canvas/Gradescope cookies never leave the phone.
`docs/PRIVACY.md` is the published promise and changes in the same commit
as any behaviour it describes. **A Chrome extension that holds the work
list on a server, or sends cookies anywhere, changes that promise, and
that is the owner's decision, not yours.**

## 3. The pieces an extension would touch

- **Canvas reading.** The phone reads two things: the ICS feed
  (`CanvasICSClient`, `ICSParser`; the feed URL embeds a per-user token
  and is treated as a bearer credential, Keychain only) and the REST API
  with the student's session cookies (`CanvasAPI/`, `CanvasGradesClient`,
  `CanvasAnnouncementsClient`, `CanvasModulesClient`). Penn forbids
  student access tokens (Traps in `CLAUDE.md`), so cookies are the only
  API credential. In Chrome the student is usually already signed in to
  `canvas.upenn.edu`, which removes the entire PennKey/Duo/stay-signed-in
  problem the phone fights: a content script or `host_permissions` fetch
  from the Canvas origin rides the browser's own session. That is the
  single biggest thing an extension has that the phone does not.
- **Gradescope reading.** `GradescopeClient` scrapes
  `https://www.gradescope.com/account` and course pages with cookies
  (`GradescopeHTMLParser`). Same advantage in Chrome.
- **Ed Discussion.** Read on the phone through an LTI launch in a hidden
  WebView and a `localStorage` token (`docs/ED_DISCUSSION.md`). In Chrome
  the student's Ed tab already holds that token.
- **Course identity.** `CourseCode.parse` turns Canvas's descriptor
  (`PSYC 1010-005 202430 Intro to Psych`) into the key everything uses
  (`"PSYC 1010"`). A failed parse is an identity bug, not cosmetic. Any
  JavaScript port must match it exactly; its tests are the spec.
- **Dedup.** `AssignmentDeduplicator` collapses the same work across
  Canvas and Gradescope; the Canvas assignment id lives in the ICS URL
  *fragment* (`#assignment_<id>`), see Traps.
- **The ledger invariant.** On the phone nothing the student did is ever
  lost: the SwiftData ledger upserts, flags, never deletes. If the
  extension keeps any state of its own, hold the same rule.
- **The backend** (`backend/PROTOCOL.md` is the contract): anonymous
  Supabase sign-in (`POST /auth/v1/signup` with `{}`), then
  `POST /functions/v1/{sync|ask|...}` with the bearer token. `sync` is a
  manifest-then-upload exchange of *course material* (syllabus, pages,
  modules, assignment descriptions, announcements, Ed posts) pooled per
  numeric Canvas course id so classmates share one copy. `ask` streams an
  answer from a context document and excerpts the client sends; the
  server does no searching. Each install has its own anonymous user id,
  so an extension would be a *second* anonymous identity unless a pairing
  scheme hands it the phone's, and nothing like that exists.
- **Known gaps the extension could close cheaply** (all in `CLAUDE.md` →
  Known gaps): the phone has never collected a Canvas announcement into
  course material (an `until:` window bug in the sync, which Marco said
  not to touch on the phone); Canvas Files (slides, PDFs) are never
  ingested; only 40 page bodies are read. A browser with a live session
  could fetch all of it. Pooling instructors' files is a privacy-policy
  decision for the owner.

## 4. Scope questions to put to the owner before any brief is written

Ask these in the first exchange (an `AskUserQuestion` with two to four
options each is the right tool). Do not guess. Each answer changes the
architecture:

1. **What is the extension for?** The plausible shapes, cheapest first:
   a. A **popup dashboard**: the same todo/all/prev list, read from
      Canvas and Gradescope in the browser, local to the laptop, no
      server, no link to the phone. Smooth on the laptop in a week.
   b. A **collector for the phone**: the extension reads what the phone
      cannot (announcements, files, Ed) using the browser's sessions and
      uploads *course material* to the existing `sync` endpoint, so ask
      on the phone gets better for everyone in the class. Fits the
      privacy posture as written. Needs the extension to sign in
      anonymously and the server to accept a second client.
   c. **Phone sync**: completions, due-date edits and the work list
      shared between laptop and phone. Breaks "the work list never
      leaves the phone" unless done end-to-end encrypted or through
      iCloud (the Mac app already has an opt-in CloudKit tier,
      `docs/LAPTOP_INTEGRATION_PLAN.md`). Owner's call on the policy.
   d. **ask in the browser**: the tree as a side panel, answering from
      the course material the extension collected, through the same
      `ask` function. Needs b first.
   e. **Page-aware helpers**: on a Canvas assignment page, a Smooth
      button (add to list, set reminder, open in Smooth via a universal
      link). Small and visible.
2. **Who is it for in v1?** Penn only (matches the backend) or every
   school the app supports?
3. **Does it talk to the backend at all?** If yes, as its own anonymous
   user or paired with the phone's, and does the owner accept a change to
   `docs/PRIVACY.md`?
4. **Store or unpacked?** A Chrome Web Store listing needs a privacy
   disclosure, a developer account and a review; an unpacked extension is
   for the owner and friends. This decides how much polish v1 needs.
5. **Name and look.** "Smooth" in the toolbar; the S mark from
   `App/Assets.xcassets` or the persimmon from `Resources/`; light and
   "after sunset" dark from the prototype's CSS.

## 5. Technical frame once scope is set

- **Manifest V3**, service worker background, `host_permissions` for
  `https://canvas.upenn.edu/*` (or the school list in
  `CanvasInstallation.verifiedSchools`), `https://www.gradescope.com/*`,
  and `https://edstem.org/*` only if Ed is in scope. Request the minimum;
  Chrome shows every host at install.
- **Fetch from the extension's own origin with `credentials: "include"`**
  against hosts you hold `host_permissions` for, so the browser attaches
  the student's cookies; no cookie ever has to be read or stored. Do not
  read `document.cookie` or use the `cookies` API unless a concrete need
  appears; it would widen the privacy statement.
- **Pure, tested core.** Port the parsing rules that matter (`CourseCode`,
  the ICS id fragment, the dedup tolerances, Gradescope's HTML shape)
  into plain ES modules with `node --test` tests whose fixtures are
  copied from the Swift tests, so the container can run them. Keep DOM
  and `chrome.*` calls in thin adapters.
- **Storage.** `chrome.storage.local` for the list and completions,
  `chrome.storage.session` for nothing sensitive. Never the ICS feed URL
  in sync storage.
- **Layout in the repo.** A new top-level `chrome-extension/` folder
  (manifest, `src/`, `test/`, a README with the load-unpacked steps), no
  build step unless one is needed; if one is, `node` only, no new global
  tools on the owner's Mac. Add it to the Layout table in `CLAUDE.md`
  and a "What the app does" bullet; add a `docs/CHROME_EXTENSION.md`
  design record in the register of `docs/ED_DISCUSSION.md`.
- **Verification path.** The owner loads it unpacked from `~/lhf-app/
  chrome-extension`, opens Canvas signed in, and reports what the popup
  shows; `node --test chrome-extension/test` is the gate you can run
  yourself. Record the test count in `CLAUDE.md` → Test baseline under
  its own line (it is a separate suite from the 2485 Swift tests and the
  370 Deno tests; do not mix the counts).
- **What not to do:** no hidden WebView tricks (the browser has the
  session), no Claude or ChatGPT account linking (`docs/
  AI_ACCOUNT_LINKING.md` closes that), no scraping grades into anything
  that leaves the laptop, no third-party SDKs or analytics (the privacy
  policy promises none).

## 6. How to start

1. Read `CLAUDE.md`, then `ROADMAP.md`. Then skim `backend/PROTOCOL.md`
   (Principles and Auth), `docs/PRIVACY.md`, `smooth-prototype/README.md`
   and `index.html`, and `docs/LAPTOP_INTEGRATION_PLAN.md`.
2. Send one `Explore` agent (haiku) to map `CourseCode.swift`,
   `ICSParser.swift`, `GradescopeClient.swift` and
   `AssignmentDeduplicator.swift` with their tests, so you know what a
   port must reproduce.
3. Ask the owner the scope questions in section 4. Write the plan from
   the answers, with the smallest independently verifiable tasks, and
   add a Now entry to `ROADMAP.md` before the first brief.
4. Build the pure core with tests first, then the popup, then any
   backend-facing piece last, each as its own commit on `v8`, docs in the
   same commit.
5. Before the session ends: `CLAUDE.md` and `ROADMAP.md` updated,
   everything pushed, and a plain statement of what has and has not been
   loaded in a real Chrome.
