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
CourseSummaryWire   { courseID, code, name, url?, term?, sectionIDs?, section? }
DocumentStub        { id, contentHash }
CourseDocumentWire  { id, courseID, course, kind, sourceID, title, url?,
                      text, updatedAt?, fetchedAt, contentHash,
                      dueAt?, pointsPossible? }        -- no `submitted`
FullySyncedCourse   { courseID, documentIDs: [string] }
CatalogEntryWire    { courseID, catalogCode, title, credits,
                      meetings: [{ sectionID, activity, weekday,
                                   startMinutes, endMinutes }],
                      components: [{ activity, credits, sectionIDs }] }
CourseProfileWire   { courseID,
                      gradingWeights: [{ name, percent, expectedCount?, dropLowest? }],
                      components: [{ name, gradingBasis?, creditUnits? }],
                      extractedAt }
```

`CatalogEntryWire.meetings[].weekday` is 1 (Sunday) through 7 (Saturday) --
the same convention `Foundation`'s `Calendar` uses on the iOS side. Penn
Labs' own meeting-day letters (`M T W R F S U`) map to it as `2 3 4 5 6 7
1`. `startMinutes`/`endMinutes` are minutes after local midnight, parsed
from Penn Labs' decimal `HH.MM` encoding of a clock time (the digits after
the point are literally minutes, not a fraction of an hour -- `15.3` is
15:30, not 15:18): hours = floor, minutes = round of the fractional part
times 100. See `_shared/catalog.ts`'s `CatalogMeeting`/`catalogEntryWire`.

`CatalogEntryWire.components` is one entry per registrar component
(lecture, lab, ...) carrying just what Grade Watcher needs to tell "the
class" apart from a same-code, separately-graded, zero-credit component --
PHYS 0151's lab is a *different Canvas course site* from its lecture. The
app resolves its own site's `section` against a component's `sectionIDs`
(the same join `_shared/catalog.ts`'s `activityForSection` does
server-side for `ask`) and reads that component's `credits` to decide
whether the site it's looking at is the credit-bearing "class" or an
attached zero-credit component.

`kind` is one of `home | syllabus | assignment | announcement | module | page | website`.
`id` is always `"{kind}:{courseID}:{sourceID}"`, computed by the client for
every kind except `website`, which the server computes itself (see "Course
websites" below) since a crawled page has no Canvas id to key on.

`CourseSummaryWire.section` is the Canvas SIS section number for *this
Canvas course site* (e.g. `"401"`), at most 8 characters matching
`^[0-9A-Za-z]{1,8}$` -- not to be confused with `sectionIDs`, which is a
student's own per-enrollment list merged onto their `enrollments` row.
`section` exists because a Penn course can be more than one Canvas site:
PHYS 0151's 1.0 CU lecture and its 0.5 CU lab are two entirely separate
Canvas sites, sharing one registrar code but not one Canvas course id, and
until `section` existed the server had no way to tell a `courses` row for
one site from a `courses` row for the other beyond their (identical) Canvas
`code`. See "Catalog" below for how `section` combines with a course's
resolved `catalog_code` to label which site a course's material came from.

## `sync` — manifest exchange, then upload

### Step 1: `{ "action": "manifest", "courses": [CourseSummaryWire], "documents": [DocumentStub] }`

Server: upserts `courses`, upserts the caller's `enrollments` for every
course listed (this is the enrollment proof; see Limitations), then answers

```
{ "coursesFresh":   [courseID],           -- server has a full sync newer than FRESH_WINDOW
  "serverManifest": [DocumentStub],       -- every live (gone_at IS NULL) doc for these courses
  "download":       [CourseDocumentWire], -- live docs whose (id, contentHash) the client didn't list
  "catalog":        [CatalogEntryWire],   -- one entry per manifest course with a resolved,
                                           -- fetched catalog_courses row (see "Catalog" below)
  "profiles":       [CourseProfileWire] } -- one entry per manifest course with an extracted
                                           -- course_profiles row (see "extract-profile" below)
