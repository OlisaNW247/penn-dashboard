# Ed Discussion → pooled course material

Written 2026-09-22. Branch: `v6`. Status: **phase 0 (recon probe) built
blind, not compiled; nothing ingested yet.**

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
  `question`; drop `is_private` and everything student-authored. Authors
  are recorded as "staff", never by name. Newest 100 per course, last 120
  days, incremental by `updated_at`.
- **Ed XML → text** — `<document>`, `<heading>`, `<paragraph>`, `<list>`,
  `<link>`, `<callout>`, `<pre>`; a pure Kit converter with fixtures.
- **Matching Ed course ↔ Canvas course** by code + term from `/api/user`,
  with an `edstem.org/us/courses/<id>` link found in the Canvas site as the
  tie-breaker (`course_websites.ed_course_id` already exists for this).
- **Sync** — a new `course_documents` kind `ed` (migration widening the
  kind check; `PROTOCOL.md` gains `ed` with `sourceID` = Ed thread id),
  uploaded through the existing manifest/dedupe path from
  `CourseKnowledgeCollector`, so classmates share one copy.
- **ask** — `CourseSearch.kindBoost` treats `ed` like `announcement`.
- **Settings** — one read-only "ed discussion" row under accounts showing
  which courses are connected; no credentials to enter.

## Phase 2

Announcement Watcher reads `ed` documents through the same gate it uses for
Canvas announcements, so a TA's "HW3 due Friday moved to Monday" becomes a
dashboard item.

## Privacy rules for this feature

Ed content is course material, pooled like syllabi. Student-authored posts
never leave the phone — they are filtered before upload. Author names are
never uploaded. No Ed credential is ever typed into the app; whatever
session the launch yields lives in the same device-bound stores as the
Canvas session and is never synced.
