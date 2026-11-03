# From "regurgitating Canvas" to a composed day (research and plan, 2026-11-03)

Written 2026-11-03 on `v8` at Marco's request. His idea, in his words: the
app still grabs assignments, but instead of building the dashboard from
the calendar feed alone it compiles every page it has (modules, pages,
announcements, syllabus, Ed) into one place and has an AI build the
day-to-day from all of it, so an assignment that only lives in a module,
or an announcement that cancels one, is handled. He also asked what it
would cost, which Canvas APIs it needs, and whether the model we use now
is good enough.

This is research plus a proposed plan; nothing here is agreed or built.
Part 1 is what exists today (it is more than expected). Part 2 is the
design I would build and why it is not quite "let the AI build the list".
Part 3 is the Canvas API surface. Part 4 is cost. Part 5 is the model
question. Part 6 is the plan in order, Part 7 how to know it worked, and
Part 8 the decisions Marco and Olisa have to make first. Two plain-language
PDFs sit beside this file: `DAY_PLANNER_2026-11-03_research.pdf` (the
research, costs and model question) and
`DAY_PLANNER_2026-11-03_how_it_works.pdf` (a walkthrough of the
proposed version as a student would meet it). Paths: `Kit/` is
`LowHangingFruitKit/Sources/LowHangingFruitKit/`, `UI/` is
`LowHangingFruitKit/Sources/LowHangingFruitUI/`, `backend/` as is. Line
numbers are from `v8` at `56cfee8`.

## 1. What exists today: collection is nearly done, reconciliation is absent

The app already pulls almost everything the idea needs. Per course, on
the hourly course-knowledge sync (`UI/AppState+CourseKnowledge.swift:122`)
and the 15-minute intel loop (`UI/AutoSyncCoordinator.swift:22`):