```

`profiles` is one per manifest course that has had `extract-profile` build
it a `course_profiles` row; a course that hasn't been extracted yet (or
whose syllabus/pages produced nothing extractable) simply contributes
nothing this call, the same "missing is not an error" posture `catalog`
already takes. The app offers a course's `gradingWeights` to Grade Watcher
as a suggested grading scheme -- never auto-applied, since the ledger's
"nothing the student did is ever lost" invariant extends to not silently
overwriting a scheme the student already set up themselves.

Client: applies `download` to local knowledge first, then fetches Canvas
for every course NOT in `coursesFresh` (announcements are fetched for all
courses in one call regardless; they are cheap and change daily). Local
merge runs as today.

### Step 2: `{ "action": "upload", "documents": [CourseDocumentWire], "fullySyncedCourses": [FullySyncedCourse], "links"?: [LinkWire] }`

`documents` = local docs whose `(id, contentHash)` is not in
`serverManifest`. `fullySyncedCourses` = the courses the client fetched from
Canvas this run with every doc id it now holds for that course.

`links` (optional, at most 400 entries per call, each `href` at most 2048
characters) is the raw material for course-website discovery -- see
"Course websites" below:

```
LinkWire { courseID, href, text, origin }   -- origin: "page" | "assignment" | "module" | "syllabus"
```

Every `href` the client finds while extracting course material from
Canvas (a link in a page body, an assignment description, a module item, a
syllabus) is worth sending, not just ones that look like a course
homepage -- the server does the filtering (`_shared/websites.ts`'s
`candidateFromLink`), and a link the client's own heuristics would have
discarded may still score.

Server: upserts docs by id (clearing `gone_at`), sets `gone_at = now()` on
live docs of a fully-synced course whose id is absent from `documentIDs`,
sets `courses.last_full_sync_at = now()` for those courses, sets
`courses.profile_stale = true` for any course whose set of
`(id, contentHash)` for kinds `syllabus|home|page|website` changed, and
scores `links` into `course_websites` candidate rows. Answers

```
{ "accepted": n, "profileStale": [courseID], "websitesPending": [courseID] }
```

Client then POSTs `extract-profile` for `profileStale` without awaiting,
and fires `discover-websites` (at most 3 course ids per call; batch a
longer list across calls) for `websitesPending`, also without awaiting.
`websitesPending` is the affected courses (from `documents` +
`fullySyncedCourses` + `links`) that have no website verified within the
last 7 days *and* either already have a candidate row or are a CIS/CIT
course (the one department a URL can be guessed for with zero candidates
at all -- see `conventionURLs`). Maximum request body 6 MB; the client
chunks `documents` into batches of at most 200.

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
frozen system instructions → `contextDocument` → course profiles JSON,
keyed by site label (see "Catalog" below), for `courseIDs` → history → user
turn `Current date: …\n\n{excerpts}\n\nQUESTION: {question}`.

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
manifest response and only ever logged as a count. A stored row's
`components` are normalized on read (`_shared/db.ts`'s `dbRowToCatalogRow`),
since `components` is jsonb and a row can predate a shape change such as
6104d86 adding `meetings`; a row that needed that normalization
(`componentsLackMeetings`) is refetched on the next manifest call even when
otherwise fresh, so a legacy row gets replaced rather than answering forever
without a schedule.

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

Manifest exchange: alongside `structureBlock`'s prose for `ask`, `sync`'s
manifest response also carries a `catalog` array (`CatalogEntryWire`, see
"Wire types" above) for the *app itself* to read -- meeting weekday/times
the Announcement Watcher resolves a phrase like "before class Thursday"
against, rather than defaulting to a fixed end-of-day time. One entry per
manifest course whose `catalog_code` already has a fetched `catalog_courses`
row (built by `_shared/catalog.ts`'s `catalogEntryWire`, looked up by
`_shared/db.ts`'s `selectCatalogEntriesForCourses`); a course that hasn't
resolved a code, or whose code hasn't had a successful Penn Labs fetch yet,
simply contributes nothing this call rather than an error or a placeholder.

RLS: `catalog_courses` needs no enrollment gate, unlike every other table in
this schema -- it's public registrar data with no student-specific angle,
so every `authenticated` caller may `SELECT` every row. There are still no
write policies; only `sync`'s service-role client ever writes it.

Multi-site courses: a single registrar course can be more than one Canvas
*site* -- PHYS 0151 is one `catalog_code` but two separate `courses` rows,
each with its own `course_id`, both resolving to the same catalog code but
carrying different `section` values (`"401"` for the lecture site, `"151"`
for the lab site; see `CourseSummaryWire.section` under "Wire types" above).
`sync`'s manifest `catalog` array reflects this directly: it is one entry
*per manifest `courseID`*, not per unique `catalog_code`
(`_shared/db.ts`'s `selectCatalogEntriesForCourses` keeps the
`course_id`/`catalog_code` pairing rather than deduplicating catalog rows
the way `ask`'s own catalog lookup does), so a student enrolled in both of
PHYS 0151's sites gets two `CatalogEntryWire` entries, one per `courseID`,
both carrying `catalogCode: "PHYS-0151"`.

`ask` uses `section` plus the resolved `catalog_courses` row to tell the two
sites apart for the model: `_shared/catalog.ts`'s `activityForSection` finds
which component (`"LEC"`, `"LAB"`, ...) a `section` belongs to, and
`siteLabel` turns that into a label like `"PHYS 0151 — lecture site (section
401)"` or `"PHYS 0151 — lab site (section 151)"` (falling back to `"PHYS
0151 (section 002)"` when the activity can't be resolved yet, and to the
bare code when there's no section at all). `ask/index.ts`'s
`loadCourseProfiles` keys the COURSE PROFILES prompt block by this label
rather than by course code or course id, so a course split across a lecture
site and a lab site carries one profile entry per site instead of one
clobbering the other; `SYSTEM_INSTRUCTIONS` tells the model to answer a
"class"/"lecture" question from the lecture site's profile and a "lab"
question from the lab site's, and to say which site an answer came from.
The COURSE STRUCTURE block, by contrast, is per `catalog_code`, not per
site -- `_shared/prompt.ts`'s `buildMessages` dedupes `catalog` rows by
`catalogCode` before calling `structureBlock`, so a course with two synced
sites still gets exactly one registrar-structure paragraph, not two
identical copies.

