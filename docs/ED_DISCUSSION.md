# Ed Discussion → pooled course material

Written 2026-09-22. Branch: `v8` (cut from `V7` 2026-10-02). Status, as
of 2026-10-10: **phase 1 built 2026-10-02 (blind), compiled green
2026-10-09 (1539/154), and the access path proven on Olisa's phone the
same day**: the launch lands on Ed, and the captured token reads Ed's API
(`native whoAmI (token): status=200 courses=19`). The backend accepts
kind `ed` since 2026-10-10 (migration applied, `sync` version 7
deployed). What has not happened yet: a full sync on a device, so the
Profile row has never read "connected" and no `ed` document has reached
the pool. What exists:

| Piece | Where |
|---|---|
| kind `ed` on both sides of the wire | `CourseDocument.Kind.ed`, migration `20261002090000_ed_kind.sql`, `_shared/manifest.ts`, `PROTOCOL.md` |
| wire models, XML → text, filter, matcher, builder | `Kit/Ed/EdWire.swift`, `EdDocumentText.swift`, `EdThreadFilter.swift`, `EdCourseMatcher.swift`, `EdDocumentBuilder.swift` |
| HTTP client and document ingestion | `Kit/Ed/EdClient.swift` (cookie or `x-token` auth), `EdIngestion.swift` |
| hidden-WebView LTI launch, session capture | `UI/EdSessionLauncher.swift`. The session is a `localStorage` token (`authToken`, else `authToken:us`) read after landing and kept in `UI/EdSessionTokenStore.swift` (Keychain, this-device-only, deleted on Canvas disconnect); any `edstem` cookies still go to `SessionCookieStore.Service.ed` (never aged by the 24 h Canvas rule) as a fallback. Token path proven by the probe 2026-10-09 |
| orchestration inside the course-material sync | `UI/EdDiscussionCoordinator.swift`, called from `AppState+CourseKnowledge.swift` before the backend upload on both paths |
| status for the student | read-only "ed discussion" row in Profile → accounts (Penn only) |
| kill switch | `FeatureFlags.edDiscussion` |

2026-10-09 probe results, real phone: a fresh hidden WebView ends at Penn
WebLogin unless the Keychain's Canvas cookies are injected into it first;
once they are, the launch lands on `edstem.org/us/courses/<id>/discussion`,
where Ed's session is a token in `localStorage` (`authToken`,
`authToken:us`), not a cookie (`document.cookie` empty, a cookie-only
`GET /api/user` is 401), so `EdClient` uses `EdAuth.token`.

Two things learned building it. `CourseKnowledgeBase.merge` and the Canvas
collector both treat a course's documents as a complete set, so an Ed
merge must pass the course's existing non-Ed documents alongside the new
ones, and prior `ed` documents must be restored after every collector
run or an unreachable Ed would erase them (and report them gone to the
server). And `CourseSummary` carries no term, so the matcher's term comes
from `CourseCode.parse(name).term`, falling back to code-only.

## What Olisa asked for

Classes that use Ed Discussion link to it from Canvas. He wants the
important posts — announcements and anything the professor or TAs write —
folded into the pooled course material that **ask** and the Announcement
Watcher read, and *not* the stream of student questions. And the student
must do the least possible work: no API token to find and paste. "I want
to avoid the API token method if possible."

## The access path: ride the Canvas login

Ed's own API takes a personal access token from `edstem.org/us/settings/
api-tokens`. That is the path every community client uses, and it is the
path we are **not** taking, because it is a chore for every student and a
secret to store.

Instead: a course that uses Ed has an "Ed Discussion" tool in its Canvas
course navigation. That tool is an LTI launch — Canvas posts a signed
launch to Ed, and Ed signs the student in with no typing, which is exactly
what happens when the student taps it on the web. The app already holds a
live Canvas session in `LoginDataStores.canvas`, so it can perform that
launch itself in a hidden WebView, the same way `CanvasSessionRenewer`
already renews Canvas silently. Whatever session Ed establishes is then
the app's to reuse, and when it lapses the app launches again. With "stay
signed in" the Canvas side never lapses either. The student's part: none.

## Phase 0 — the probe (built 2026-09-22, blind)

One unknown decides the shape of everything after it: after the launch,
**where does Ed keep its session and does a plain cookie-carrying request
read its API?** Rather than guess, a DEBUG-only button in Settings
("probe ed discussion", `EdDiscussionProbe.swift`) does the launch once
on the owner's phone and reports metadata only:

- which of the student's Canvas courses have an Ed tab
  (`CanvasCourseContentClient.tabs(courseID:)` — `/api/v1/courses/:id/tabs`
  is the only endpoint that lists tools placed in the nav; the module
  scan the collector already does never sees them);
- the navigation hops the launch took (host and path, never the query,
  which can carry LTI state) and where it finally landed;
- the *names* of Ed's localStorage / sessionStorage keys and cookies —
  never a value;
- the status of an in-page `GET https://us.edstem.org/api/user` sent with
  cookies, plus the course count and codes it returned.

