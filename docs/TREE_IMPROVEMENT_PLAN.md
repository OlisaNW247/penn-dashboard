# Improving the tree (ask): research and a ranked plan

Written 2026-10-24 for Olisa, from a read-only survey of the client, the
backend, the live tables and the test fixtures, at his request ("do deep
research on how we can improve the tree feature"). Nothing in it is
implemented. There is no Swift toolchain where this was written, so every
"test prediction" below is a prediction until `swift test --no-parallel`
runs on a Mac, and every verdict in section 3 is a prediction from the code
and the live counts until the questions are asked on a phone.

The method, so the numbers can be re-checked: the live tables were read
through the Management API (`POST /v1/projects/<ref>/database/query`),
counts, kinds, lengths and dates only, never a document body; the code
references are to `v8` at `3af6547`; the question set is what a Penn
student actually types, drawn from the questions the tree has been asked
in the notes (CLAUDE.md, `ask-probe.mjs`) and from the shape of the
material in the pool.

## 1. What the tree is asked today

Since the outcomes table began on 2026-09-22, real phones have asked **44
questions** (8 of the 25 anonymous users; 21 users were active in the past
week). In the last 30 days: 42 questions, 37 answered, 5 refused for quota,
all five on 2026-10-19 (the day a failing announcement extractor emptied the
shared quota, CLAUDE.md → "How the posts are read"). Nothing else failed.

| measure (real questions, last 30 days) | value |
|---|---|
| first word, median / p95 | 2.4 s / 3.9 s |
| whole answer, median | 3.3 s |
| answer length, mean | 515 characters |
| prompt, mean per day | 7,000 to 15,500 tokens |
| cached prompt tokens, mean per day | 0 on six of twelve days; 1,100 to 7,900 on the rest |
| hedge fired (`detail` naming a race) | **never**, on any real question |
| model that answered | `openai/gpt-4.1-mini`, every time |

Three conclusions. Latency is not the problem: the primary model has
answered every real question itself, and the glm hedge has never been
needed, so model-side work buys little on speed. Volume is tiny, so the
sample says nothing about correctness, and the outcomes table cannot: it
records that an answer came, not whether it was right. And prompt caching
is unreliable (zero cached tokens on half the days), which is a cost, not a
quality, problem; section 6 says why.

## 2. What the pool holds (2026-10-24)

63 live courses, 2,477 live documents, 3.6 MB of text. By kind:

| kind | documents | courses | median length | note |
|---|---|---|---|---|
| assignment | 1,218 | 59 | 102 chars | half are a title and a due line |
| page | 556 | 16 | 2,170 | 421 of them in one course (CIS 4500), 6 updated this term |
| module | 352 | 47 | 196 | titles only |
| ed | 123 | 10 | 412 | since 2026-09-28 |
| announcement | 122 | 10 | 553 | 104 from phones, 18 from the extension |
| file | 53 | 1 | 776 | PDFs, all from the extension, all one course |
| syllabus | 50 | 36 | 3,677 | **18 are stubs under 300 characters** |
| website | 3 | 1 | 3,556 | the crawl has run for one course, ever |

Two facts the notes had wrong, fixed in CLAUDE.md with this commit. The
Chrome extension **has** run in a real Chrome: by 2026-10-24 20:00 UTC it
had uploaded 692 documents across 10 courses, including 53 PDF `file`
documents, so file download works for at least one course. And the
course-website path is dormant, not slow: `course_websites` holds 213
candidates, 38 rejected, 3 verified, and no row has ever been crawled
(`page_count` 0, `last_crawled_at` null everywhere). Section 5 has the
cause.

**Syllabus coverage is the number that matters most.** Of 63 courses, 28
have a real syllabus in the pool, 18 have only a stub (the Canvas syllabus
page saying, in effect, "see the attached PDF"; 10 of the 50 syllabus
documents mention an attachment or a PDF), and 17 have none. So for about
half of all classes, the one document that answers "late policy", "how much
is the final worth", "office hours" and "when is the midterm" is not there
to be retrieved. Where it is missing it is almost always a PDF in Canvas
Files or a page on an external course site.

Olisa's own seven classes, which is what a phone read can verify:

| class | what the pool holds | what a student can ask about |
|---|---|---|
| ACCT 1010 | syllabus 11k, 42 assignments, 16 announcements, 3 Ed | office hours with times (3 docs), dated midterm (3), weights (2), textbook, regrades, recordings, cancellations |
| PHYS 0151 | syllabus 9k, 60 assignments, 20 announcements, 6 empty pages | office hours (3), late rule (2), dated midterm (1), weights (1), attendance (3), lab preparation (13, mostly assignment lines) |
| CIS 4500 | syllabus 6.7k, **421 pages (6 from this term)**, 81 assignments, 39 Ed | everything above, but diluted by 415 pages from earlier years of a recycled site |
| CIS 3990 | syllabus 2.3k, 4 long assignments, 15 Ed | office hours (3), dated midterm (1), lab/project preparation (7) |
| LGST 1010 | **syllabus stub (153 chars)**, 27 modules (titles), 8 assignments, 27 announcements (16 under 120 chars) | announcements; no policy, no weights, no exam date |
| CIS 2400 | **no syllabus, no pages**, 13 assignments (12 are a title), 40 Ed | Ed posts: office hours (9), regrades (3), cancellations (3); no policy, no weights |
| CIS 2620 | **Ed only** (20 posts) | the midterm's room and date (from posts); nothing else |

The three CIS classes with no syllabus are the ordinary Penn CIS pattern:
the syllabus and schedule live on `seas.upenn.edu/~cisNNNN` or a
`github.io` site, which is exactly what the dormant website path was built
to fetch.

## 3. Thirty questions, and what happens to each today

Verdicts: **OK** the pool holds it and today's retrieval should find it;
**NP** not in the pool; **NR** in the pool but today's retrieval is likely to
miss or misrank it; **MB** retrieved but the model is likely to answer
badly. A second tag notes a secondary risk. Each row is a prediction from
the mechanics in sections 4 to 6 and the counts above; the phone read in
section 10 is how it gets confirmed.

| # | question | what the phone would retrieve and send | verdict |
|---|---|---|---|
| 1 | when is the ACCT 1010 midterm? | the syllabus passage naming it (3 docs carry "midterm" beside a date), the work list if Canvas lists it, the profile's `examDates` if extracted | OK |
| 2 | where is the CIS 2620 midterm? | the one Ed post naming a room; the Sections block never holds exam rooms, which the prompt says | OK |
| 3 | what's the late policy in CIS 4500? | 7 documents state a late rule, but 415 of the course's 421 pages are from earlier years, so a stale page's rule can outrank this year's; a short "Late policy" heading can end one passage while its text starts the next | OK, NR risk |
| 4 | what's the late policy for LGST 1010? | the 153-character syllabus stub; the real syllabus is a PDF | **NP** |
| 5 | how much is the final worth in PHYS 0151? | the grading table, flattened to one line ("Homework 20% Midterm 25% Final 30% …"), plus the profile's weights | OK, MB risk |
| 6 | how is my grade broken down in CIS 2400? | nothing: no syllabus, no pages, and the course website was never crawled | **NP** |
| 7 | what did my professor say this week in CIS 2400? | the newest dated Ed posts first (the recency rule of 2026-10-20, never yet asked on a phone) | OK |
| 8 | any announcements in LGST 1010 lately? | the newest announcements; 16 of 27 are under 120 characters, so the answer is mostly titles | OK |
| 9 | what do I need for lab this week? (PHYS 0151) | assignment lines that say "bring" or "required"; the lab manual itself is a PDF and the six course pages are empty | **NP** in part |
| 10 | when are office hours for ACCT 1010? | the syllabus passage with the times (3 docs) and the profile's `officeHours` | OK |
| 11 | who is the TA for CIS 3990? | the profile's `contacts` and the syllabus | OK |
| 12 | what's due tomorrow? | the work list in the context document, every due time in UTC, with "Current date" as a UTC instant: at 9 pm Eastern the model is told it is already tomorrow, and an 11:59 pm deadline reads as the next day | **MB** |
| 13 | what's due this week in CIS 4500? | as 12 | OK, MB risk |
| 14 | is lecture cancelled tomorrow? (ACCT 1010) | posts with "cancel" get the 1.4 boost, but nothing orders them by date unless the question has a recency word, so a September cancellation can outrank yesterday's | NR |
| 15 | where does CIS 2400 lecture meet? | the Sections sentence from the registrar (74 of 78 catalog rows now carry rooms, all `2026C`) | OK |
| 16 | what's the textbook for PHYS 0151? | 3 documents | OK |
| 17 | can I get an extension on HW 3 in CIS 4500? | the late rule ("extension" expands to "late"); "HW3" written without a space never matches "hw 3" | OK, NR risk |
| 18 | how do regrades work in CIS 2400? | 3 Ed posts | OK |
| 19 | what's on the CIS 2620 midterm? | 2 Ed posts that date the midterm; a review sheet would be a file or slide | OK, NP risk |
| 20 | explain the pumping lemma from lecture (CIS 2620) | nothing: no slides, and the prompt forbids outside knowledge | **NP** |
| 21 | did I submit HW 4? | the work line's `done` / `outstanding` (the completion state `docs/PRIVACY.md` says is never sent) | OK |
| 22 | what's the attendance policy in PHYS 0151? | 3 documents | OK |
| 23 | when is the CIS 3990 project due? | the assignment document and the work list | OK |
| 24 | are ACCT 1010 lectures recorded? | 7 documents | OK |
| 25 | what's the schedule for week 8 in CIS 4500? | the schedule table flattened to one line, so a date can attach to the wrong week; "8" is a lone digit that matches list numbers everywhere | NR, MB risk |
| 26 | what are the lab report requirements in PHYS 0151? | assignment lines; the lab manual is a PDF | **NP** in part |
| 27 | when's the exam in my cis class? | the matcher needs one course per department word; with four CIS classes it scopes to nothing and searches every course, so the answer can be another class's exam | NR |
| 28 | what about next week? (after 13) | the previous question glued in front, scoped to CIS 4500 | OK |
| 29 | how many points is the ACCT 1010 project worth? | the assignment document's Points line | OK |
| 30 | is there a curve in CIS 2620? | nothing but Ed | **NP** |

**Failure classification (primary verdict):** 19 OK, 6 not in the pool, 4
in the pool but likely not retrieved, 1 model answers badly. Secondary
risks: 3 more rows carry a model risk (the flattened tables and the UTC
dates), 2 more a retrieval risk. **Unverifiable:** the source chip under an
answer links only when the model's `<sources>` detail contains the
document's title (`CitationLinks.swift:116-131`), and the server prompt
asks instead for "a few words locating the fact, such as '§4 attendance,
p.2'" (`prompt.ts:99-110`) and offers no `ed` kind at all, so under the
current contract a chip links only when the model happens to quote the
title. Whether that happens on real answers is a one-question check on the
phone (section 10); the tests pin only the detail-equals-title case.

The shape of the result: **coverage is the first-order problem** (6 of 30
unanswerable, all of them a PDF or an external site), **dates are the one
model-side defect** that touches the most common question, and retrieval
loses a handful at the edges. Nothing here calls for a new model, a new
index or a new architecture.

## 4. Retrieval: what the code does and where it loses

The pipeline (`CourseSearch`, `BM25Index`, `PassageChunker`,
`QueryExpansion`, `CourseMatcher`; all `LowHangingFruitKit/Sources/
LowHangingFruitKit/Knowledge` and `Assistant`) is sound for the pool it
has. Passages are paragraphs packed to 160 words, hard cap 220, no
overlap, a paragraph over 220 words split on sentence ends
(`PassageChunker.swift:23-91`). Tokens are lowercased alphanumeric runs,
stemmed by a short suffix list, lone digits kept; BM25 with k1 1.2, b
0.75; up to 12 title tokens indexed with each passage
(`BM25Index.swift:28-170`). Nine query-only synonym groups
(`QueryExpansion.swift:41-51`). Kind boosts: syllabus 1.35 on policy words,
announcements and Ed 1.4 on "announce / posted / cancel / moved"
(`CourseSearch.swift:243-270`). Pool of 48, rerank, 3 per document, 8 sent
(`BackendAssistantResponder.swift:313-315`). The index is rebuilt in
memory on every question; for 3.6 MB of text across every class that is
cheap, and persisting it is not worth doing.

Where it loses, each verified in the source:

- **Table structure is destroyed at the last step.** `HTMLText` separates
  table cells with a space and ends rows with a newline, then the excerpt
  builder replaces every newline with a space before sending
  (`BackendAssistantResponder.swift:450`). A grading table or a weekly
  schedule reaches the model as one run-on line. This is the likeliest
  cause of a wrong "how much is the final worth" and a wrong "what's due
  week 8". Keeping the newlines costs nothing in tokens.
- **Headings are orphaned.** The chunker flushes when the next paragraph
  does not fit (`PassageChunker.swift:58-62`), so "Late Policy" can be the
  last line of one passage while "Assignments lose 10% per day" opens the
  next, which then contains no "late" token. No overlap carries it. A
  one-line fix: a short heading-shaped paragraph is never left as the
  tail of a chunk.
- **Letter-digit tokens never meet their spaced forms.** "HW3", "PS2" and
  "Exam2" are single tokens; "hw 3" is two (`BM25Index.swift:28-35`). The
  synonym table also lacks quiz/test, deadline/due, recitation/section and
  regrade.
- **The unscoped retry fires only on an empty scoped result**
  (`CourseSearch.swift:133-137`). One stray in-course passage sharing a word
  with the question suppresses it, and nothing tops up weak results from
  other courses. Combined with follow-up scoping inherited from up to four
  questions back, a wrong course gives one weak hit and no retry.
- **The course matcher** (`CourseMatcher.swift:80-126`) needs exactly one
  course per department word, so "my cis class" with several CIS classes
  scopes to nothing; aliases match by substring ("stats" inside "states");
  and it iterates a `Set`, so a question naming two departments can resolve
  differently between launches. It also ignores the student's own rename
  when Canvas supplies a name.
- **Recycled sites dilute the index.** CIS 4500's 421 pages (6 from this
  term; the oldest page in the pool is from 2013, the oldest assignment
  from 2020) all compete with this term's material, and a prior year's late
  policy is as retrievable as this year's. Nothing in the chunker, the
  index or the manifest knows the term.
