# LHF backend protocol

The contract between the iOS/macOS app (`LowHangingFruitKit`) and the
Supabase backend in this directory. Both sides are written against this
file; when they disagree, this file wins and the code is wrong.

## Principles

1. **Canvas credentials never reach the server.** The phone fetches course
   material with the student's own cookies and uploads the *extracted*
   documents. The server never talks to Canvas.
2. **Only course-level material is shared.** Syllabus, pages, modules,
   assignment descriptions, announcements. Never grades, completions,
   submission state, the work list, the student's name, or transcripts of
   questions. `CourseDocument.submitted` is stripped before upload.
3. **The sharing key is the Canvas numeric course id.** Every student in the
   same Canvas site sees identical material. Section ids are recorded on the
   enrollment row for later scoping but do not partition documents in v1.
4. **Identity is anonymous.** Supabase anonymous sign-in. No email, no
   password. The refresh token lives in the Keychain beside the session
   cookies. A user id exists so the server can scope private rows and
   enforce quotas, nothing more.
5. **The on-device answerer is the fallback.** Offline, over quota, or with
   the backend down, ask answers from the phone exactly as it does today.

## Auth (Supabase GoTrue)

- Sign in: `POST {SUPABASE_URL}/auth/v1/signup` with headers
  `apikey: {ANON_KEY}`, `Content-Type: application/json`, body `{}`.
  Anonymous sign-ins must be enabled on the project. Response:
  `{ access_token, token_type, expires_in, expires_at, refresh_token, user: { id, ... } }`.
- Refresh: `POST {SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,
  same headers, body `{ "refresh_token": "…" }`. Same response shape.
  Refresh tokens rotate: always store the new one.
- Every function call: `POST {SUPABASE_URL}/functions/v1/{name}` with
  `Authorization: Bearer {access_token}`, `apikey: {ANON_KEY}`,
  `Content-Type: application/json`. A 401 means refresh and retry once.

## Wire types (JSON)

Dates are ISO 8601 strings with fractional seconds allowed
(`2026-09-07T14:03:00Z`). Canvas ids are strings, never numbers.

```
CourseSummaryWire   { courseID, code, name, url?, term?, sectionIDs? }
DocumentStub        { id, contentHash }
CourseDocumentWire  { id, courseID, course, kind, sourceID, title, url?,
                      text, updatedAt?, fetchedAt, contentHash,
                      dueAt?, pointsPossible? }        -- no `submitted`
FullySyncedCourse   { courseID, documentIDs: [string] }
```

`kind` is one of `home | syllabus | assignment | announcement | module | page`.
`id` is always `"{kind}:{courseID}:{sourceID}"`, computed by the client.

## `sync` — manifest exchange, then upload

### Step 1: `{ "action": "manifest", "courses": [CourseSummaryWire], "documents": [DocumentStub] }`

Server: upserts `courses`, upserts the caller's `enrollments` for every
course listed (this is the enrollment proof; see Limitations), then answers

```
{ "coursesFresh":   [courseID],           -- server has a full sync newer than FRESH_WINDOW
  "serverManifest": [DocumentStub],       -- every live (gone_at IS NULL) doc for these courses
  "download":       [CourseDocumentWire] } -- live docs whose (id, contentHash) the client didn't list