## Course websites

The problem this solves: a lot of Penn courses -- all of CIS, for one --
keep their real material on an external course website instead of Canvas.
Until this existed, none of that reached `ask`: a Canvas course site with
just a home page and a syllabus stub told the assistant almost nothing
about grading, the schedule, or projects, even though the professor's own
site had all of it.

**Discovery.** A URL becomes a `course_websites` candidate one of four
ways, recorded as `source`:

- `canvas-link` -- a link the client reported in `sync`'s upload `links`,
  scored by `_shared/websites.ts`'s `candidateFromLink`: +3 confidence when
  the URL contains the course's compact code (`cis2400`, `cis-2400`,
  `~cis2400`), +2 when the anchor text reads like "course website"/"course
  page", +1 when the host is `*.upenn.edu`. A link on an `IGNORED_HOSTS`
  host (Canvas, Gradescope, Ed, Zoom, Panopto, YouTube, Google Calendar/
  Docs/Forms, ...) is never a candidate.
- `cis-directory` -- an entry from the CIS Advising Handbook's course
  directory (`https://advising.cis.upenn.edu/course-dir/`), fetched by
  `discover-websites` at most once per 24 hours *total* (across every
  student's call, not once per student) via the service-role-only
  `directory_cache` table.
- `convention` -- the guessed `~courseN/current/` pattern off
  `seas.upenn.edu` and `cis.upenn.edu`, CIS/CIT only.
- `penn-labs-syllabus` -- Penn Labs' own `syllabus_url` field on the
  course's `catalog_courses` row, when present (often `null`).

**Verification.** `discover-websites` fetches every `candidate` row (and
every `verified` row whose `verified_at` is more than 7 days old) and
checks it with `verifyPage`: does the page's title/heading/first 3000
characters of body state both this course's code and the current
semester (`catalog_courses.semester`, matched via `termAliases` -- "2026C"
also matches "fall 2026", "26fa", "fa26", ...)? Both must hit for
`status` to become `verified`; a code match with no term match (a stale
prior-semester page) or vice versa leaves it `candidate`; a page that
doesn't match either becomes `rejected` and is not re-fetched on future
calls. A 404 or network failure leaves the row untouched -- neither
outcome is evidence the URL is wrong, only that this attempt to check it
failed.

**Crawling.** Once a course has a `verified` site, `discover-websites`
crawls it (`_shared/crawl.ts`): same host, same-or-deeper path as wherever
the start URL's redirects landed (so `~cis2400/current/` -> `~cis2400/
26fa/` never wanders into `~cis1210/...`), breadth-first, at most 40 pages,
depth 2, an 8-second per-request timeout, honoring `robots.txt`'s
`Disallow` for `User-agent: *`, and never following a link onto an
`IGNORED_HOSTS` host. A linked PDF (capped at 200 KB) is read via `unpdf`;
everything else is read as HTML. Re-crawled at most once per 7 days per
site. Every page becomes a `course_documents` row with `kind: "website"`,
`id` and `source_id` derived from a hash of the page's own URL (a crawled
page has no Canvas id to key on) rather than client-computed; a
previously-crawled page absent from a fresh crawl is marked `gone_at`, the
same rule `sync`'s fully-synced-course upload step applies to Canvas
documents. A crawled page whose title or URL matches
`/syllabus|polic|grading|logistics/i` also sets `courses.profile_stale =
true`, since that page is exactly the kind `extract-profile` wants to read
(see below).

## `discover-websites`

Request `{ "courseIDs": [courseID] }`, at most 3 per call (batch a longer
`websitesPending` list across calls). The caller must be enrolled in every
listed course. Runs discovery, verification and (for at most one
newly-or-still-eligible site per course) a crawl for each, within a 45
second overall budget. Response:

```
{ "discovered": [ { "courseID", "url", "status" } ], "crawled": [courseID] }
```

`status` is the row's status *after* this call (`candidate`, `verified` or
`rejected`) for every candidate this call looked at, whether or not it
changed. `crawled` lists only the courses a crawl was actually attempted
for this call. Logs counts only, never a URL, title or page body.

## `extract-profile`

Request `{ "courseIDs": [courseID] }`. For each listed course that the
caller is enrolled in and whose `profile_stale` is true, the server builds
one `course_profiles` row from that course's live `syllabus`, `home` and
`page` documents plus any `website` document whose title or URL matches
`/syllabus|polic|grading|logistics|schedule/i` (at most
`PROFILE_INPUT_CHARS`, default 60000; input order is syllabus, then a
matching website page, then home, then page) and clears `profile_stale`.
Response `{ "updated": [courseID] }`.

Profile JSON (every field optional, strings are verbatim quotes or close
paraphrases of the source, never inferred):

```
{ "gradingWeights": [ { "name", "percent", "expectedCount"?, "dropLowest"? } ],
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

A `gradingWeights` entry's "expectedCount" is the number of items the
syllabus states that category has ("12 labs", "three midterms" -> 3);
"dropLowest" is how many of that category's lowest scores the syllabus
says are dropped ("the lowest two homework grades are dropped" -> 2). Both
are plain non-negative integers, never inferred, omitted whenever the
syllabus doesn't state one. Grade Watcher uses these to tell a student
they're missing an expected item and to apply the syllabus's own drop rule
when averaging a category, rather than the app guessing either from the
grades it has actually seen post.

## `extract-announcement`

Request `{ "announcementID", "courseCode", "title", "message", "postedAt"?, "now": ISO8601 }`.
Response `{ "assignments": [ { "title", "dueAt"?, "kind" } ] }`, where `kind`
is `"submission"` (handed in or completed on a platform -- homework, a
quiz, a survey, an upload) or `"preparation"` (read/watch/review/bring/
prepare, nothing to hand in); the model defaults to `"submission"` when it
omits or misstates `kind`. Replaces the user-key
`ClaudeAnnouncementExtractor`. Counted against the same daily quota.

The server resolves `courseCode` against the caller's own enrollments (the
`courses` row whose `code` matches case-insensitively and ignoring
space/dash differences -- `_shared/announcement.ts`'s `courseCodesMatch`)
to load that course's registrar catalog row and syllabus-derived profile,
and folds three optional blocks into the model's user message ahead of the
announcement body, in this order: `COURSE STRUCTURE` (`structureBlock` for
the one resolved course), `CLASS MEETINGS` (one line per class meeting,
e.g. `LEC Tue 10:15–11:44 (section 401)`, sorted by weekday then start
time -- see `_shared/catalog.ts`'s weekday/time convention under "Wire
types" above), and `COURSE PROFILE` (a small stable-JSON subset of the
course's profile -- only `gradingWeights`, `latePolicy`, `components`,
`keyPolicies`). This is what lets the model resolve "before class
Thursday" to the section's actual start time (`ANNOUNCEMENT_INSTRUCTIONS`
tells it to prefer this over guessing 11:59 PM) instead of the
one-size-fits-all end-of-day default it used before class meeting times
existed anywhere in this system. Any step of that resolution coming up
empty -- no enrollment match, no catalog code, no fetched catalog row, no
profile row -- degrades to omitting that block, never an error; extracting
a task never depends on this context being available.

`ANNOUNCEMENT_INSTRUCTIONS` also draws an explicit line the on-device
heuristic used to miss: a sentence in passive voice or the first person
about the instructor's *own* action ("the slides discussed today have been
posted", "I uploaded the recording", "we will cover chapter 6 next week")
is informational and yields no task, even when it names course material by
title -- this is the fix for the real failure that turned "The slides
discussed today have been posted." into an overdue assignment.

## `map-categories`

The problem this solves: Grade Watcher's grading scheme needs to know
which Canvas assignment *groups* feed which of the syllabus's grading
categories ("Problem Sets" is 20% -- but which Canvas group, or groups, is
that?), and a student shouldn't have to build that mapping by hand every
semester when a classmate's client could just as well have solved the same
mapping already.

Request `{ "courseID": string, "groups": [ { "id", "name", "items": [
{ "id", "name", "pointsPossible"?, "submissionTypes"? } ] } ] }` -- Canvas
assignment-*group* names and their items' names, points possible, and
submission types **only**. Never a score, a submission, or anything else
about one student's own work; `pointsPossible` and `submissionTypes` exist
purely to help the model tell a real graded item from a zero-point
placeholder or an attendance tool entry. `map-categories/index.ts`'s
`parseMapCategoriesBody` (`_shared/categoryMap.ts`) rebuilds every
group/item as a new object naming exactly these fields, so any other key a
client's JSON happens to carry (a `score`, a `submitted` flag) is never
read, not merely ignored-but-present -- the same defense-in-depth
`course_documents` having no `submitted` column already gives principle 2.

Limits, enforced by rejecting the whole request with 400 rather than
silently truncating it: at most 40 groups, at most 400 items total across
every group, every group/item name at most 200 characters.

The caller must be enrolled in `courseID` (`is_enrolled`, the same gate
`discover-websites` uses). When the course has no `course_profiles` row
yet, or one whose `profile.gradingWeights` is empty -- no syllabus
extraction has produced grading categories to map onto -- the response is
`{ "mapping": null }` immediately, with no model call and no quota spent.

Response `{ "mapping": null }` (see above) or:

```
{ "mapping": {
    "categories": [ { "name", "canvasGroupIDs": [string], "itemIDs": [string], "expectedCount"? } ],
    "excludedItemIDs": [string],
    "reasons": { "<id>": string },
    "extractedAt": ISO8601,
    "structureHash": string } }
```

`categories[].name` is always one of the course's `gradingWeights[].name`
values verbatim -- a name the model invents is dropped, category and all.
Every id anywhere in the response (`canvasGroupIDs`, `itemIDs`,
`excludedItemIDs`, `reasons` keys) is an id the request actually listed;
an unknown id is dropped silently. An id may appear in at most one
category -- group ids and item ids each have their own "first category to
claim it wins" rule, evaluated in `categories`' own array order.
`expectedCount` survives only as a non-negative integer, omitted
otherwise. `_shared/categoryMap.ts`'s `sanitizeCategoryMapping` is a pure,
independently-tested function enforcing all of this; the app treats the
whole response as a suggestion the student confirms, the same posture it
already takes toward `sync`'s `profiles.gradingWeights`.

**Cache, per course, shared across every enrolled classmate.** A course's
assignment-group *structure* (names, points, submission types) is the same
fact for every student in it, exactly like `course_profiles.profile`
already is -- so the mapping is cached on that same row, not per student.
`structureHash` is the first 16 hex characters of a sha-256 digest over the
request's groups/items sorted by id (order-independent -- the same
discipline `profileSourceHash` and `buildMessages` already hold their own
hashes/prompts to), computed by `_shared/categoryMap.ts`'s `structureHash`.
When a request's own `structureHash` matches `course_profiles.
category_map_hash`, the stored `category_map` is re-validated against the
live request's own valid-id/name sets (the same normalize-jsonb-on-read
discipline `dbRowToCatalogRow`/`profileRowToWire` already apply, per
CLAUDE.md's jsonb trap) and returned with **no model call and no quota
spent** -- otherwise the model is called, the sanitized result is stored
on `course_profiles.category_map`/`category_map_hash`/`category_map_at`
(`20260910120000_category_map.sql`), and quota is spent exactly once for
that call.

Quota: `MAP_DAILY_LIMIT` requests per user per UTC day (default 20),
recorded through the same shared `ask_usage` counters (and the same
`ASK_MONTHLY_GLOBAL_LIMIT`) `ask`/`extract-profile`/`extract-announcement`
already write to -- one pool of per-user daily and global monthly figures
across every model-calling function, not a separate counter per function.
A cache hit, or a `mapping: null` response, never calls
`checkAndConsumeQuota` at all.

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