- **The recency rule can take every slot.** With no window named, the
  picks can fill all eight (`BackendAssistantResponder.swift:434, 519`), so
  "what's the latest on the final exam?" can send zero syllabus passages.
  Glued follow-ups make it worse: a three-word question after a "recent
  posts" question inherits the recency word.
- **The embedding rerank is untested and partial.** It blends 0.65 BM25 and
  0.35 cosine over the first 600 characters, title excluded
  (`CourseSearch.swift:289-309`); a passage with no vector keeps its raw
  BM25 score and can leap past the blended ones; every test runs with a
  cold provider, so the blend has no coverage; and the first question after
  an install is BM25-only by design (the `NLEmbedding` trap). It is a
  bonus, not a lever: the misses above are vocabulary and structure, which
  a sentence embedding over 600 characters does not fix, and a vector index
  on the phone would add a cold-start trap the project has already hit
  once. Not worth more investment.

What the fixtures can and cannot measure: no test fixture resembles a real
syllabus. The largest is 400 words of repeated filler; none holds an HTML
table; the retrieval suite's "syllabus" is four short lines. So the
measurement this plan needs is a bench over a real knowledge base: a test
that loads a `course-knowledge.json` read off Olisa's phone (local only,
never committed) and prints the top three passages for the 30 questions.
That is the phone read asked for in section 10.