```

Client: applies `download` to local knowledge first, then fetches Canvas
for every course NOT in `coursesFresh` (announcements are fetched for all
courses in one call regardless; they are cheap and change daily). Local
merge runs as today.

### Step 2: `{ "action": "upload", "documents": [CourseDocumentWire], "fullySyncedCourses": [FullySyncedCourse] }`

`documents` = local docs whose `(id, contentHash)` is not in
`serverManifest`. `fullySyncedCourses` = the courses the client fetched from
Canvas this run with every doc id it now holds for that course. Server:
upserts docs by id (clearing `gone_at`), sets `gone_at = now()` on live docs
of a fully-synced course whose id is absent from `documentIDs`, sets
`courses.last_full_sync_at = now()` for those courses, and sets
`courses.profile_stale = true` for any course whose set of
`(id, contentHash)` for kinds `syllabus|home|page` changed. Answers

```
{ "accepted": n, "profileStale": [courseID] }
```

Client then POSTs `extract-profile` for `profileStale` without awaiting.
Maximum request body 6 MB; the client chunks `documents` into batches of at
most 200.

## `ask` — streamed answer

Request:

```
{ "question": string,
  "contextDocument": string,   -- the byte-stable AssistantContextDocument
  "excerpts": string,          -- rendered RETRIEVED EXCERPTS block, may be ""
  "askedAt": ISO8601,
  "courseIDs": [courseID],     -- the courses the student currently has
  "history": [ { "role": "user" | "assistant", "content": string } ] } -- may be []
```

Response is `text/event-stream`. Every event is one `data:` line of JSON:

```
data: {"type":"delta","text":"…"}
data: {"type":"done","usage":{"promptTokens":n,"completionTokens":n,"cachedTokens":n}}
data: {"type":"error","code":"quota_exceeded"|"upstream"|"bad_request","message":"…"}
```

The model is instructed to end with the same `<sources>COURSE|kind|detail;…</sources>`
line the app already parses (`SourcesBlockSplitter`); the server passes
model text through untouched. Errors before streaming starts are plain
JSON with an HTTP status: 401 unauthorized, 429
`{ "error": "quota_exceeded", "resetAt": ISO8601 }`, 502 upstream.

Server prompt order (stable prefix first, for provider prefix caching):
frozen system instructions → `contextDocument` → course profiles JSON for
`courseIDs` → history → user turn `Current date: …\n\n{excerpts}\n\nQUESTION: {question}`.

Quota: `ASK_DAILY_LIMIT` requests per user per UTC day (default 40) and
`ASK_MONTHLY_GLOBAL_LIMIT` requests across all users per calendar month
(default 100000). Usage is recorded in `ask_usage` after the stream ends;
questions and answers are never stored.

## Catalog

The problem this solves: a Canvas course site is one thing, but the
registrar course underneath it can be several -- PHYS 0151 is one Canvas
site containing a 1.0 CU lecture and a 0.5 CU lab, and nothing before this
told `ask` that, so a question about "the class" could get answered from
whichever component's syllabus text happened to be retrieved.

Source: Penn Labs' public Penn Courses API (the backend behind Penn Course
Review), `GET https://penncoursereview.com/api/base/current/courses/{DEPT-NNNN}/`,
no auth, no key. `{DEPT-NNNN}` is the Canvas course code with its space
replaced by a dash (`PHYS 0151` -> `PHYS-0151`; see `_shared/catalog.ts`'s
`catalogCode`). Review-score fields the response also carries
(`course_quality`, `instructor_quality`, `difficulty`, `work_required`, at
both the course and section level) are Penn Labs' own aggregated Penn
Course Review data, not the registrar's, and are never stored -- out of
scope for this table on purpose.