| Source | Fetch | Where it goes |
|---|---|---|
| Calendar feed (ICS) | `Kit/Canvas/CanvasICSClient.swift:19` | the ledger, every 5 min |
| Assignments with submission state and description | `Kit/CanvasAPI/CanvasCourseContentClient.swift:66` | course knowledge (kind `assignment`, with due date and "Status: submitted" in the text) |
| Modules with items and content details | `Kit/Canvas/CanvasModulesClient.swift:123` | course knowledge (one doc per module) **and** `.canvasModules` reading rows on the dashboard (`UI/AppState.swift:4976-5110`) |
| Planner items (Canvas's own merged to-do) | `Kit/Canvas/CanvasModulesClient.swift:138` | only as a date overlay for module items without a due date (`UI/AppState.swift:5011`) |
| Pages (first 40 bodies, newest first) | `CanvasCourseContentClient.swift:79` | course knowledge |
| Syllabus (course body, syllabus pages, syllabus PDF) | `Kit/Syllabus/CanvasSyllabusClient.swift:86-172` | course knowledge; server profile; exam cards |
| Announcements, 120 days | `Kit/Canvas/CanvasAnnouncementsClient.swift:179` | course knowledge; the watcher (60 days, selected courses) |
| Ed posts (announcement, pinned, staff) | `Kit/Ed/EdClient.swift:73` | course knowledge kind `ed`; Ed-found tasks |
| Gradescope | `Kit/Gradescope/GradescopeClient.swift:101` | the ledger |
| Grades and assignment groups | `Kit/Canvas/CanvasGradesClient.swift:79` | Grade Watcher |

Not fetched today: `/users/self/missing_submissions`, `/users/self/todo`,
assignment overrides (`all_dates`), `unlock_at`/`lock_at`, discussion
topics as JSON, page to-do dates, the activity stream.

And the dashboard already has six origins (`Kit/Models/Assignment.swift:7-41`):
feed items, Gradescope, module readings, announcement-found tasks (Canvas,
Ed and syllabus-exam flavours), manual, and accepted Canvas-scan
suggestions. The announcement watcher is already "AI reads prose and
emits dated tasks": an on-device gate (`Kit/Announcements/HeuristicAnnouncementExtractor.swift:109`)
sends likely posts to `extract-announcement`, which returns
`{assignments:[{title, dueAt, kind}], relevance}` (`backend/PROTOCOL.md:896`).

So the gap is not "the app only reads the calendar". The gap is that
every one of those paths is **additive and independent**. Nothing can
express "this document changes that item":

- An announcement saying "HW3 is cancelled" can only *add* a task; it
  cannot touch the HW3 card that came from the feed. The extractor's
  prompt literally has no verb for it (`backend/supabase/functions/_shared/announcement.ts:26-81`).
- "Quiz moved to Friday" produces, at best, a second quiz card with the
  new date beside the old one (the twin matcher at `UI/AppState.swift:5226`
  dedups by title, so it may instead be dropped).
- A module item with a due date and the same assignment in the feed are
  kept as two cards when their ids differ (deliberately, after the Lab 3
  trap; `ROADMAP.md` → Done, 2026-10-18).
- The pooled material on the server is read by no AI path except the
  syllabus profile (`backend/supabase/functions/extract-profile/index.ts:306`).
  `ask` never reads `course_documents` (`ask/index.ts:333-343`).
- Canvas's own Planner, which already honours overrides, dismissals and
  page to-do dates, is used only to fill in missing module dates.

That is the thing to build: a **reconciliation layer** with one model
pass per new document, not a replacement for the list.

## 2. The design: facts applied to a ledger, not a list built by a model

The tempting version is the one in the request: hand the model
everything and let it write the day. I would not do that, for reasons
that are each individually sufficient:

1. **The ledger invariant.** "Nothing the student did is ever lost"
   (`CLAUDE.md` → The ledger is the point) cannot survive a list that a
   model regenerates nightly. A model that forgets an item once has
   deleted it.
2. **Stability.** A student's list must not reorder or reword itself
   each night because sampling differed. Marco's own verdict on the tree
   (2026-11-02) was that the model reasons poorly about *when*; the
   prior research (`docs/TREE_CONTEXT_RESEARCH_2026-11-02.md` Part 2)
   found the literature unanimous: resolve dates and authority in code,
   let the model extract.
3. **Cost shape.** Re-reading 50-100k tokens per student per night is
   the expensive design (Part 4). Reading each new document once, per
   *course*, is 50-100x cheaper and the sync already knows which
   documents are new (`content_hash`, `backend/.../_shared/manifest.ts:499`).
4. **Explainability.** A cancelled card must say which post cancelled it
   and let the student undo. That needs a fact with a source, not a list.

So: the dashboard stays deterministic. The model's only job is to turn
each new or changed *prose* document into zero or more **facts** with a
verbatim quote, against an index of the course's current items. Code
applies facts to the ledger as overlays with provenance and precedence.

### 2.1 The fact

```
{ "facts": [ {
    "type": "new_task" | "cancel" | "reschedule" | "scope_change" | "note",
    "target": "<sourceID of an existing item, or null>",
    "title": "<for new_task>",
    "due_at": "<ISO 8601 or null>",
    "kind": "submission" | "preparation" | "event",
    "quote": "<verbatim span from the document>",
    "confidence": "high" | "medium"
} ] }
```

The model is given, besides the document and its posted date in the
student's zone: the course's **item index** (for each live assignment,
quiz and module item: sourceID, title, due date; 20-60 short lines, from
the pooled `assignment` and `module` documents, which carry `due_at`),
and the weekly meeting pattern from the catalog. It names a `target` by
sourceID rather than by title, so matching is the model's job *with the
candidates in front of it* (the "select from a blocked list" strategy the
entity-matching literature finds most cost-effective, arXiv 2405.16884),
and code only has to check that the id exists. Relative dates ("Friday",
"before Tuesday's lecture") are resolved by code from the posted date and
the meeting pattern where the model's `due_at` is null or disagrees with
the quote; the model never does calendar arithmetic (the Kyriba and
Test-of-Time findings in the earlier research).

Two checks reject a fact in code before it is stored: the `quote` must
appear in the document text (this is the "no invented tasks" guard; a
strict JSON schema guarantees shape, not truth), and a `target` must be
in the index. A `due_at` outside 400 days of the post is dropped, as the
extractor does now (`announcement.ts:274`).

### 2.2 Where extraction runs: pooled per course, on the server

A fact about "HW3 is cancelled" is the same fact for every student in
the class. The backend already pools documents per Canvas course id and
already gates syllabus extraction on upload (`profile_stale`). Facts
belong beside them: a `course_facts` table keyed by `(document_id,
content_hash)`, filled by a new `extract-facts` function (or
`extract-announcement` grown to cover it) for every newly uploaded
document of kind `announcement`, `ed`, `page`, `module` or `syllabus`,
and served down in the manifest with the profiles. A fact is computed
once per course, not once per phone, and never again for the same
content hash.

What stays on the phone is everything personal: which items the student
finished, hand-edited dates, hidden classes, and the application of facts
to *their* ledger. This keeps the privacy line exactly where
`docs/PRIVACY.md` draws it (course material pooled; the student's own
state on-device). One wrinkle already exists and should be fixed on the
way: assignment documents carry "Status: submitted" in their uploaded
text (`CanvasCourseContentClient.swift:291-294`), which contradicts the
header comment at `UI/AppState+CourseKnowledge.swift:33-40`. Strip it.

Non-Penn installs have no backend, so they get Phase 1 below (structured
sources, no model) and the heuristic extractor, as today.

### 2.3 Applying facts on the phone

A new SwiftData model, `AppliedFact` (fact id, target sourceID, type,
dates, source document id and quote, applied at, student override:
none / confirmed / rejected). Rules, in precedence order:

1. The student's own action wins: a hand-edited date, a completion, or
   "not cancelled" is never overridden by a fact.
2. Canvas's own structured state wins over prose: if the assignment's
   `due_at` already moved, the reschedule fact is redundant and is marked
   applied-by-canvas; if the assignment is gone from the API and the
   feed, the cancel fact is confirmation, not news.
3. A newer fact about the same target supersedes an older one.
4. A fact never deletes a row. `cancel` hides the card from todo and
   tags it in all/prev ("cancelled · Oct 3 announcement"); `reschedule`
   shows the new date with the old one struck; `new_task` creates a
   `.canvasAnnouncement`-style row (the existing origin, with the fact
   id as provenance); `note` only annotates.
5. Every applied fact is one tap from its source and one tap from undo.

The megaphone becomes the natural home for "what changed": the finds
sheet already lists per-class posts and NEW tags; applied facts are a
better list than raw posts.

### 2.4 "The day" is then deterministic

Once facts are applied, today's view is a filter, not a model call:
overdue and due within two days (as `DashboardViewModel.todoSections`
does now), plus preparation tasks whose lecture is today or tomorrow,
plus class meetings from the catalog pattern minus any `cancel` on a
meeting. If a one-line "your day" summary is wanted, it is a cheap
`ask`-path call over that small computed list, and it is cosmetic.

## 3. The Canvas API surface it needs

All with the student's cookie session, as today (`Accept:
application/json` suppresses the `while(1);` prefix; GETs need no CSRF
token). None of these needs a developer key or scope. Verified against
the Canvas API docs on 2026-11-03 except where marked.

| Need | Endpoint | Status |
|---|---|---|
| Items that live only in modules, with their completion rule | `courses/:id/modules?include[]=items&include[]=content_details` (`completion_requirement`, `completed`, `state`, `unlock_at`) | fetched; completion fields not read |
| Canvas's own merged to-do with overrides and dismissals | `planner/items?start_date&end_date` (`plannable_type`, `planner_override.{marked_complete,dismissed}`, `submissions`) | fetched; used only as a date overlay |
| Missing work Canvas itself knows about | `users/self/missing_submissions?include[]=planner_overrides` | not fetched |
| Per-section due dates and overrides | `courses/:id/assignments?include[]=all_dates&include[]=overrides` | not fetched (the ICS override trap in `CLAUDE.md` is the symptom) |
| Discussions with a to-do date, graded discussions | `courses/:id/discussion_topics` (`todo_date` unverified in docs; `assignment` nested) | HTML scrape only |
| Page to-do dates ("add to student to-do") | `courses/:id/pages` (`updated_at`, `published`); the to-do field is reported as `student_todo_at`, unverified | pages fetched; field not read |
| Announcements beyond 14 days | `announcements?context_codes[]&start_date&end_date` (explicit window required or Canvas silently cuts at 14 days) | fetched correctly |
| Cheap "did anything change" | `users/self/activity_stream` (newest first, no `since`; page until the last seen id) | not fetched |
| Unpublished or deleted assignments | not reachable; detect by diffing successive API fetches (assignment gone from the list and from the feed) | diff exists for the feed (`isGoneFromFeed`) |
| Change feed or audit log | none for students (admin-only audit APIs) | n/a |

Two limits to design around. Canvas has no `since`, ETag or
If-Modified-Since anywhere documented, so change detection is our own
hash diff (already how `sync` works). And Canvas throttles per user
(`X-Rate-Limit-Remaining`, 403 when exhausted); the extra calls above are
roughly six per course per hourly sync on top of today's, which is well
inside the limit for a five-course student, but the collector should
read the header and back off rather than fail the whole run.

Canvas's own Planner is worth leaning on harder than today: it already
merges assignments, quizzes, graded discussions, planner notes and pages
with to-do dates, honours overrides, and lets the student dismiss items.
Its documented gaps (Penn State's 2025-01-21 notice; the Canvas known
issue about more than 50 completed items hiding future work; paper and
"no submission" items vanishing after the due date; the open idea "put
everything with a deadline into the to-do list") are the places prose
extraction has to cover. The ICS feed, by contrast, carries no to-do
items, collapses overrides, and is capped at 1,000 items and 30 days of
past events.

## 4. Cost

Figures read 2026-11-03 from OpenRouter's model list, OpenAI's and
Anthropic's pricing pages; per 1M tokens, input / output.

**Model calls.** The pooled design (2.2) scales with *new documents per
course*, not with students. A Penn course posts on the order of 2-5
prose documents a week (PHYS 0151 posted 20 announcements in 60 days;
CIS classes post on Ed instead). One extraction call is about 3-4k
tokens in (instructions, schema, item index, the document) and under
500 out.

| | per call | per course / month (20 docs) | 150 courses (≈200 students) |
|---|---|---|---|
| gpt-6-luna or Claude Haiku 5.5 ($0.10 / $0.50) | ≈ $0.0006 | ≈ $0.012 | ≈ $2 / month |
| gpt-6.1-terra ($1 / $5) | ≈ $0.006 | ≈ $0.12 | ≈ $18 / month |
| glm-5.3-flash ($0.031 / $0.085) | ≈ $0.0002 | ≈ $0.003 | ≈ $0.50 / month |

For comparison, the design the request describes, a nightly re-plan over
each student's 75k tokens of material, costs per student per month
(30 runs, 2k output):

| Model | no cache | incremental (8.5k in) |
|---|---|---|
| gpt-4.1-mini (today's ask model) | $1.00 | $0.20 |
| gpt-6-luna / Claude Haiku 5.5 | $0.26 | $0.06 |
| gpt-6.1-terra | $2.55 | $0.56 |
| Claude Sonnet 5.5 | ≈ $5.00 | ≈ $1.10 |

At 200 students that is $52 to $1,000 a month depending on model and
design, against about $2 for the pooled design. Prompt caches do not
rescue the nightly design: Anthropic's default TTL is 5 minutes (1 hour
at 2x write cost), OpenAI's for GPT-5.6-and-later is 30 minutes, and
Gemini charges per hour of storage, so a cache written tonight is gone
by tomorrow and a cold write costs more than no cache. Batch APIs halve
either design and fit a nightly job.

**Quota plumbing.** Today every model function shares the student's
40-a-day `ask_usage` counter (`backend/.../_shared/quota.ts:122`). Pooled
extraction is charged to the course, not the student, so it needs its
own ceiling (per course per day, and a global monthly cap) and must not
eat anyone's ask budget.

**Canvas side.** No money, but about six more requests per course per
hourly sync and one more hidden-WebView dependency on the session being
alive. Everything here inherits the sign-in fragility that
`docs/SIGNOUT_2026-11-01.md` and `v9` are about; a fact pipeline on a
dead session simply goes stale, and facts must carry `as_of` so a stale
phone does not apply a week-old reschedule over a newer feed date.

**Engineering** is the real cost: roughly three phone-side pieces (new
structured sources, `AppliedFact` and the precedence rules, the UI tags
and undo), two server pieces (`extract-facts`, `course_facts` in the
manifest), and the bench. See Part 6.

## 5. Is the model we use good enough?

What runs today (`backend/`, read 2026-11-03):

| Function | Model | Fallback |
|---|---|---|
| `ask` | `openai/gpt-4.1-mini` | `z-ai/glm-5.3-flash` (5 s hedge) |
| `extract-announcement`, `extract-profile`, `map-categories` | `z-ai/glm-5.3-flash` | `openai/gpt-5.6-luna` |

(`PROTOCOL.md:1126` says the JSON functions share `ask`'s defaults; the
code does not. Fix the doc.)

Three findings:

1. **gpt-4.1-mini is being retired.** OpenAI's deprecations page lists
   GPT-4.1 mini for shutdown on **2027-01-14**, replacement `gpt-6-luna`
   (verified by reading the page). gpt-5-mini and gpt-5-nano go on
   2026-12-11. Whether OpenRouter keeps serving them past those dates is
   not stated. So `ask` has to move within two months regardless of this
   feature, and the answer to "is it good enough" is "it is leaving".
2. **glm-5.3-flash, which does today's extraction, has the weakest
   evidence** of any candidate: third-party quality indices for it
   disagree (28 vs 42 on two snapshots), latency to first token is the
   most variable (that is why the ask hedge exists), it is an
   always-thinking model whose reasoning once ate its whole output budget
   (`CLAUDE.md` → Traps), and it appears on no hallucination leaderboard.
   It is also the cheapest by 3x. It should be the hedge, not the
   primary, for a job where a false task is worse than a missed one.
3. **No public benchmark measures this task** (messy announcement in,
   dated tasks and corrections out, nothing invented). Proxies: on
   Vectara's summarization-hallucination leaderboard (2026-10-22)
   DeepSeek V4.1 Flash 4.2%, Gemini 2.5 Flash 7.8%, Claude Haiku 4.5
   9.8%, glm-5 10.1%, gpt-5-mini 12.9%; gpt-4.1-mini, gpt-6-luna and
   Haiku 5.5 are not listed. On Artificial Analysis's index, Haiku 5.5
   (low effort) scores 19, gpt-6-luna 9, gpt-6.1-terra 30-38,
   glm-5.3-flash 28, DeepSeek V4.1 Flash 19-32. These rank general
   ability, not date extraction, and bigger reasoning models sometimes
   hallucinate *more* on extraction.

Structured outputs: every candidate lists `structured_outputs` on
OpenRouter (verified via the models API), but OpenRouter enforces per
endpoint, so the call must set `provider.require_parameters: true` and
a `json_schema` with `strict`. Today's client sends only
`response_format: {type: "json_object"}` (`_shared/openrouter.ts:187`),
which is best-effort shape and no schema; that is a small, worthwhile
change on its own. Anthropic's schema mode is true constrained decoding
but disallows `minimum`/`maxLength` and recursive schemas, so range
checks stay in code (they already do).

**Recommendation.** Do not pick from benchmarks. Build the bench first
(Part 7): 50-80 real Penn documents off Marco's and Olisa's phones with
hand-labelled expected facts, run through an `ask-canary`-style probe
against four models, and choose on precision first. Going in, the two
front-runners at the same $0.10 / $0.50 price are **Claude Haiku 5.5**
(constrained decoding, higher index) and **gpt-6-luna** (OpenAI's named
successor to the model `ask` uses now; if it benches well, one model
serves both). **DeepSeek V4.1 Flash** is the cheap dark horse with the
best hallucination number; **gpt-6.1-terra** is the quality fallback if
nothing under $1 reaches the precision bar, at about $18 a month for
200 students in the pooled design, which is affordable. Keep
glm-5.3-flash as the hedge.

## 6. The plan, in order

Each phase ships on its own and is useful without the next.

**Phase 0: the bench and the migration (one to two weeks, no app change).**
Collect `course-knowledge.json` and the ledger from two phones (the
device-forensics path in `CLAUDE.md`), label 50-80 documents with
expected facts (include cancellations, moves, scope changes, "none", and
posts that *look* like tasks but are the instructor's own actions, which
the current prompt already excludes), write the `extract-facts` prompt
and schema, and run the four candidates through a probe with a tag in
`ask_outcomes`. Separately, move `ask` off gpt-4.1-mini on the canary
before 2027-01-14. Output: a model decision and a measured precision.

**Phase 1: structured sources, no model (phone, Penn and non-Penn).**
Read what Canvas already states as data: Planner items as a first-class
origin with `marked_complete` and `dismissed` respected; module items
with a `completion_requirement` and `completed`; `missing_submissions`;
`all_dates` so the student's own section date wins; discussion topics as
JSON; page to-do dates. Each becomes a row with a real Canvas id, so the
existing twin logic (same id, one card) applies. This alone covers "the
assignment is only in the modules" and most "it's a page with a to-do
date" cases, with zero model cost. Rate-limit header respected in the
collector. Strip "Status: submitted" from uploaded assignment text.

**Phase 2: `extract-facts` on the server, pooled.** New function and
`course_facts` table; run on upload for new prose documents; strict
schema; quote and target verification; per-course quota; facts in the
manifest. `extract-announcement` keeps serving old clients until the
phone side lands, then is retired into it. Deno tests on the handler
with fixture documents from the bench.

**Phase 3: `AppliedFact` on the phone.** The SwiftData model, the
precedence rules (2.3), the dashboard tags, undo, and the megaphone as
"what changed". Swift tests for every precedence rule with a pinned
clock, and the ledger invariant tests extended: no fact may delete or
complete a row.

**Phase 4: the day view.** The deterministic composition (2.4), prep
tasks before the lecture they prepare, cancelled meetings. Optional
one-line summary through `ask`.

**Phase 5: feedback.** A thumbs-down on an applied fact writes a row
with the fact id and verdict (no content) so precision can be tracked
per model and prompt version, the way `ask_outcomes` tracks ask.

Phases 1 and 3 are phone work on `v8`; 2 is backend and needs a deploy
with a person's go; 0 needs the probe secret Olisa holds. Olisa has owned
announcements and Ed since 2026-10-18, and Phase 2 and 3 replace the
watcher's output, so this is his call as much as Marco's.

## 7. How to know it worked

- **Bench precision and recall** on the labelled set, per fact type.
  Gate for shipping: no invented `new_task` and no wrong `cancel` on the
  set (precision at or near 100% on those two; a missed cancellation is
  today's behaviour, a wrong one hides real work), date exactness on
  `reschedule`, and correct `target` ids.
- **A frozen Swift regression set** for the precedence rules and the
  ledger invariant, no model involved, on every push.
- **On two phones for two weeks**: count applied facts, undo taps, and
  the three cases Marco named (module-only assignment, cancelled
  assignment, moved date), recorded in `CLAUDE.md` → Known gaps as the
  hand-offs ask.

## 8. Decisions needed before Phase 0

1. **Pooled on the server versus per phone.** This plan says pooled
   (one extraction per course document, facts shared by classmates,
   personal state on-device). The alternative, calling the model from
   each phone as the watcher does, costs 50-200x more at scale and
   gives every student a slightly different reading of the same post.
2. **Hide or tag.** Does a `cancel` fact hide the card from todo, or
   only tag it until the student confirms? Hiding is what the request
   wants; tagging is safer for the first build. The plan says hide with
   undo, after the bench shows the precision.
3. **Model**, after the bench; and whether `ask` moves to the same one.
4. **Ownership** of the watcher's replacement (Olisa's area).

## Sources

- Canvas API: Planner https://canvas.instructure.com/doc/api/planner.html; Modules https://canvas.instructure.com/doc/api/modules.html; Assignments https://canvas.instructure.com/doc/api/assignments.html; Announcements https://canvas.instructure.com/doc/api/announcements.html; Pages https://canvas.instructure.com/doc/api/pages.html; Users (todo, missing submissions, activity stream) https://canvas.instructure.com/doc/api/users.html; Calendar events https://canvas.instructure.com/doc/api/calendar_events.html; Pagination https://canvas.instructure.com/doc/api/file.pagination.html
- Canvas planner gaps: Penn State notice 2025-01-21 https://www.it.psu.edu/?p=239160; known issue, 50+ completed items https://community.canvaslms.com/t5/Known-Issues/OPEN-Students-with-more-than-50-completed-items-in-the-past-two/m-p/656708; idea "put everything with a deadline into the to-do list" https://community.canvaslms.com/t5/Canvas-Ideas/Put-everything-with-a-deadline-into-the-to-do-list/idi-p/304836
- OpenAI deprecations https://developers.openai.com/api/docs/deprecations; pricing https://developers.openai.com/api/docs/pricing; prompt caching https://developers.openai.com/api/docs/guides/prompt-caching
- Anthropic pricing https://platform.claude.com/docs/en/about-claude/pricing; structured outputs https://platform.claude.com/docs/en/build-with-claude/structured-outputs; prompt caching https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- OpenRouter models API https://openrouter.ai/api/v1/models; structured outputs https://openrouter.ai/docs/features/structured-outputs; prompt caching https://openrouter.ai/docs/features/prompt-caching
- Google AI pricing https://aistudio.google.com/docs/pricing
- Vectara hallucination leaderboard https://github.com/vectara/hallucination-leaderboard; Artificial Analysis https://artificialanalysis.ai/leaderboards/models
- Entity matching with LLMs, "Match, Compare, or Select?" https://arxiv.org/abs/2405.16884; Test of Time https://arxiv.org/abs/2406.09170; relative-date handling https://developer.kyriba.com/site/articles/temporal-logic-enhancement
- Prior art, marketing-grade only: Shovel and DormWay (https://dormway.app/blog/best-apps-that-sync-with-canvas-lms-2026), CanvasBuddy (https://devpost.com/software/canvasbuddy-v2pgra), Instructure IgniteAI agent (https://www.constellationr.com/index.php/insights/news/instructure-launches-igniteai-agent-canvas-builds-amazon-bedrock). No public lesson on false positives was found.
- Earlier in this repo: `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`, `docs/ED_AND_MEGAPHONE_PLAN.md`, `docs/ANNOUNCEMENT_WATCHER_PLAN.md`.

## Addendum, later on 2026-11-03: two reads, dedup, and what has to change

After reading Parts 1-8 Marco refined the idea. It does not need to run
nightly. It needs a very good first read of a class (modules above all,
so the term is known three months out) that takes notes, then a careful
read of each new piece of information against those notes. He also
expects it to dedup across sources, and to make announcements "fluid"
with assignments: one story per item, not two feeds. This addendum
replaces the "nightly re-plan" framing in Part 4 and extends Part 2.

### A. Two reads, not one schedule

**Read 1, the first read, once per class, on the server.** When a class
first reaches the pool (or its structural documents change hash: modules,
syllabus, schedule pages), the best affordable model reads everything the
class has in one pass and writes a versioned **semester map**
(`course_maps`, per Canvas course id, shared by classmates): the week
structure (module ↔ week ↔ dates, from module order, subheaders and the
catalog meeting pattern); the class's rhythm ("quiz every Friday",
"prelab before each lab", undated weekly readings); every item found,
with a *stated* date or an *inferred* date and which it is; standing
rules; exam and milestone dates that exist only in the syllabus or a
schedule page; and a list of things it could not pin down. 50-150k
tokens in, once per class, so this is where to spend on the premium
tier: $0.10-0.50 per class on gpt-6.1-terra or Sonnet 5.5, a few cents
on Haiku 5.5. At 150 classes, $15-75 once. Re-read only on structural
change.

On the phone, map items Canvas has not published yet become **projected
cards** (a new origin: lighter, "expected", source "from module 9"), in
`all`, months out. When the real assignment appears, the projected card
merges into it (Part C) rather than sitting beside it.

**Read 2, every new document, read against the map.** When the hourly
sync uploads a new or changed prose document, `extract-facts` reads it
with the semester map, the class's item index and the meeting pattern in
context. "The usual quiz is pushed to Monday" is only readable by a
model that already knows there is a usual quiz. Facts as in 2.1, plus
`map_amendment` (the map itself changes: "week 9 reading replaced") and
`needs_review` (ambiguous; shown, never applied). Event-driven, no
schedule; cost stays around $2 a month at 200 students.

### B. Edge cases this version handles and today's does not

Removing or changing work: a cancelled assignment ("HW3 is cancelled");
made optional; unpublished or deleted in Canvas (today the card lingers
until 14 days past due); a cancelled class or recitation; a moved or
cancelled exam; a conditional ("skip HW5 if you did the project"),
flagged not applied.

Better assignments from announcements: a moved due date (everyone or one
section); scope changes ("only problems 1-4"); submission venue changed
("Gradescope, not Canvas"); a date for an item the feed left undated;
"quiz covers chapters 5-6" as a note on the quiz; prep tasks ("read 3.1
to 3.3 before Tuesday"); relative dates resolved from the post's date;
correction posts superseding earlier ones; the instructor's own actions
kept out.

Thorough reading of modules, pages and the syllabus: work that exists
only as a module item, page or file; undated weekly readings dated by
module week and lecture day; undated items bracketed by dated
neighbours; module unlock dates; a pattern stated once in the syllabus
turned into the term's cards; a schedule table with dates months out;
project milestones on a project page; external-tool items linked to the
work they point at; a schedule page edited mid-term, caught by the hash
diff; last year's dates on a recycled site flagged on the first read.

Across sources: the same work in the feed, a module and Gradescope as
one card; a syllabus date and a later announcement date disagreeing,
newer wins with the source shown.

Still out of reach: anything said only in lecture, email or Slack;
private Ed threads; a dead Canvas session (nothing new is read).

### C. What has to change for this to work effectively

Grouped by layer. Items marked **(sync)** touch the collector or the
sync path, which Olisa owns; they need his go before any code.

**Identity and dedup (phone, Kit).** Today identity is per source
(`sourceRaw` + `sourceID`), with title-based twin matching bolted on.
The map, the feed, modules, Gradescope and facts all have to agree on
*one* work item, so:
1. A `WorkItem` identity with **aliases**: Canvas assignment id (from
   the ICS fragment), module item id and its `content_id` (which for an
   Assignment item *is* the assignment id, via `content_details`),
   Gradescope id, map item id, announcement-derived id. Deterministic
   ids merge first; title-and-date proximity second; the model's
   `target` third, and only among candidates in the index.
2. A merge record with provenance, so a merge is reversible ("these are
   two things" splits them), and the Lab 3 / Lab 3 Report rule
   (different Canvas ids never collapse) is kept as a hard rule.
3. `AppliedFact` (2.3) and the projected origin (A), both SwiftData,
   both never deleting. The ledger invariant tests extend to them.

**Announcements become part of the item, not a second feed (phone, UI).**
4. A fact links a post to the item it changes, so a card shows its
   history ("moved to Fri · Oct 3 post · scope narrowed · Oct 5 post")
   and opens the post. The watcher's own `.canvasAnnouncement` task rows
   are retired into `new_task` facts.
5. The megaphone lists facts grouped by item ("what changed"), raw
   posts only when they touched nothing, and a "needs a look" group.
   Minimal copy, per the owner's rule.
6. Card treatments: tag, struck date, projected style, undo, one-tap
   source.

**Collection (phone, Kit) (sync).**
7. Fetch what Canvas states as data and we skip: `all_dates`/overrides,
   module `completion_requirement`/`completed`/`state`/`unlock_at`,
   Planner items as a first-class source with `marked_complete` and
   `dismissed`, `missing_submissions`, discussion topics as JSON, page
   to-do dates, all pages (not the first 40), a files listing for
   schedule PDFs.
8. One document per module *item*, not per module, so the item index
   and change detection work at item grain (`CanvasCourseContentClient`
   /`CourseKnowledgeCollector`).
9. Deleted or unpublished assignments detected by diffing successive
   API lists, not only the feed.
10. Read `X-Rate-Limit-Remaining` and back off per course instead of
    failing the run.
11. Stop uploading "Status: submitted" in assignment text.

**Server (backend).**
12. `course_maps` (versioned, per course id) and `build-map`, triggered
    by a structural hash change on `fullySyncedCourses`, with a per-class
    budget and cooldown like `extract-profile`'s.
13. `extract-facts` replacing `extract-announcement` for new clients
    (the old one stays for old clients), run on upload for new prose
    documents; `course_facts` keyed by document id + hash; manifest
    serves facts and the map since a cursor.
14. The item index built server-side from `assignment` and module-item
    documents (`due_at` is already stored).
15. `_shared/openrouter.ts`: `response_format: json_schema` with
    `strict`, `provider.require_parameters: true`, and schema validation
    plus the quote check on the way in. Today it sends `json_object` only.
16. Quotas per class (map builds, facts per day) and a global monthly
    cap; a cost ledger in `ask_outcomes` style. Never the student's ask
    counter.
17. Model config: `ask` off gpt-4.1-mini before 2027-01-14; extraction
    model chosen by the bench; the first read on the premium tier.
18. `docs/PRIVACY.md` and `PROTOCOL.md`: maps and facts are course-level
    and carry nothing personal; say so in the same commit.

**Making it reason well (prompt and code, both sides).**
19. Everything the model needs is in front of it: map, item index,
    meeting pattern, the post's date and weekday in the student's zone.
    Code does all calendar arithmetic and all precedence.
20. Facts ordered by posted date; a newer fact on the same target
    supersedes; corrections handled by the same rule.
21. `needs_review` as an output, with a UI, so the model is rewarded for
    flagging instead of guessing.
22. The bench (Part 7) grows a dedup section: pairs and triples that
    must merge, and pairs that must not.

**Rollout.** Non-Penn installs get items 1-2 and 7-11 (no backend).
Items 7-11 and 13 change what the sync collects and sends, so the order
is: bench and model choice; identity and dedup on the phone (pure Kit,
testable); the server pieces on a canary; then the UI. Nothing lands on
`v8` without a compiled build and the ledger tests green.