## 5. Coverage: the gaps, with their privacy cost

What the phone collects per class, with the caps that silently narrow it:
assignments (description, due, points); the 40 newest pages' bodies,
decided before unpublished pages are filtered, so a course with unpublished
pages gets fewer (`CanvasCourseContentClient.swift:79-90`); module titles
only; the syllabus from the syllabus page plus at most three
syllabus-named pages and three syllabus-named PDFs, the first 20 pages of
each (`CanvasSyllabusClient.swift:108-153`, `SyllabusTextExtractor.swift:47`);
announcements 120 days back; Ed staff, pinned and announcement posts. Two
things in that list can remove material already pooled, not just fail to
add it: every syllabus source is fetched under `try?`
(`CanvasSyllabusClient.swift:67-78`), so a 401 or a timeout reads as "no
syllabus", the course is still reported fully synced and the server retires
the syllabus for every classmate; and the 40-page cap is relative, so as
pages are edited an older page leaves the top 40 and is retired the same
way. Neither is in Known gaps today; both belong there.

The gaps, ranked by how many of the 30 questions they would open up:

**A. External course websites (CIS 2400, CIS 2620, and the CIS pattern
generally).** The path exists end to end: `sync` returns `websitesPending`,
the phone calls `discover-websites`, which verifies candidates and crawls
the best one into `website` documents (`discover-websites/index.ts:222-376`).
It has never produced a crawled page because of a bug on the phone:
`AppState+CourseKnowledge.swift:428-457` sends every pending course in one
call, the server refuses more than three ids with a 400
(`discover-websites/index.ts:53, 418-420`), and the `try?` swallows it. A
student in four CIS classes therefore never triggers discovery; the
extension chunks by three and is the only caller that ever has. Behind
that bug sit two narrower ones: the convention guesser knows only
`seas.upenn.edu/~cisNNNN/current/` and `cis.upenn.edu/~cisNNNN/current/`
(not `cisNNNN.github.io`), and verification demands the course code and a
term alias in the page's first 3,000 characters, with a PDF read as text,
so a real site can be rejected for good. **Privacy:** `docs/PRIVACY.md`
has no sentence about the website crawl at all; it is an existing omission
(the server fetches public pages with no credential), and fixing the path
should add one sentence under "What is sent to our server" saying the
server also reads the course's public website when the instructor links
one.