A 2xx there means the launch produced a cookie-borne session and a
URLSession client carrying those cookies can read Ed's API — the simple
outcome. A 401 with a token-shaped storage key means Ed's web client
authenticates with a header from storage, and the next step is a separate
decision, not something the probe works around.

The launch URL takes `display=borderless`: without it Canvas renders the
tool in an iframe, the WebView's main frame stays on canvas.upenn.edu, and
no main-frame script can see Ed at all.

## Phase 1 — ingestion (after the probe)

- **Kit `Ed/` client**, cookie- or token-authenticated per the probe:
  `GET /api/user` (the student's Ed courses with code, name, year,
  session, role) and `GET /api/courses/:id/threads?limit=100&sort=new`
  (threads with `type`, `is_pinned`, `is_private`, `category`, `document`
  in Ed's XML, timestamps, `user_id`; `users[]` with `course_role`).
- **Filter** — keep a thread when `type == announcement`, or `is_pinned`,
  or its author's `course_role` is `admin`/`staff` and it is not a
  `question`; drop `is_private`, `is_anonymous` (since 2026-10-23) and
  everything student-authored. Authors are recorded as "staff", never by
  name. Threads whose last activity is within 120 days, read up to 300
  deep (see "2026-10-23" below). **Not incremental:** an earlier version of
  this line said "incremental by `updated_at`". Nothing is fetched by
  `updated_at` and nothing is diffed on the wire; every read takes the whole
  window and replaces the class's Ed set, and only the document hash
  decides what counts as changed.
- **Ed XML → text** — `<document>`, `<heading>`, `<paragraph>`, `<list>`,
  `<link>`, `<callout>`, `<pre>`; a pure Kit converter with fixtures.
- **Matching Ed course ↔ Canvas course** by code + term from `/api/user`,
  with an `edstem.org/us/courses/<id>` link found in the Canvas site as the
  tie-breaker (`course_websites.ed_course_id` already exists for this).
  **Not wired (stated 2026-10-23):** `EdCourseMatcher` implements the link
  tier, but the coordinator passes `edLinks: [:]`, so no link is ever read
  and code plus term is the only matching in use. A class whose code or
  term does not agree between Canvas and Ed is not matched (status failure
  kind `noMatch`).
- **Sync** — a new `course_documents` kind `ed` (migration widening the
  kind check; `PROTOCOL.md` gains `ed` with `sourceID` = Ed thread id),
  uploaded through the existing manifest/dedupe path from
  `CourseKnowledgeCollector`, so classmates share one copy.
- **ask** — `CourseSearch.kindBoost` treats `ed` like `announcement`.
- **Settings** — one read-only "ed discussion" row under accounts showing
  which courses are connected; no credentials to enter.

## Phase 2

**Built twice, merged 2026-10-20 (blind, not compiled): the Announcement
Watcher reads the synced `ed` documents for tasks.** Two lines of work built
this on 2026-10-18/19. One fed announcement, pinned and staff posts through
the Canvas loop in `syncAnnouncements` (`edAnnouncementsForExtraction`, finds
named `announcement-ed:{course}:{thread}-{n}`). The other, which stayed, is
its own pass, `syncEdAnnouncementTasks` (`AppState+EdAnnouncementTasks.swift`):
announcements and pinned posts only, a class re-checked after every network
call, a six-hour retry clock per failed post, finds named
`ed-{course}-{thread}-{n}`. The merge took the second and gave it what the
first had: the header's posting day as the post's date and window
(`edPostDate`), a twin check against finds already made
(`droppingAnnouncementTwins`), a stop on a quota refusal, and a one-line
`lastEdTaskSyncSummaryV1`. A staff post that is neither an announcement nor
pinned is therefore no longer read for tasks. Rows the first version wrote
stay on a phone as inert `.canvasAnnouncement` rows (their processed ids are
the same, so nothing is read twice) and leave the dashboard by the ordinary
rule.

A TA's "HW3 due Friday moved to Monday", if it is an announcement or pinned,
becomes a dashboard item through the same gates as a Canvas announcement.

## 2026-10-23: paging, anonymous posts, sign-outs, and the status line

Written blind: nothing here was compiled or run when it was written. Four
holes were found by reading the code, and three behaviours changed.

1. **The read pages until the window closes.**
   `EdClient.threadsWithinWindow` reads `/threads` 100 at a time, `sort=new`,
   offsets 0, 100, 200, and stops at the first of: a short page (fewer than
   100, an empty one included); a page whose oldest thread, by last activity
   (`updated_at`, else `created_at`), is older than 120 days; the third page.
   The cap of 3 (300 threads) is there because a board with more than 300
   threads in 120 days is a question board, where announcements and pins are
   a small fraction and paging further downloads student threads to throw
   them away; it also bounds a run to three requests per class. Before this
   the sync read the newest 100 only, so a pinned or announcement post older
   than the 100th newest thread was never read, and because each successful
   read replaces the class's whole Ed set, one that had been read earlier
   vanished from the phone on the next run. A failure on any page throws and
   discards the pages already read: handing back a partial set would erase
   the posts on the pages not reached. A thread repeated across pages (a
   reply moved it between two requests) is kept once. One thing is assumed and
   not verified against a live board: that `sort=new` runs in the same
   order as last activity (if it runs by creation, a long-dead thread
   revived by a reply can sit on a page the stop rule never reaches, which
   is the same miss the one-page read always had). The `users` side-loads of
   every page are merged by user id before the filter sees them.
2. **Anonymous posts are dropped.** `docs/PRIVACY.md` has promised that
   anonymous Ed posts never leave the phone; `EdThreadFilter` never read
   `isAnonymous`, so an anonymous announcement, or an anonymous thread staff
   pinned, was kept and pooled. It is now dropped with the reason
   "anonymous", after the private check and before the announcement check.
   A missing `is_anonymous` decodes as `false` (`EdWire.swift`), unlike
   `is_private`, which defaults to `true`; so a thread that arrives without
   the flag is judged on its other fields. Ed sends the flag today. If it
   ever stops, anonymous posts would be kept again; defaulting it to `true`
   would fail safe at the price of dropping every announcement, and is the
   owner's call.
3. **A sign-out mid-run restores, never drops.** On a 401 from `/threads`
   the run stops (a retry would only repeat the 401). Before today only the
   classes the loop had reached were in the matched set, so every class
   after the break fell into the drop set and had its stored Ed documents
   deleted: a sign-out on the second of six classes erased the other four
   classes' posts. Every match is now resolved to its Canvas site before any
   read, so `matched` is the whole list, and the rule reads: **drop** =
   classes with no Ed match after a successful `/user`; **restore** =
   matched classes not read this run (a failed read, or never reached);
   **replace** = classes read. `restoreDropPlan` is that rule as a pure
   function, and `readTargets` the loop, so the tests drive both with a fake
   reader.
4. **The status line says why a class was not read.** The Ed status line
   (Profile → accounts in a DEBUG build, and the `ed:` tail of
   `lastCourseKnowledgeSyncSummaryV1` on the phone's App Group plist) now
   leads with counts: `matched 3 · read 1 · restored 2 · dropped 0 · first
   failure sessionExpired · <detail>`. Classes are Canvas courses: `matched`
   found an Ed course, `read` were read, `restored` kept their stored
   documents, `dropped` had them removed. The first failure is one fixed
   word: `noTab` (no class has an Ed tab), `tabCheck` (a Canvas tab request
   failed, so nobody knows), `launch` (no Ed session came out of the
   launch), `noMatch` (Ed's courses matched none of the Canvas classes),
   `sessionExpired`, `http(code)`, `notHTTP`, `invalidJSON`, or `other`.
   Counts come first because the summary line is capped at 120 characters
   and the cap cuts the tail. Never a title, id or body. This exists
   because ten CIS 3990 documents on the server had no `· posted` day,
   meaning that class had not completed a read since the header gained the
   date (2026-10-19), and nothing on the phone said why. The line cannot
   by itself tell whether that class has an Ed tab, was never matched
   (`noMatch`), or was read and failed (`http(code)`, `sessionExpired`); it
   narrows the question to one of those. It is not necessarily a code bug.

## Privacy rules for this feature

Ed content is course material, pooled like syllabi. Student-authored posts
never leave the phone — they are filtered before upload. Author names are
never uploaded. No Ed credential is ever typed into the app; whatever
session the launch yields lives in the same device-bound stores as the
Canvas session and is never synced.