Storage: `catalog_courses`, one row per registrar course code (not one per
Canvas course id, and not one per enrolled student -- a registrar course is
the same fact for every semester's offering and every student in it).
`courses.catalog_code` is the join from a Canvas course site to its
registrar course; nullable, since a code `catalogCode` can't confidently
parse is left unlinked rather than guessed at.

Refresh rule: piggybacks on `sync`'s manifest step rather than a cron. After
`upsertCourses`, for every course in the manifest whose code resolves to a
catalog code, the server links `courses.catalog_code` and -- for at most 8
of those codes per call, each fetched concurrently with a 2.5 s timeout --
fetches a fresh `catalog_courses` row if none exists yet or the existing one
is more than 7 days old. This is deliberately not its own scheduled job:
only courses someone is enrolled in are worth a Penn Labs request for, and
every enrolled course already reaches this code path at least once an hour
(the app's own refresh loop calls `sync` that often), so there is no
staleness gap a cron would close that this doesn't already close on its
own. Failures (a 404, a timeout, a network error) are silent to the
manifest response and only ever logged as a count.

Structure block: `ask`'s prompt carries a `COURSE STRUCTURE (from the Penn
registrar via Penn Labs)` system block, built by `_shared/catalog.ts`'s
`structureBlock` from the `catalog_courses` rows reachable through the
caller's enrolled courses' `catalog_code`. It sits after the context
document and before the course-profiles block (see "Server prompt order"
under `ask` above), one paragraph per course, sorted by catalog code for
the same byte-stability reason `buildMessages` sorts everything else in the
cached prefix: title and overall credits, then each component ("Lecture
(2 sections, 1.5 CU each)", "Lab (3 sections)" -- credits omitted per
component when no section states one), then grade modes offered, then
prerequisites, then a 600-character description. Empty when no enrolled
course has a resolved, fetched catalog row.

RLS: `catalog_courses` needs no enrollment gate, unlike every other table in
this schema -- it's public registrar data with no student-specific angle,
so every `authenticated` caller may `SELECT` every row. There are still no
write policies; only `sync`'s service-role client ever writes it.

## `extract-profile`

Request `{ "courseIDs": [courseID] }`. For each listed course that the
caller is enrolled in and whose `profile_stale` is true, the server builds
one `course_profiles` row from that course's live `syllabus`, `home` and
`page` documents (at most `PROFILE_INPUT_CHARS`, default 60000, syllabus
first) and clears `profile_stale`. Response `{ "updated": [courseID] }`.

Profile JSON (every field optional, strings are verbatim quotes or close
paraphrases of the source, never inferred):

```
{ "gradingWeights": [ { "name", "percent" } ],
  "latePolicy": string, "attendancePolicy": string,
  "examDates": [ { "name", "date"?, "text" } ],
  "officeHours": [ { "who", "when", "where"? } ],
  "contacts": [ { "name", "role"?, "email"? } ],
  "textbooks": [ string ],
  "keyPolicies": [ { "topic", "text" } ],
  "components": [ { "name", "gradingBasis"?, "creditUnits"?, "notes"? } ],
  "sourceDocumentIDs": [ string ] }
```

`components` is only populated when the syllabus itself distinguishes parts
of the course (e.g. "the lab is graded pass/fail, 0.5 CU") -- not simply
because the registrar's section list says there is a lab (that's
`catalog_courses.components` below, a different fact from a different
source). "name" is the component as the syllabus names it; "gradingBasis",
"creditUnits" and "notes" are each omitted unless the syllabus states that
component's own value.

## `extract-announcement`

Request `{ "announcementID", "courseCode", "title", "message", "postedAt"?, "now": ISO8601 }`.
Response `{ "assignments": [ { "title", "dueAt"? } ] }`. Replaces the
user-key `ClaudeAnnouncementExtractor`. Counted against the same daily quota.

## `delete-account`

Request `{}`. Deletes the caller's `enrollments` and `ask_usage` rows and the
auth user. Shared course material is untouched (it is not the user's data).
Response `{ "deleted": true }`.

## Model

`LHF_MODEL` env, default `z-ai/glm-5.3-flash`, called through OpenRouter's
chat-completions endpoint (`https://openrouter.ai/api/v1/chat/completions`)
with `provider: { "data_collection": "deny", "allow_fallbacks": true }` and,
when `LHF_PROVIDER_ORDER` is set, `provider.order` from that comma list.
Fallback model on upstream failure: `LHF_FALLBACK_MODEL`, default
`openai/gpt-5.6-luna`. `OPENROUTER_API_KEY` is a function secret, never in
the repo, never in the app.

## Limitations recorded on purpose

- Enrollment is asserted by the client, not proven. A tampered client could
  list a course id it is not enrolled in and read that course's material.
  Real proof would need the server to hold Canvas credentials, which
  principle 1 forbids. Material shared this way is course-site content every
  enrolled student already sees; nothing personal is reachable.
- Section-specific announcements and per-section due-date overrides are
  shared at the course level in v1.