**B. Canvas Files through the extension.** Built, running, and uploading:
PDFs only (the design doc says "and plain text", the code filters to
`application/pdf`), newest 60 per course per run, text cut at 60,000
characters, never the file itself (`chrome-extension/src/adapters/files.js`,
`canvasDocuments.js:603-626`). The server accepts `file` as a census kind,
serves it only to clients that advertise the kind (the phone does), and has
**no per-course cap** for it (`manifest.ts:54, 527-553`), so a course with
400 PDFs would push all of them into every classmate's download. Unverified:
a course whose Files tab is visible (the one course with files is an
archive; the 2026-10-23 run found hidden Files tabs answering 401), and
whether the phone's search handles a 60,000-character document well (the
chunker will make 50 passages of it; the 3-per-document cap holds).
**Privacy:** PRIVACY.md L194-199 already says the extension collects "the
text of PDFs in a course's Files (slides, readings)", so no new promise;
but L9-16 and L93-96 list the pooled kinds without files, and L235-242 and
L257-261 call the pool "public content" and "the same syllabus and
assignment pages every enrolled student can already see", which is a
stronger claim for an instructor's slide deck than for a page. Those four
sentences should mention files.

**C. PDFs the phone could read itself.** The phone already extracts a PDF
whose name matches "syllabus". Widening that to "schedule", "calendar",
"logistics" and "policies" (still at most three, still 20 pages) catches
the LGST 1010 case without the extension. **Privacy:** L93-96 lists what
the app fetches and says "syllabus"; it would say "syllabus and schedule
files". Smaller than B, helps every Penn install, needs no laptop.

**D. Server-side extraction** (the server fetches a file by a signed URL the
phone hands it). Not worth doing: L74-77 and L93-96 promise the fetch is
done with the student's own session on the phone, the crawl in B already
does the extraction where the browser has the session, and a signed Canvas
URL is a bearer credential. Listed so nobody rebuilds it.

**E. Replies and staff answers inside Ed student threads.** Not reachable
without a new per-thread fetch and a new privacy sentence; parked by the
announcements plan already.

## 6. The model side

`ask/index.ts` and `_shared/prompt.ts`, read in full. The system prompt does
most things right: answer only from the document and the profiles; say
plainly when it is not there; prefer the document over the profile; treat
excerpts as part of the document and prefer them for policy; the Sections
block never holds an exam room. Three defects, two of them phone-side:

1. **Dates reach the model in UTC and nothing says so.** The context
   document renders every due time as `2026-09-05T03:59:00Z`
   (`AssistantContextDocument.swift:365-377`), and the user message says
   `Current date: 2026-10-24T01:15:22.123Z`
   (`prompt.ts:214`, `BackendWire.swift:766-776`). An 11:59 pm Eastern
   deadline is the next calendar day in UTC, and from 8 pm Eastern on,
   "today" is already tomorrow. The prompt has no rule about time zones.
   The byte-stability reason for UTC (the prompt-cache trap) does not
   require UTC: it requires the same bytes for the same student, and a
   student's zone is as fixed as their work list. Rendering in the
   student's zone with the offset, and sending the local calendar date and
   weekday, keeps the prefix stable. This is the one change that touches the
   most common question class ("what's due tomorrow", "when is X due"), and
   it needs no deploy: the server passes `askedAt` through.
2. **The citation contract does not ask for the title.** Section 3 covers
   it. The fix is two sentences in the prompt (name the document's title in
   `detail`; add `ed` to the kinds) and one line on the phone (accept `ed`).
3. **No rule for conflicting posts.** Nothing tells the model to prefer the
   newest post when two posts disagree, or that a staff post can override
   the syllabus (a moved exam). One sentence.

Smaller: `temperature` 0.2 where 0 would be more reproducible for extraction
Q&A (`ask/index.ts:83`); `PROTOCOL.md` still names glm as the primary and a
`gpt-5.6-luna` fallback (fixed with this commit); the probe set
(`ask-probe.mjs`) is three synthetic questions over one fixture with fake
course ids, so the canary has never measured a real catalog block, a real
profile, an Ed excerpt or correctness; and prompt caching is at the mercy of
OpenRouter's routing because no provider order is pinned
(`openrouter.ts:231-241`), which is the likeliest reason half the days show
zero cached tokens. Pinning an order is a canary experiment, a cost saving,
and nothing a student would notice.

Not worth doing on this side: a cheaper or different primary (every real
question was answered by 4.1-mini inside 4 s; the 2026-09-22 measurement
stands); a two-step retrieve-then-answer with a server re-query (the server
holds no index, the second call would add a second 10k-token prompt and two
seconds, and the misses are coverage, not query phrasing); and a reasoning
model (the glm episode).

## 7. Product

Each one paragraph, with the privacy note. None is ranked above the fixes in
section 8 because none answers a question the tree gets wrong today.

