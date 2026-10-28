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

### Identity resolution (linked devices)

The Chrome extension signs up as its own anonymous user and is then paired
to a phone (`pair`, below). After verifying the token, every function looks
the caller up in `device_links` (one query). `AuthContext` then carries
`callerUserId` (the token's user), `deviceOwnerLinked` (true for a linked
device) and `userId`, which is the **owner's** id when the caller is a
linked device and the caller's own id otherwise. Every function scopes
enrollments and the ask quota by `userId`, so a linked device is the same
student as its phone with no per-function change. Only `pair`,
`device-sync` and `delete-account` read `callerUserId`. A failed lookup
fails the request (502): treating a linked device as a fresh student would
be wrong silently. The one exception is the table not existing yet
(`42P01` / `PGRST205`): then no link can exist and the caller is treated
as unlinked, so a function deployed before the migration keeps serving
every phone. Apply the migration before the extension pairs, all the same.

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
                      examDates: [{ name, date?, text }],
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

`kind` is one of `home | syllabus | assignment | announcement | module | page | website | ed`.
`id` is always `"{kind}:{courseID}:{sourceID}"`, computed by the client for
every kind except `website`, which the server computes itself (see "Course
websites" below) since a crawled page has no Canvas id to key on.

`ed` is an Ed Discussion post (see `docs/ED_DISCUSSION.md`). `sourceID` is the
Ed thread id, so `id` is `"ed:{courseID}:{threadID}"`, and `courseID` is still
the Canvas course id the thread's Ed course was matched to. `text` is plain text
converted from Ed's XML body. Author names are never included, in `text` or
anywhere else. Only announcements, pinned threads and staff posts are
uploaded; a student's post never becomes a document. `ed` is content like
`announcement`: it is never profile or syllabus input, and it does not make a
course's profile stale. One more exception: the upload step's complete-set
rule (Step 2 below, "sets `gone_at` on live docs of a fully-synced course
whose id is absent from `documentIDs`") skips every **window kind**,
`announcement` and `ed`. The kinds split in two. A *census* kind (home,
syllabus, assignment, module, page, website, file) is the same for every
enrolled student, so one student's complete fetch is the truth. A *window*
kind is a stream and each client fetched only a window of it: a student not
yet on Ed, or without the Ed tab, a client whose announcements request
failed, or one whose window is narrower, legitimately reports a
fully-synced course with fewer (or no) such ids, and that must not erase
classmates' pooled posts. So window-kind rows are only ever upserted by an
upload, never retired by one, whichever client reports and whoever
collected them. In their place the server ages them out on read: a
window-kind row whose `coalesce(updated_at, fetched_at)` is more than 120
days old is never served (not in `download`, `serverManifest`, or the
upload's profile-staleness snapshots) and may be deleted by a later
cleanup; nothing deletes it today. (For `ed`, `updated_at` is the thread's
last activity; for an announcement it is the post time.) A manifest also
sends at most the newest 150 window-kind rows per course in `download`;
`serverManifest` still lists all of them, so a client does not re-upload
the rest. Live-document reads are paginated (500 rows a page, ordered by
`id`) because the project's PostgREST `max_rows` is 1000 and a larger
single select is silently truncated.

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

### Step 1: `{ "action": "manifest", "courses": [CourseSummaryWire], "documents": [DocumentStub], "acceptsKinds"?: [string], "client"?: "phone" | "extension" }`

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

`acceptsKinds` (optional, at most 32 strings of at most 32 characters;
unknown strings are ignored) lists the capability-gated document kinds the
client can decode. Today that is only `"file"`: documents of kind `file`
are left out of **both** `download` and `serverManifest` unless `acceptsKinds`
includes it. Absent means the kinds that existed before the field, which is
every shipped phone. A shipped phone drops an unknown kind without
failing (`CourseDocumentWire.kind` is a string and `document()` returns
nil), but it never stores what it dropped, so without the gate it would
download every file document again on every sync. `client` is
described under Step 2; on the manifest it only matters for the pairing
check below.

`profiles` is one per manifest course that has had `extract-profile` build
it a `course_profiles` row; a course that hasn't been extracted yet (or
whose syllabus/pages produced nothing extractable) simply contributes
nothing this call, the same "missing is not an error" posture `catalog`
already takes. The app offers a course's `gradingWeights` to Grade Watcher
as a suggested grading scheme -- never auto-applied, since the ledger's
"nothing the student did is ever lost" invariant extends to not silently
overwriting a scheme the student already set up themselves.

`examDates` is the exams the syllabus names, from the same stored profile
(see "extract-profile" below), and is what the app files syllabus exam
cards from. It is always present, `[]` when there is none. `name` and `text`
are the extracted strings; `date` is present only when the stored date is a
real `YYYY-MM-DD` calendar day (a date-time such as
`2026-10-23T18:00:00-04:00` is cut to its day: the time and offset are
dropped, since the app files the exam as an all-day entry). A date written
any other way ("October 23", "10/23", "2026-02-30") is omitted and the entry
goes out undated rather than being guessed at or dropped; entries with no
usable name, and anything malformed in the stored jsonb, are dropped without
failing the call. The app ignores undated entries. A dated entry for an exam
the phone also read from the syllabus text replaces the on-device reading
(same exam, same ledger row); an app build from before this field existed
ignores the key and keeps reading the text. Additive: no existing field
changed and no request changed.

Client: applies `download` to local knowledge first, then fetches Canvas
for every course NOT in `coursesFresh` (announcements are fetched for all
courses in one call regardless; they are cheap and change daily). Local
merge runs as today.

### Step 2: `{ "action": "upload", "documents": [CourseDocumentWire], "fullySyncedCourses": [FullySyncedCourse], "links"?: [LinkWire], "client"?: "phone" | "extension" }`

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

`client` (on both steps; absent means `"phone"`, every shipped build; any
other value is a 400) says which kind of client is reporting. Upload stamps
`course_documents.collector` (`'phone'` or `'extension'`) on every document
it upserts, so the row belongs to whoever uploaded it last. `file` is an
accepted document kind on upload (extracted text of a Canvas File, at most
200,000 characters like every kind). It is never profile input and does not
set `profile_stale`.

`client: "extension"` from a caller that is not a linked device is refused
`403 not_paired`: the extension pairs before it syncs, so it is one student
with the phone rather than a second one.

Server: upserts docs by id (clearing `gone_at`), sets `gone_at = now()` on
live docs of a fully-synced course whose id is absent from `documentIDs`
(when the reporting `client` is the phone, only docs with
`collector = 'phone'`; when it is the extension, docs of any collector;
window kinds, `announcement` and `ed`, are exempt for both), sets `courses.last_full_sync_at = now()` for those courses, sets
`courses.profile_stale = true` for any course whose set of
`(id, contentHash)` for kinds `syllabus|home|page|website` changed, and
scores `links` into `course_websites` candidate rows. Answers

```
{ "accepted": n,
  "rejected": [ { "id": string, "reason": string } ],
  "profileStale": [courseID], "websitesPending": [courseID] }
```

A document that fails validation (an empty title or text, an id that does
not match its own kind/courseID/sourceID, an unknown kind) is reported in
`rejected` (`id` is "" when the entry had none) and does not fail the
batch: the rest are upserted and counted in `accepted`. `rejected` is `[]`
when there are none. A rejected document is never upserted and never
changes what the complete-set rule retires. Resending it unchanged will be
rejected again, so a client should log it and move on.

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

Size caps (`_shared/askRequest.ts`, since 2026-10-27): `contextDocument` at
most 400,000 characters, `excerpts` 100,000, `question` 20,000, `history` 40
turns and 100,000 characters in all. A body over any cap is refused before the
model is called with `413 { "error": "payload_too_large", "message":
"ask request over size cap: <field>" }` (the message names the field, never
echoes content) and an `ask_outcomes` row of outcome `client_error`. A wrong
shape is a `400 bad_request`. The caps are ceilings on abuse, not on a heavy
student: a syllabus-sized prompt is about 56,000 characters of context
document.

A request may also carry an optional `x-lhf-probe` request header (at most
40 characters, `[A-Za-z0-9-]` only) to tag the `ask_outcomes` row this
request produces as belonging to a specific harness run rather than a real
student's question -- honored by both `ask` and `ask-canary`, since tagging
a row doesn't change how the request is served. A malformed or missing
header just leaves the row untagged.

Response is `text/event-stream`. Every event is one `data:` line of JSON:

```
data: {"type":"delta","text":"…"}
data: {"type":"done","usage":{"promptTokens":n,"completionTokens":n,"cachedTokens":n}}
data: {"type":"error","code":"quota_exceeded"|"upstream"|"bad_request","message":"…"}
```

The model is instructed to end with the same `<sources>COURSE|kind|detail;…</sources>`
line the app already parses (`SourcesBlockSplitter`); the server passes
model text through untouched. Since 2026-10-25 `kind` is one of `syllabus`,
`canvas`, `website`, `announcement` or `ed` (an excerpt labelled "ed
discussion"), and `detail` is the title of the excerpt or document the fact
came from, copied exactly as it appears between the quotes in the excerpt
line (only when no excerpt applies, a few words locating the fact), because
the phone links a source chip only when `detail` contains the cited
document's title as whole words. Errors before streaming starts are plain
JSON with an HTTP status: 401 unauthorized, 429
`{ "error": "quota_exceeded", "resetAt": ISO8601 }`, 502 upstream.

Server prompt order (stable prefix first, for provider prefix caching):
frozen system instructions → `contextDocument` → course profiles JSON,
keyed by site label (see "Catalog" below), for `courseIDs` → history → user
turn `Current date: …\n\n{excerpts}\n\nQUESTION: {question}`.

`ask` answers from the context and excerpts it was already handed, not by
reasoning the problem out. The default model was `z-ai/glm-5.3-flash`, a
thinking model that, with `reasoning` left unset, spends output tokens on
hidden reasoning before emitting any answer text at all on a large enough
prompt — the 2026-09-14 incident below. `reasoning: { effort: "low" }`
(OpenRouter's `{ enabled: false }` is rejected with a 400 by this model;
`effort: "low"` is accepted) cut that model's reasoning spend from ~300
tokens to ~6, but 2026-09-22 canary runs against the live function found it
does not fix the model's real failure mode: 30 timed probes still saw 12
take over 8s to first delta and one take 66s, several of them with *zero*
reported reasoning tokens — the tail is provider time-to-first-token, not
thinking, and no `reasoning` setting touches a queueing delay on
OpenRouter's or the provider's side.

**The primary model and the hedge.** The default primary model is now
`openai/gpt-4.1-mini` (`LHF_MODEL` still overrides it) — not a thinking
model, no `reasoning` field on its request at all, and 10/10 canary probes
answered correctly about dates between 1.9s and 3.0s to first delta. The
default fallback model is `z-ai/glm-5.3-flash` (`LHF_ASK_FALLBACK_MODEL`
overrides it), with `reasoning: { effort: "low" }` (`_shared/fallback.ts`'s
`reasoningFor`, applied to any model whose id starts with `z-ai/`,
primary or fallback). Rather than waiting the primary out and only then
trying the fallback, `ask` hedges: if the primary hasn't produced a content
delta within `HEDGE_AFTER_MS` (5s), the fallback is started *concurrently*,
and whichever model produces the first content delta wins — the other is
aborted immediately, and once either has produced content the race is over
for good (no switching mid-answer). A primary that fails outright or
exhausts its whole stream with zero content *before* the hedge would even
fire skips straight to the fallback alone, sequentially, since there is
nothing left to race. Either way this all happens before the SSE response
is ever committed to the client — a 502 is still only possible if *both*
models come up with nothing. The whole race (primary alone, or primary and
fallback together) is bounded by `TOTAL_BUDGET_MS` (45s, well inside the
phone's own 60s `URLSession` timeout); once a winner is streaming, there is
no further time limit here. `MAX_TOKENS` stays 3000, raised from the
original 1200, so an answer with low- or no-effort reasoning has headroom
to spare. Models tried and rejected along the way on correctness rather
than latency: Gemini Flash/Flash-Lite, `glm-4.5-air` and `deepseek-v3.1`
answered fast but got a plain "what's due tomorrow?" wrong.

`ask_outcomes.detail` records which of these happened: absent for the
ordinary case (the primary answered on its own), `"hedged at <ms>ms; winner
<model>"` when the race was actually run, and `"fallback from <primary>
after <empty|upstream_error>"` when the fallback ran alone because the
primary never made it to the hedge. `ask_outcomes.model` is whichever model
actually produced the streamed answer, not necessarily the primary.

Quota: `ASK_DAILY_LIMIT` requests per user per UTC day (default 40) and
`ASK_MONTHLY_GLOBAL_LIMIT` requests across all users per calendar month
(default 100000). **A request is reserved before the model is called and
settled afterwards** (since 2026-10-27, hardening BE-C): `reserve_ask_usage`
checks both limits and charges one request in a single statement, so ten
parallel requests at 39 of 40 get exactly one reservation (the daily limit
is atomic; the global monthly limit is a snapshot read in the same call and
can overshoot by the number of requests in flight), and a refused request
never reaches the model and never moves the counter. `settle_ask_usage`
then adds the request's tokens to the day it was reserved on, in the
stream's `finally`, so it runs whether the stream ends cleanly, breaks, or
the student leaves. A reserved request stays counted if the model was called
and the student was shown something or walked away; it is given back
(`settle_ask_usage` with `p_refund`) only when it never reached the model or
failed before the student was shown anything *while still connected*.
Refunding an abandoned request would make "send a large prompt, hang up, get
the unit back" a free loop, so a client that left is never refunded. When the
client goes away (`req.signal`, or the response body being cancelled) every
upstream model request is aborted, including a hedge that would have started
afterwards. Questions and answers are never stored. The same reservation
guards `extract-announcement` (given back on a failure while the student is
still there, so a deterministic failure the phone keeps retrying cannot drain
the asks), `extract-profile` and `map-categories` (charged up front and not
given back, as before, and deliberately not aborted on disconnect: their
work is shared with classmates). The older `record_ask_usage` and
`ask_usage_counts` RPCs remain in the database for functions deployed before
`20261027100000_reserve_ask_usage.sql`; apply that migration before
deploying functions that call the new pair.

The reservation RPC carries a 1.5s client-side deadline and the settle RPC
4s (`_shared/quota.ts`'s `reserveUsage` / `settleUsage`), and both fail open
with a `console.warn` rather than propagate the failure: a reservation that
times out or errors is treated as "allow this call, unmetered" (no lease, so
nothing to settle), and a settle that times out or errors just leaves one
request's tokens uncounted, or one refund undone. A database stall degrades
the quota counter to "unmetered for that call," never a 502 -- the counter
protects the aggregate budget, not the individual student, so it must
never be the thing that makes `ask` (or the extract functions) unusable.
This follows a real incident: on 2026-09-13 20:47 UTC a student's `ask`
request came back 502 because `ask_usage_counts` hit Supabase's API-gateway
timeout — about 5 s in front of PostgREST — during a stall of that hop
(`ask: ask_usage_counts failed Gateway Timeout` in the function log; the
logs showed Postgres idle and the RPC never slower than 23 ms), even
though the RPC itself is two trivial lookups on a tiny table.

**Outcome telemetry.** Every call to `ask` (and `ask-canary`, below) writes
one `ask_outcomes` row via `record_ask_outcome`, classified as `answered`
(any `delta` text reached the student), `empty` (the stream ended clean
with zero characters -- the 2026-09-14 "reasoning ate the whole output cap"
shape this table exists to catch happening again, unnoticed, a second
time), `upstream_error` (the model backend failed, before or during
streaming), `quota` (the 429 path) or `client_error` (a malformed request
body, a refused or oversized one, or, with `detail` `"client disconnected"`, a
student who left mid-stream); `timeout` is reserved in the schema for a
future caller (such as a canary harness's own client-side deadline) and nothing in `ask/index.ts`
produces it today. The row carries the model, token counts (including
`reasoning_tokens` when OpenRouter's response reports one), content-length
and delta-count counters, latency, and -- for a failure -- the upstream
status and a capped error message (for an upstream error, the status and
the length of the provider's error body; since 2026-10-27 never the body's
text, in the log or the row, because a provider's refusal can quote the
prompt back), but never the question, the context document, the excerpts or
the answer; `probe` carries the `x-lhf-probe` tag
above, or is `null` for an ordinary request. Both this write and
the usage settlement (`settle_ask_usage`) are scheduled via Supabase Edge Runtime's
`EdgeRuntime.waitUntil` rather than awaited before the SSE stream's `done`
event is yielded (the SSE stream itself is always yielded last): awaiting
either one first would hold up the student's answer for a database
round-trip that has nothing to do with it, and the earlier code, which
awaited `record_ask_usage` *after* `yield done`, had it backwards in the
other direction -- on Supabase's Edge Runtime the isolate can be torn down
as soon as the client has read the last SSE event, before an `await` placed
after that generator's last `yield` is guaranteed to run at all,
under-counting usage in a way nothing surfaced. `ask_outcomes` is written
alongside `ask_usage` for exactly the same reason and the same fix applies
to both. This table has no read policy for `anon`/`authenticated` at all
(see `20260922090000_ask_outcomes.sql`) -- it is a system diagnostic, not
something a student's own client ever reads back.

## `ask-canary`

**Closed by default (2026-10-27).** The function answers only a request that
carries `x-lhf-probe-secret` equal, compared in constant time, to the
function secret `LHF_PROBE_SECRET`. With that secret unset, or with a missing
or wrong header, every request (OPTIONS included) gets Supabase's own
`404 { "code": "NOT_FOUND", "message": "Requested function was not found" }`,
so a gated canary looks undeployed. A valid anonymous JWT alone no longer
opens it: before this, anyone could pick the model, token cap and provider on
LHF's own OpenRouter key through it. Even with the secret, `probe` values are
held to a policy (`_shared/probe.ts`'s `ProbePolicy`):

- `model` and `fallbackModel` must be `openai/gpt-4.1-mini`,
  `z-ai/glm-5.3-flash`, the current `LHF_MODEL` / `LHF_ASK_FALLBACK_MODEL`, an
  entry of the comma-separated secret `LHF_PROBE_MODELS`, or start with
  `invalid/` (which cannot run; it is how to force the primary to fail).
- `maxTokens` is clamped to 4096, `hedgeAfterMs` to 30000, `temperature` to
  0..2.
- `provider` may carry only `order` (at most 8 plain names),
  `allow_fallbacks` and `data_collection: "deny"`; `reasoning` only `effort`
  (`low`/`medium`/`high`), `enabled` and `exclude`.

A well-formed value the policy refuses is a `400 bad_request` whose message
names the field (`probe.model is not on the canary's model allow-list`), with
a `client_error` outcome row; it is never silently replaced by the default,
which would record the default model's numbers under the candidate's tag. A
wrong-typed field is still dropped, as before. The harness
(`scripts/ask-probe.mjs`) reads the secret from the `LHF_PROBE_SECRET`
environment variable.

A harness-only twin of `ask` (`ask-canary/index.ts`), serving the exact same
`handleAsk` logic (`ask/index.ts`) with one difference: an optional
`probe` object in the request body is honored, letting a harness try a
different model, token cap, reasoning shape, provider order, or a
truncated context document against the identical prompt-building and
streaming code production `ask` runs, so a canary result actually predicts
production instead of exercising a parallel implementation that could
drift from it.

```
{ ...the same "ask" request body...,
  "probe"?: { "model"?: string, "maxTokens"?: number, "reasoning"?: any,
              "temperature"?: number, "provider"?: any,
              "contextTrimChars"?: number, "fallbackModel"?: string,
              "disableFallback"?: boolean, "hedgeAfterMs"?: number } }
```

`model`, `maxTokens` and `temperature` replace `ask`'s own constants for
this call only. `reasoning` and `provider` are forwarded verbatim as
OpenRouter's `reasoning`/`provider` request fields respectively -- `provider`
*replaces* the `data_collection`/`allow_fallbacks`/`order` object `ask`
would otherwise send, rather than merging with it; `reasoning` overrides
only the *primary* candidate's reasoning shape (the fallback candidate
always gets `reasoningFor`'s automatic choice -- point `model`, not
`fallbackModel`, at it to probe its own reasoning shape instead).
`contextTrimChars` truncates `contextDocument` to that many characters
before the prompt is built, which is what lets a harness reproduce the
2026-09-14 "reasoning ate the whole output cap" failure at a chosen prompt
size without a real 14.5k-token syllabus fixture on hand. `fallbackModel`
overrides the model `ask` races/falls back to (e.g. pairing it with a
bogus `model` forces the primary to fail immediately and proves the
fallback alone can answer); `disableFallback` turns off both the fallback
*and* the hedge for this call, so a harness can measure the primary model
by itself; `hedgeAfterMs` overrides how long the primary gets before the
fallback starts racing it, e.g. a near-zero value to exercise the race path
deterministically. A `probe` field sent to production `ask` (rather than
`ask-canary`) is silently ignored, never a 400 -- a client that happens to
send one, or a future harness pointed at the wrong URL, isn't punished for
it. This function still enforces the same quota and still writes
`ask_outcomes` rows (tag a run with the `x-lhf-probe` header above to tell
it apart from real traffic); it is an overridable door, not
an unmetered one.

## Catalog

The problem this solves: a Canvas course site is one thing, but the
registrar course underneath it can be several -- PHYS 0151 is one Canvas
site containing a 1.0 CU lecture and a 0.5 CU lab, and nothing before this
told `ask` that, so a question about "the class" could get answered from
whichever component's syllabus text happened to be retrieved.

Source: Penn Labs' public Penn Courses API (the backend behind Penn Course
Review), `GET https://penncoursereview.com/api/base/{semester}/courses/{DEPT-NNNN}/`,
no auth, no key. `{semester}` is always explicit, from `_shared/catalog.ts`'s
`academicSemester(now)`: the calendar date in America/New_York decides it
(Jan 1 - May 20 -> `YYYYA` spring, May 21 - Aug 15 -> `YYYYB` summer,
Aug 16 - Dec 31 -> `YYYYC` fall; e.g. `2026C`). The date decides because the
app does not send the Canvas term (`courses.term` is null) and Penn Labs'
`current` is whatever is open for registration, not what is in session; there
is no fallback to `current`. A row whose `semester` differs from
`academicSemester(now)` is refetched on the next manifest call however fresh
it is, and is never served: `ask` drops it from COURSE STRUCTURE and the
manifest's `catalog` omits it (`rowsForSemester`). Rollover incident,
2026-10-15: Penn Labs flipped `current` to `2027A` for advance registration,
so refetches stored Spring 2027 rooms and times for Fall 2026 students, and
fall-only courses (CIS 2620) 404ed and kept stale rows. `{DEPT-NNNN}` is the Canvas course code with its space
replaced by a dash (`PHYS 0151` -> `PHYS-0151`; see `_shared/catalog.ts`'s
`catalogCode`). Review-score fields the response also carries
(`course_quality`, `instructor_quality`, `difficulty`, `work_required`, at
both the course and section level) are Penn Labs' own aggregated Penn
Course Review data, not the registrar's, and are never stored -- out of
scope for this table on purpose.

What is kept from each section: its activity (lecture, lab, ...), credits,
and weekly meetings (weekday, start and end minutes after local midnight,
and the meeting's `room`, `null` when Penn Labs gives none or an empty
string -- an online section), plus each section's instructor names, stored
per component as `instructorsBySection` (section id -> names, trimmed,
deduped, sorted for byte stability; a section with no named instructor has
no key). Rooms and instructors feed only `ask`'s structure block; the
`CatalogEntryWire` the app receives is unchanged.

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
without a schedule. The same rule covers rooms and instructors
(`componentsLackSectionDetails`): a stored meeting with no `room` key, or a
component with no `instructorsBySection` key, marks a row written before
those were kept, and it is refetched even when fresh. The test is key
*presence*, never null-ness: a stored `room: null` or
`instructorsBySection: {}` is a real answer (an online section, no listed
instructor), and testing the value would refetch such a course on every
manifest call forever.

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

After the components sentence each course gets one `Sections:` sentence
(omitted when the course lists no sections), for example `Sections: 151 Lab
— Mon 3:30–5:29 PM, DRLB LAB, Peter Harnish; 401 Lecture (the student's
section) — Mon, Wed, Fri 10:00–10:59 AM, DRLB A1, Diana Van Winkle.` Each
item is the section number (the last dash-separated token of its id, the
number in the profile block's "(section 151)" site label), the component's
label, then days, times, room and instructors. Components follow activity
order and sections are sorted by id; meetings with the same span merge into
one weekday-ordered day list and different spans are joined with "and";
times are 12-hour with one AM/PM when both ends share it; the room clause is
dropped for a null room, the instructor clause when none, and a section with
no meetings reads "time not listed". At most 8 sections are listed per
component, then `and N more sections`; the student's own sections are always
listed (first) and marked "(the student's section)". `ask` derives those
from the same `courses` rows (`section`, `catalog_code`) it already reads
for the profile labels, enrolled ids only, and passes them to
`structureBlock` as `ownSectionsByCatalogCode`. The block holds the weekly
pattern only: never exam rooms or one-off room changes, which the system
instructions tell the model come only from the context document or
excerpts.

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

**What it may fetch** (since 2026-10-27, hardening BE-F; `_shared/netguard.ts`).
Candidate URLs include any link a phone reported from a course page, so the
function holds every request, from verification and the CIS directory to
`robots.txt` and each crawled page, to these rules:

- **https only**, on the default port, no credentials in the URL, and the
  host must be a *name*: never an IP literal, never a name that only means
  something inside a network (`localhost`, a single label, `*.local`,
  `*.internal`, `*.intranet`, `*.lan`, `*.home.arpa`, `*.corp`, and the other
  reserved top-level names). **Any public host is allowed by default**,
  because a course's own site is often on its own domain (`cis1912.org`,
  `*.github.io`, a lab's site) and finding those is what discovery is for.
  The **host allow-list is opt-in**: setting the function secret
  `LHF_DISCOVERY_HOSTS` to a comma-separated list of suffixes restricts
  discovery to `upenn.edu` plus those suffixes (a blank value counts as
  unset). It is the switch for narrowing the function if it is ever abused.
  A candidate the rules refuse is left exactly as it was, like a network
  failure, so it is picked up again if the rules change. A `verified` site
  the rules refuse is **skipped for that call**: nothing is fetched, no
  existing website document is marked gone, and `last_crawled_at` is not
  stamped, so the next call tries it again instead of waiting seven days. That
  holds for a refusal found up front (an internal name, off the allow-list,
  resolving to a private address, or an address check that cannot run on this
  runtime) and for one found on the way (the start URL redirecting to a host
  the rules refuse), and the course is left out of the response's `crawled`
  list. It does not hold for a site that answered and had nothing to read, or
  returned a non-2xx start page: those are still a crawl that found no pages,
  and still retire the course's earlier website documents.
- **Public addresses only**, with or without an allow-list. The name is
  resolved (`Deno.resolveDns`, 3 s) and every address must be outside
  loopback, private, link-local (including the `169.254.169.254` metadata
  service), carrier-grade NAT, multicast, reserved and documentation ranges,
  in IPv4 and IPv6 (IPv4-mapped, NAT64, 6to4 and Teredo forms included). A
  name that does not resolve is refused. With no allow-list this is the
  control that stops an attacker-chosen name pointed at a private address, so
  if the runtime has no DNS API at all the URL is refused (discovery stays
  off until `LHF_DISCOVERY_HOSTS` is set); with an allow-list the hostname
  rules stand on their own, with a warning in the log. Residual risk: the
  name is resolved here and again by `fetch`, so DNS that changes between the
  two is not caught; an allow-list narrows who could try it.
- **Redirects are followed by the function, hop by hop** (`redirect:
  "manual"`, at most 5), and every hop is held to the rules above before it
  is requested. `redirect: "follow"` checked nothing.
- **Bodies are streamed with a cap and a deadline** and the connection is
  cancelled at either: HTML pages 1 MB (cut, and the text read so far is
  used), `robots.txt` 100 KB, a PDF 200 KB (over it, skipped), a
  verification fetch 500 KB, the CIS directory 2 MB (a truncated directory is
  not cached). The deadline per body is the request timeout (8 s). The crawl
  also stops starting pages once the call's 45 s budget is spent.

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

**Time budget** (since 2026-10-27, hardening BE-12): one call may rebuild up
to 20 profiles, one model call after another, and now has a 40 second budget
(`EXTRACT_PROFILE_BUDGET_MS`). Past it no further course is started and a
model call in flight is aborted. A course not reached, or whose call was cut
off, keeps `profile_stale` set and is simply absent from `updated`, the same
outcome as an upstream failure, so the next sync's call picks it up. The wire
shape is unchanged. Still charged once per call, not per course: charging per
course would let a sync of several courses spend several of the student's 40
daily requests, and `profile_stale` is re-set whenever a page's content
changes, so that is a product decision, not part of this change.

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

`examDates[].date` is an ISO 8601 date when the source gives an exact one and
is omitted otherwise ("midterm week" is not a date). The prompt gives the
model no current date or term, so a date the syllabus writes without a year
rests on the model's guess of the year. `sync` passes the date on once
normalized (see "sync" above). The app discards one more than 150 days in
the past as a previous term's, and does not let the server's day override a
reading from the syllabus text on the phone whose line named a weekday that
fits the date it chose; where the two agree on the day it keeps the time of
day the phone read, since the server's date has none.

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
Response `{ "assignments": [ { "title", "dueAt"?, "kind" } ], "relevance"?: { "kind", "until"?: ISO8601 } }`, where `kind`
is `"submission"` (handed in or completed on a platform -- homework, a
quiz, a survey, an upload) or `"preparation"` (read/watch/review/bring/
prepare, nothing to hand in); the model defaults to `"submission"` when it
omits or misstates `kind`. Replaces the user-key
`ClaudeAnnouncementExtractor`. Counted against the same daily quota.

`relevance` is the model's judgment of how long the post *as a whole* stays
worth listing, independent of whether it yielded any task (an informational
post has `"assignments": []` and is where it matters most). Its `kind` is
one of four values, and nothing else is ever returned:

| `kind` | The post is... | `until` |
|---|---|---|
| `"event"` | about a dated happening: an exam, a review session, office hours, a room or time change | when the happening is over |
| `"task"` | mainly about work to do | the latest due date it names, if any |
| `"standing"` | a resource or policy useful for the rest of the term: a formula sheet, an office-hours schedule, a solutions directory, a grading policy | absent |
| `"news"` | an FYI that stops mattering within days: grades released, slides posted, a reminder about something already acted on | absent |

`relevance` is **optional and additive**: the key is omitted entirely (never
`null`) when the model gave none, or gave one the server could not use -- no
`relevance` object, a `kind` that is not exactly one of the four, or text
that does not parse. A shipped client that does not know the field ignores
it (Swift `Decodable` drops unknown keys), so the response to an old client
is the same one it always got, and a new client must treat a missing
`relevance` as "no judgment, decide the old way". `until` is an ISO 8601
datetime and is kept only when it parses as a date within `[now - 1 day,
now + 200 days]` of the request's `now`; otherwise just `until` is dropped
and `kind` survives. It is returned as the model wrote it, not
re-serialised. A bad `relevance` can never fail the request or change
`assignments` (`_shared/announcement.ts`'s `parseRelevance` and
`parseAssignments` read the model's text independently). The server does
not receive anything new for this: the post's title and text were already
sent, and `relevance` is derived from them in the same model call, with
nothing stored.

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

## `pair` — link the Chrome extension to a phone

Request `{ "action": ... }`, all POST, all authenticated as the caller's own
anonymous user. Tables `pairings`, `device_links` (service role only).

- `start` (the extension): the caller must not already be a linked device
  (else `409 already_paired`). Deletes the caller's older pairings, stores a
  new code (128 random bits, 22 characters base64url) valid for ten
  minutes, answers `{ "code", "expiresAt" }`. No per-caller rate limit yet
  (at most one live code per user, so the table is bounded); add one if
  anonymous signups are abused.
- `claim { "code" }` (the phone): the caller must not itself be a linked
  device (`403 forbidden`) and must not be the code's own user (`403`). An
  unknown, malformed or expired code is the same `404 pairing_not_found`, so
  codes cannot be probed. The code is consumed by an atomic delete, then
  `device_links(device_user_id, owner_user_id = caller)` is inserted.
  Answers `{ "paired": true }`. A device user that already owns devices, or
  is already linked, is `409 already_paired`.
- `status` (the extension): `{ "paired": bool }`.
- `unpair { "deviceUserId"? }`: from a device, removes its own link, its
  blob row and its auth user (naming another device is `403`). From the
  owner, removes the named device (must be theirs, else `404
  device_not_found`) or all devices when absent. Answers `{ "unpaired": n }`.

The end-to-end key `K` is never sent to the server: the QR carries it in the
URL fragment between the two devices only.

## `device-sync` — encrypted snapshots between paired devices

Only an owner (a user with at least one linked device) or a linked device
may call it; anyone else is `403 not_paired`. Table `device_sync_blobs`
(service role only), keyed `(owner_user_id, device_id)`.

- `put { "deviceId", "ciphertext" }`: `ciphertext` is standard base64 of at
  most 2 MB decoded (`413` above that), `deviceId` matches
  `^[A-Za-z0-9_-]{8,64}$`. Upserts the caller's own row and answers
  `{ "deviceId", "updatedAt" }`. An owner's row is keyed by the `deviceId`
  it sent. A **linked device's row is keyed by its own user id** whatever
  `deviceId` it sent, so unpairing can find and delete it; the response
  carries the id actually used.
- `get`: `{ "blobs": [{ "deviceId", "ciphertext", "updatedAt" }] }`, every
  device's row for the owner (a device reads the same set its owner does).

The server never parses, decrypts or logs `ciphertext`; it validates only
that it is base64 and within the size cap.

## `delete-account`

Request `{}`. From an owner (any user that is not a linked device): deletes
the caller's `enrollments` and `ask_usage` rows, every linked device's auth
user, the device links and every sync blob, then the auth user. Shared
course material is untouched (it is not the user's data). Response
`{ "deleted": true }`.

**Idempotent** (since 2026-10-27, hardening BE-14): a second call, or a
retry after a failure part way, completes the deletion and answers 200
`{ "deleted": true }`. An owner's linked devices are deleted first, while the
link rows that name them still exist (deleting a device's auth user cascades
its link away), then the owner's rows, then the owner; an auth user that is
already gone is skipped rather than failing the call, so it can fail at any
step and be called again. A call whose token is genuine but whose account no
longer exists (GoTrue answers `user_not_found`, which `requireUser` surfaces
as a 401 with code `user_not_found`) is answered 200 by this function only:
the deletion already finished. A bad or expired token is still 401
`unauthorized`.

From a **linked device**: never deletes the owner. It behaves as `unpair` of
that device (link, blob row, auth user) and answers `{ "deleted": true }`.
Identity resolution makes a device's `userId` its owner's, so the rule is
decided on `deviceOwnerLinked` (`decideDeleteAccount` in `_shared/devices.ts`),
and an inconsistent resolution is refused rather than guessed at.

## Model

`LHF_MODEL` env, default `openai/gpt-4.1-mini` since 2026-09-22 (this
section said `z-ai/glm-5.3-flash` until 2026-10-24; the primary-and-hedge
paragraph above was already right), called through OpenRouter's
chat-completions endpoint (`https://openrouter.ai/api/v1/chat/completions`)
with `provider: { "data_collection": "deny", "allow_fallbacks": true }` and,
when `LHF_PROVIDER_ORDER` is set, `provider.order` from that comma list.
Hedge and fallback model: `LHF_ASK_FALLBACK_MODEL`, default
`z-ai/glm-5.3-flash` at `reasoning.effort: low`. `OPENROUTER_API_KEY` is a function secret, never in
the repo, never in the app.

The two JSON-mode functions (`extract-announcement`, `extract-profile`) read
`LHF_MODEL` and `LHF_FALLBACK_MODEL` (same defaults) and go through
`chatCompletionJSON`, which does two things `ask` does not need. Each request
body carries `reasoning: { "effort": "low" }` when, and only when, the model
that body targets has a `z-ai/` id (`_shared/fallback.ts`'s `reasoningFor`;
the fallback body is built for the fallback model, not copied from the
primary's). And a primary that answers HTTP 200 with no usable
`choices[0].message.content` -- null, missing, or empty/whitespace -- gets
one retry against the fallback model before the function gives up, because
a thinking model that spends its whole output cap on hidden reasoning
returns exactly that, and `requestWithFallback` only retries on an HTTP or
transport failure. If the fallback also has no usable content the call
fails as an upstream error (502), as a missing body always did. This was
found on 2026-10-23 when one 255-word Canvas announcement failed twice with
a 502 on a real phone while a 53-word one succeeded.

## Limitations recorded on purpose

- Enrollment is asserted by the client, not proven. A tampered client could
  list a course id it is not enrolled in and read that course's material.
  Real proof would need the server to hold Canvas credentials, which
  principle 1 forbids. Material shared this way is course-site content every
  enrolled student already sees; nothing personal is reachable.
- Section-specific announcements and per-section due-date overrides are
  shared at the course level in v1.
- The server cannot verify a client's `client` claim. `client: "extension"`
  only requires that the caller is a linked device; a tampered phone that is
  paired could claim it and have its complete-set report retire phone-
  collected rows too, or a paired extension could claim `"phone"` and retire
  fewer rows than it should. Neither reaches anything the caller could not
  already change as that student. The same goes for `acceptsKinds`: it is a
  capability the client asserts, not one the server checks.
- Pairing is single use and ten minutes, but the code travels in a QR a
  custom URL scheme can in principle hand to another app on the phone. It is
  useless without the phone's own approval and token (`claim`), and links
  only the claiming phone's account.