**A daily "what changed" card.** The megaphone already lists the past 7
days' posts; the tree could open with one card, built on the phone from
the pooled announcements and Ed posts newest first ("3 posts since
yesterday: CIS 2400 moved office hours; PHYS 0151 lab 6 prep …"), using the
same recency picks the excerpt block uses, and a tap asks the question that
produced it. On-device only, no model: nothing new leaves the phone, and
one bullet under "What stays on your phone" says the card is built from
material already synced. Sending the picks to the model for a summary is
the same request the tree already makes, so it adds no privacy change, but
it spends a quota slot per day per student and should wait until the pool
is worth summarising.

**Quick actions from an answer.** Today an answer offers source chips only:
no copy, no retry, no "add as task", no "open the post" except through a
chip that links. Three on-device actions earn their place: open the cited
post (the chip, made reliable by the citation fix), "add to my list" when
the answer names an undated or unlisted task (the add sheet exists), and
"remind me" (the reminder scheduler exists). All three act on the phone and
send nothing; PRIVACY.md needs no change.

**Per-class memory.** The conversation lives in a `@StateObject` and is
gone when the screen closes (`AssistantConversation.swift:30`); the
follow-up scoping is the only memory. Keeping the last few questions per
class on the phone (in `UserDefaults.lhf`, cleared on disconnect) would let
"what about the lab?" work a day later and let the tree suggest the
student's own recurring questions. On-device only, it needs one bullet
under "What stays on your phone" and one clause in the deletion paragraph.
Sending those turns with a question is a different proposal: it changes
L123-128 ("the app sends the question, an on-device summary … and the most
relevant excerpts") and L239-242 ("There is no transcript") would need
re-reading, and nobody has approved it. The server already caps `history`
at ten turns and 8,000 characters if it ever arrives.

**Spoken answers.** `AVSpeechSynthesizer` reading the streamed text, on the
device, with the mic that already exists: no new data leaves the phone, and
the "audio never leaves the phone" sentence stays true. Set aside on
2026-10-22 for dictate-then-send; still the right order.

**Concept questions.** Question 20 fails by design: the prompt forbids
outside knowledge, which is right for policies and dates and wrong for
"explain the pumping lemma". Letting the model answer a concept question
from general knowledge when no excerpt covers it, labelled as such and
with no chip, is a one-sentence prompt change and a product decision: the
tree would then sometimes be a tutor. Worth a decision, not a default.

## 8. Ranked improvements

Ranked by effect on the 30 questions per hour of work. "Deploy" means an
Edge Function deploy, which needs Olisa's go; "privacy" means a sentence of
`docs/PRIVACY.md` changes in the same commit. Hours are for a session with
a toolchain, including tests.

| # | change | effect on the 30 | hours | deploy | privacy |
|---|---|---|---|---|---|
| 1 | Local dates in the context document and the user message | fixes 12, protects 1, 13, 23, 29 (every deadline question after 8 pm) | 3 | no | one clause: the student's time zone offset is sent |
| 2 | Chunk the `discover-websites` call by three on the phone; then widen verification | opens 6, 30, part of 2 and 19 (CIS 2400, CIS 2620), and every CIS install | 2 phone + 4 server | the server half | one sentence: the server reads the course's public website |
| 3 | Keep passage newlines in excerpts; separate table cells with " \| " | fixes the MB risk on 5, 25, 3 | 2 | no | no |
| 4 | Citation contract: title in `detail`, `ed` kind; phone accepts `ed` | chips link on most answers (the unverifiable class) | 2 + canary | yes, `ask` | no |
| 5 | Phone reads schedule/calendar/policy PDFs like it reads a syllabus | opens 4, part of 9 and 26 | 3 | no | "syllabus" becomes "syllabus and schedule files" at L93-96 |
| 6 | Heading-aware chunking (never leave a heading as a chunk's tail) and letter-digit token splitting | fixes the NR risk on 3, 17; helps every policy question | 3 | no | no |
| 7 | Unscoped top-up when scoped results are weak; deterministic matcher; several courses per department word fall back to the follow-up course | fixes 27; protects follow-ups | 3 | no | no |
| 8 | Term filter at index time: pages and assignments last updated more than a year before the term start are excluded from retrieval | fixes 3 and 25's stale-site risk for recycled sites (CIS 4500 today) | 3 | no | no |
| 9 | Cap recency picks at four when no window is named and the question has other content words | fixes the crowding on "latest on the final" shapes | 1 | no | no |
| 10 | Syllabus `try?` and failed page bodies count as errors, so a bad fetch cannot retire a classmate's syllabus | protects the pool; no question today | 2 | no | no (touches the sync: tell Marco) |
| 11 | Per-course cap on `file` in `download`; verify files on a course with a visible Files tab | makes B safe before it grows | 2 + a laptop run | yes, `sync` | four sentences mention files (section 5B) |
| 12 | Prompt: prefer the newest post on conflict; `temperature` 0; a real-excerpt probe set with a dated-post case and an evening "due tomorrow" case | correctness on 14 and 7; a canary that can measure | 4 | yes, after canary | no |
| 13 | Pin a provider order on the canary and read `cached_tokens` | cost only | 1 + canary | yes, after canary | no |
| 14 | Quick actions under an answer (open post, add task, remind me) | product | 6 | no | no |
| 15 | Per-class memory on the phone | product | 4 | no | one bullet |
| 16 | Daily "what changed" card | product | 6 | no | one bullet |
| 17 | Spoken answers | product | 4 | no | no |

Per item: files, test prediction, risk.

1. **Local dates.** `AssistantContextDocument.swift` (`isoTimestamp`, the
   header sentence that explains dates), `AssistantContextAssembly.swift`,
   `BackendAssistantResponder.swift` (a `localDate` line in the user
   message: weekday, date, zone), `BackendWire.swift` if a field is added,
   `backend/PROTOCOL.md`. Server: none; `askedAt` stays. Tests:
   `AssistantContextDocumentTests` pins the `Z` shape and must be rewritten
   to pin the offset form and byte-stability across two renders; one new
   test that a 23:59 Eastern deadline renders on its own day. Prediction:
   same count, three tests rewritten, two added. Risk: a student who
   travels changes the prefix once per zone, which re-bills one request;
   the zone offset is a new byte leaving the phone and must be named in
   PRIVACY.md L123-128.
2. **Website discovery.** Phone: `AppState+CourseKnowledge.swift:448-457`
   dedupes and chunks `websitesPending` by three, as
   `chrome-extension/src/collectRun.js:65-69` does, and the diagnostics
   summary records how many calls were made. Server, separately and after
   the phone fix has produced its first verification: `_shared/websites.ts`
   (`conventionURLs` gains `cisNNNN.github.io`; `verifyPage` accepts a
   `canvas-link` or `penn-labs-syllabus` candidate on code or term, not
   both; a PDF candidate is parsed, not read as text) and
   `discover-websites/index.ts`. Tests: one Swift test on the chunking;
   Deno tests on the verification table. Prediction: +1 Swift, +4 Deno.
   Risk: the crawl is server egress to Penn hosts that has run for one
   course ever; the first live run must be watched for 400s and timeouts
   in the function log before the server half is touched. A wrongly
   verified site pools a stranger's pages under the class; the code-hit
   rule stays for `convention` guesses.
3. **Excerpt structure.** `BackendAssistantResponder.swift:450` keeps the
   newline (the model reads it fine) and `HTMLText.swift:24` writes " | "
   between cells. Tests: `AskExcerptChannelTests` and `RetrievalStrengthTests`
   pin the flattened form and are rewritten; one new test with a two-row
   table. Prediction: same count plus one. Risk: none to the prefix (the
   excerpts follow it); a 1,500-character cut now falls inside a row, which
   `cutAtWordBoundary` already handles.
4. **Citations.** `prompt.ts:99-110` (title in `detail`; kinds gain `ed`),
   `CitationLinks.swift:107-112` (accept `ed`), `AskCitationLinkTests`.
   Measured on `ask-canary` with the real excerpt format (item 12's probe
   set, or by hand) before `ask` is deployed. Prediction: +2 Swift tests.
   Risk: a longer `<sources>` line; the parser needs exactly three fields,
   so a title containing "|" must be stripped on the phone.
5. **Schedule PDFs on the phone.** `CanvasSyllabusClient.swift:134-163`
   (search terms), `SyllabusTextExtractor.swift`, `docs/PRIVACY.md` L93-96.
   Kind stays `syllabus` so nothing downstream changes. Tests:
   `SyllabusMatcherTests`. Prediction: +3. Risk: a "schedule" PDF that is a
   room schedule for the whole department; the three-file cap and the
   syllabus boost make that a mild misrank, not a wrong answer. Touches
   the collector (tell Marco).
6. **Chunking and tokens.** `PassageChunker.swift:58-62` (a paragraph of
   eight words or fewer with no terminal punctuation is carried forward),
   `BM25Index.swift:28-35` (emit both "hw3" and "hw" "3"),
   `QueryExpansion.swift:41-51` (quiz/test, due/deadline,
   recitation/section, regrade). Tests: `RetrievalStrengthTests`,
   `CourseKnowledgeTests`. Prediction: +5. Risk: index size grows a little;
   a heading carried forward duplicates eight words.
7. **Scope.** `CourseSearch.swift:133-137` (top up to the limit with
   unscoped hits ranked below the scoped ones when the scoped best score is
   under a threshold, or fewer than three hits), `CourseMatcher.swift:100-124`
   (iterate sorted; a department word with several matches yields no scope
   and lets `FollowUpRetrieval` supply the previous course). Tests:
   `FollowUpRetrievalTests`, a new `CourseMatcherTests` case. Prediction: +4.
   Risk: a top-up can bring another class's policy into a scoped question;
   the excerpt line names the course, and the prompt already says which
   course each fact is about.
8. **Term filter.** `CourseSearch.swift` (exclude from the index a page or
   assignment whose `updatedAt` is more than 365 days before the current
   term's start, computed from `askedAt`; syllabi, modules and posts are
   never filtered) with the term boundary from the same
   `academicSemester` rule the server uses. Tests: new. Prediction: +3.
   Risk: a course that genuinely reuses last year's policy page loses it;
   the syllabus still carries the policy. Decide the cut-off from the phone
   read, which shows how old the retrieved pages are.
9. **Recency cap.** `BackendAssistantResponder.swift:497-528`. Tests:
   `AskRecencyExcerptTests`. Prediction: +2. Risk: none.
10. **Pool safety.** `CanvasSyllabusClient.swift:64-80`,
    `CanvasCourseContentClient.swift:90`, `CourseKnowledgeCollector.swift:
    258-279` (a failed source puts the course in `partialCourseIDs`, which
    the 2026-10-23 salvage already honours). Tests:
    `CourseKnowledgeCollectorPartialSyncTests`. Prediction: +3. Risk: a
    course with a permanently failing syllabus endpoint is partial forever
    and never pruned, the same accepted edge the salvage recorded.
11. **Files cap.** `_shared/manifest.ts:94` (a 200-per-course cap on `file`
    in `download`, newest first, like the window kinds), `PROTOCOL.md:104`
    (the kinds list lacks `file`). Deno tests. Prediction: +2 Deno. Risk:
    none; the cap only trims what one phone is handed.
12. **Prompt and probe.** `prompt.ts` (one sentence on newest-post
    precedence), `ask/index.ts:83`, `backend/scripts/ask-probe.mjs` (a set
    built with the phone's real excerpt line format, including an Ed post
    dated last week and an older conflicting one, and an `askedAt` at
    01:00 UTC with a 23:59 deadline). Measured on `ask-canary`: 20 runs,
    read `ask_outcomes` by tag, read the answers by eye. Deploy `ask` with
    Olisa's go. Risk: temperature 0 can make a wrong answer repeat exactly;
    the canary shows it first.
13. **Provider order.** `LHF_PROVIDER_ORDER` on the canary only, then read
    `cached_tokens` on 20 runs against 20 without. A secret change needs
    Olisa's go even on the canary.
14. to 17. Product items, section 7; each is its own brief once 1 to 9 are
    on a phone.

## 9. Not worth doing, and why

- **An on-device vector index or embeddings as the primary ranker.** The
  misses are coverage and structure; the `NLEmbedding` trap cost a
  two-minute hang once; the existing blend is a bonus and should stay one.
- **Sending the whole knowledge base, or more than eight excerpts.** The
  prompt is already 8k to 15k tokens; the pool is 3.6 MB; the excerpts
  that miss are missing because they were never collected.
- **A different primary model, a shorter hedge or a reasoning model.** The
  hedge has never fired on a real question; first word is 2.4 s median.
- **Retrieve-then-answer with a server re-query.** The server has no index;
  a second round trip doubles the prompt bill and adds two seconds for a
  problem that is not query phrasing.
- **Server-side file extraction with the phone's credentials** (section 5D).
- **Persisting the BM25 index.** Rebuilding 3.6 MB in memory is cheap.
- **A bigger synonym table beyond the four groups in item 6.** Each group is
  a guess; the phone read says which words students actually use.
- **Sending conversation history** before Olisa and Marco decide the
  privacy sentence; item 15 gets most of the benefit on the phone.
- **Taking completion state out of the summary as a side effect of this
  plan.** It is a published-promise decision (ROADMAP → Now), not a
  retrieval change, and removing it makes "what am I missing" worse. The
  plan only records that question 21 depends on it.

## 10. The three things to do first, and what is needed

1. **Local dates (item 1).** Phone-only, three hours, protects the most
   common question. Needs: nothing from Olisa beyond the compile and one
   evening question on the phone ("what's due tomorrow" after 8 pm, and
   "when is X due" for an 11:59 pm item).
2. **Chunk the website discovery call (item 2, phone half).** Two hours,
   opens the two classes with nothing in the pool. Needs: after the build is
   on the phone and one sync has run, a read of `course_websites` for the
   CIS courses (status, `verified_term`, `last_crawled_at`) and the
   `discover-websites` function log for 400s; then a decision on the server
   half.
3. **Excerpt structure and the citation contract (items 3 and 4).** Four
   hours plus a canary run. Needs: Olisa's go for the `ask-canary` deploy
   and, once 20 runs read clean, for `ask`.

What I need from Olisa, in order:

- **A phone read.** `course-knowledge.json` and `announcement-log.json`
  copied off his iPhone (Commands in CLAUDE.md; the course-knowledge file
  sits beside the announcement log in the App Group container), into a
  local folder that is never committed. With it, a bench test over the 30
  questions replaces every "predicted" in section 3 with a measured top
  three, and decides the term cut-off in item 8 and the synonym words in
  item 6. Also, from the phone itself: ask questions 7 and 12 and say
  whether the source chips under the answers are tappable.
- **A canary run go**, for item 4 and item 12 together, once the probe set
  is rewritten.
- **Two decisions**, neither blocking the three items above: whether the
  tree may answer concept questions from general knowledge when no excerpt
  covers them (section 7, last paragraph), and the completion-state
  sentence already in ROADMAP → Now.

**Running the bench** (2026-10-25). `RetrievalBenchTests` loads a
`course-knowledge.json` and prints, for each of the 30 questions, the course
the matcher chose, whether the recency rule fired and the exact excerpt lines
`ask` would send (it calls the phone's own `excerptBlock`). The file is in the
app's private container, not the App Group: `CourseKnowledgeStore` keeps it
under Application Support, beside `announcement-log.json`
(`CourseKnowledgeStore.swift:17-23`). Copying it works only from a developer
build installed over the store copy (Commands in CLAUDE.md). `~/lhf-bench/` is
outside the repo and must stay there: the file holds the student's course text
and is never committed. With the variable unset the test does nothing. Optional
`LHF_BENCH_QUESTIONS` (one question per line, `>` marks a follow-up) and
`LHF_BENCH_ASKED_AT` (ISO 8601) change the questions and the pinned "now".

```bash
mkdir -p ~/lhf-bench
xcrun devicectl device copy from --device <CoreDevice id> --domain-type appDataContainer --domain-identifier com.lhf.lowhangingfruit --source "Library/Application Support/LowHangingFruit/course-knowledge.json" --destination ~/lhf-bench/course-knowledge.json
cd LowHangingFruitKit && LHF_BENCH_KNOWLEDGE=~/lhf-bench/course-knowledge.json swift test --no-parallel --filter RetrievalBenchTests
```

## 11. Status

- **2026-10-25.** Olisa: "put your plan into action". Written blind in
  the cloud container, nothing compiled: items 1, 2 (phone half), 3 and 4
  (server half), the `RetrievalBenchTests` bench of section 10, and the
  `citations` probe set with `--asked-at` and `--temperature`. Predicted
  `swift test` delta: +17 tests (13 for dates and excerpts, 3 for the
  chunking, 1 for the bench), +2 suites, nothing removed; the Mac's count
  wins. Deno 468/0 before and after the prompt change. The `ask-canary`
  deploy was refused by the session's permission classifier as a
  production deploy, so the new prompt is not live anywhere; the command
  is `node backend/scripts/deploy-function.mjs ask-canary --also ask`
  from a shell with the Management API token. A 6-run baseline of the
  `citations` set against the canary's old prompt (tag `cite-base`): 6/6
  answered, first word median 2.5 s, 13.2k of 14.6k prompt tokens cached
  from the second run on, 2/2 midterm answers named the newer post's room
  without the new sentence, 3/6 `<sources>` details carried a known title
  verbatim (case-sensitive count; the phone folds case, so the real
  linkable share is higher), and the model wrote `ed discussion` as its
  kind word, which the phone already accepts. So item 4's effect is
  smaller than section 3 feared; the deploy still earns its place by
  making the title the rule rather than the habit.
