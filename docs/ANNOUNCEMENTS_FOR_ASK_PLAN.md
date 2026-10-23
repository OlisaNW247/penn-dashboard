# Announcements for ask: Canvas and Ed, pooled properly

Written 2026-10-23 for Olisa, from a read-only survey of the client, the
backend and the live table. The ask was: "make sure the tree has access to
announcements from both Canvas and Ed and organize that properly in the
backend." This is the plan. Nothing in it is implemented yet.

## 1. What is true today

The live table on 2026-10-23 (19 anonymous users, 76 courses):

| kind | live rows | courses | newest | note |
|---|---|---|---|---|
| ed | 95 | 6 | 2026-10-22 | 57 announcements, 18 pinned, 20 staff posts |
| announcement | 9 | 1 | 2026-04-07 | all from one spring class |
| page / syllabus / module / assignment | 904 | most | | not this plan's subject |

**Canvas announcements never reach ask.** The course-material collector
asks Canvas for announcements from 200 days back and sends no end date.
Canvas closes the window 28 days after it opens, so the request is for
posts between about 200 and 172 days ago: a spring window, in October.
That is the whole reason the table holds nine spring posts and nothing
from this term. Everything downstream of that call is already built and
tested: the `announcement` document kind, the id scheme, upload and
pooling, the search boost (announcements and Ed posts get the same 1.4
boost on "announce / posted / cancel / moved" questions), the
newest-first picks for "what's new" questions, the `posted Oct 18` tag on
excerpts, citations, and the on-device "latest announcements" answer.
They are fed nothing. The on-device megaphone list is a separate path
that works (60 days, with an end date), but it never leaves the phone by
promise, and ask does not read it.

**Ed posts reach ask, with limits.** One request per class for the newest
100 threads, no paging; a 120-day window on *last activity*; each
successful read replaces the class's whole Ed set, so a pinned post
beyond the 100th newest vanishes; a sign-out halfway through a run
deletes the Ed documents of the classes not yet read; server rows are
never marked gone, so a deleted thread stays pooled forever; the
privacy page promises anonymous posts never leave the phone and nothing
enforces it (`isAnonymous` is decoded and never read); replies and staff
answers inside student questions are never captured. Ten CIS 3990 posts
on the server still carry no posting day, which means that class has not
had a successful Ed read since the header gained the date on 2026-10-19.

**The backend treats every kind the same, and that is the problem.** One
table, one id scheme, one gone rule, one unpaginated read:

- The gone rule marks a document gone the moment one phone's complete
  list for a class omits it. Right for a syllabus. Wrong for a post that
  one phone fetched in a narrower window than another, or whose fetch
  failed: that phone would mark every classmate's pooled announcements
  gone. Ed is exempt; announcements are not.
- The validator rejects an empty title or empty body by throwing, and the
  function turns that into a 500 for the whole 200-document batch.
  Canvas announcements can have both (an untitled post, an image-only
  body). Today harmless, because none are collected.
- The announcement document's text opens with `Posted: Tue, Apr 7 at
  4:52 pm`, rendered in the device's time zone and locale, so two
  classmates in different zones hash the same post differently and keep
  re-uploading it to each other. Ed's header uses a fixed Eastern
  `· posted 2026-10-20` token for exactly this reason.
- The manifest reads every live document of the student's classes, full
  text included, in one query, and the project's PostgREST `max_rows` is
  1000 (confirmed on the live project). The biggest class already has 164
  live documents. A term's announcements are 30 to 60 per class, so a
  student in eight classes crosses 1000 rows once they flow, and the
  manifest silently truncates: pooled documents never arrive, and the
  profile-staleness diff compares two truncated snapshots.
- `ask` itself never reads the table. Retrieval is on the phone. So
  "organize the backend" means: store the right rows, keep them current,
  and hand each phone the right set, so the phone's search has them.

## 2. What "done" looks like

Asked "what did my professor announce in CIS 2400 this week", the tree
answers from both the Canvas announcement and the Ed post, dated, cited,
newest first. The pool holds one copy of each post per class, posted
within the last 120 days, no author, byte-identical on every phone. A
phone that cannot read Ed still gets the pooled Ed posts for a class it
is in. No phone can delete a classmate's announcement by having a bad
fetch. A student in ten classes gets every pooled document.

## 3. The plan, in order

Each phase is independently shippable and verifiable. Phase 1 is the
one that matters; 2 protects it; 3 and 4 are the Ed and organization
work the request also asked for.

### Phase 1. Make Canvas announcements flow (client; one afternoon; blind until compiled)

Files: `CourseKnowledgeCollector.swift`, `CanvasCourseContentClient.swift`
(`CourseDocumentBuilder.announcement`), `EdDocumentHeader.swift`,
`AppState+CourseKnowledge.swift`, tests.

1. **The window.** Pass `until: now + 1 day` from the collector, and
   look back 120 days (Ed's window) instead of 200. The URL test that pins
   "no `end_date` when `until` is nil" stays true; add a collector test
   whose Canvas stub honours the 28-day default and proves this term's
   posts come back.
2. **A byte-stable header, the Ed way.** Replace the device-zone
   `Posted: …` line with `[canvas · announcement] · posted yyyy-MM-dd`
   (Eastern day, the same token `EdDocumentHeader` already writes and
   parses), and teach `shownPostedAt` to read it for `.announcement` as it
   does for `.ed`. Same hash on every phone; the recency picks and the
   `posted` tag keep working; the nine old rows re-upload once with the
   new hash.
3. **Never produce a document the server rejects.** An untitled post gets
   the title `Announcement` plus its date; a post with no body after
   stripping is skipped (it is an image, and nothing can be retrieved
   from it).
4. **A failed announcements call must not erase announcements.** Port the
   one rule from `parked/ask-course-sync-fixes` that matters here: when
   the announcements request fails, no class counts as fully synced that
   run, so the merge keeps the stored announcements and the server is not
   told they are gone. (The rest of that branch stays parked.)
5. **Force one run.** Bump `courseKnowledgeSyncVersion` to 5 so every
   install re-collects on its next refresh.

This touches the course-material sync, which the notes say Marco asked
not to touch. The owner asked for this directly on 2026-10-23, which is
the go; Marco should be told before it merges. `docs/PRIVACY.md` already
says announcements are fetched and pooled, so no privacy text changes.

Verify: `swift test --no-parallel`; build to the phone; after one sync,
`select count(*) from course_documents where kind='announcement' and
updated_at > now() - interval '30 days'` through the Management API is
non-zero for your classes; ask the CIS 2400 question above.

### Phase 2. Make the backend safe for window-sourced kinds (Deno; testable here; deploy needs the go)

Files: `_shared/db.ts`, `_shared/manifest.ts`, `sync/index.ts`,
`PROTOCOL.md`, one migration, Deno tests.

1. **Two classes of document.** Name them in `manifest.ts`: *census*
   kinds (syllabus, home, page, module, assignment, website), where a
   phone's complete list is the truth and absence means gone; and
   *window* kinds (announcement, ed), where each phone sees a window and
   absence means nothing. The gone rule applies to census kinds only
   (today's `.neq("kind", "ed")` becomes the window list). PROTOCOL says
   so.
2. **Window kinds age out server-side instead.** Live reads of window
   kinds keep rows posted within 120 days (`updated_at` for Ed is last
   activity, which is the same rule the phone uses; announcements carry
   the post time). A nightly job is not needed: the live select filters,
   and a later cleanup can delete rows older than a year. This also ends
   "a deleted Ed thread stays pooled forever": it stays at most 120 days
   past its last activity.
3. **Paginate the live read.** `selectLiveDocumentsForCourses` fetches in
   `.range()` pages of 500 until a short page, and the upload's before
   and after snapshots select only `id, kind, content_hash`, not text.
   Deno test with a fake client that returns 1000-row pages.
4. **Reject a bad document, not the batch.** `validateDocument` failures
   are collected and returned as `rejected: [{id, reason}]`; the rest of
   the batch lands. The phone logs the count in its sync summary.
5. **A posted date column.** Migration: `posted_at timestamptz` on
   `course_documents`, an index on `(course_id, kind, posted_at desc)
   where gone_at is null`, and `postedAt` as an optional wire field that
   the phone sends for announcement and Ed documents. The server fills
   `posted_at` from the wire or, for an Ed row without it, from the
   header token, so old rows get a date on their next upsert. Then the
   age-out in step 2 uses `posted_at` and the per-class cap below is
   exact. This is the "organize it properly" step; everything above
   works without it, with `updated_at` as the stand-in.
6. **Cap what a phone is handed.** The manifest's `download` for window
   kinds is the newest 150 per class by `posted_at`. A class that has
   posted 400 times does not push a phone over its own limits.

Deploy `sync` only (ask does not read the table). Verify with
`deno task test`, the 2.1 type check, and the live counts.

### Phase 3. Fix the Ed reader's holes (client, Olisa's scraping logic; one to two days; blind)

Files: `EdClient.swift`, `EdIngestion.swift`, `EdThreadFilter.swift`,
`EdDiscussionCoordinator.swift`, tests, `docs/ED_DISCUSSION.md`.

1. **Page until the window closes.** Read pages of 100 sorted newest
   until the page's oldest thread is past 120 days or three pages are
   read. Pinned and announcement posts beyond the 100th newest stop
   vanishing.
2. **Keep the anonymous promise.** Drop a thread whose `isAnonymous` is
   true, before the announcement and pinned rules. The privacy page
   already says this; the code will then match it.
3. **A sign-out mid-run restores, never drops.** Classes not reached
   after a 401 are "matched, not read" and keep their stored documents.
4. **Why CIS 3990 has no dates.** Read the Ed status row on the phone
   after a sync; if that class never completes a read, the cause is in
   the coordinator (one Ed session serves every class from the first
   class with a tab) and is fixed here.
5. Out of scope, recorded: replies and staff answers inside student
   questions. Ed has no endpoint in the client for them; adding one is a
   new fetch per thread and a new privacy sentence.

### Phase 4. One Canvas announcement path on the phone (later; a decision, not just code)

The megaphone's Canvas rows come from a local 60-day log that the privacy
page promises is never uploaded; ask's come from the pooled documents.
Once Phase 1 flows, the log is a second copy of the same posts with a
narrower promise. The clean end state is one source: the megaphone and
the Announcement Watcher read pooled `.announcement` documents exactly as
they already read `.ed` ones, and the log file goes. That changes a
published promise ("that file is never uploaded" becomes "those posts
are pooled, as the material section already says"), so it is Olisa's and
Marco's call, and it is not needed for ask. Until then the two paths
disagree only on hidden classes (the log skips them; the pool does not)
and on window (60 vs 120 days), and neither matters to ask.

## 4. What does not change

- `ask`'s prompt and the context document: retrieval stays on the phone;
  the context document's announcements section stays empty on purpose
  (it is the byte-stable cached prefix). The excerpts carry the posts.
- The recency rule, the search boost, the citation chips: already in
  place for both kinds.
- The privacy posture: announcements and Ed posts are already disclosed
  as pooled course material; no author is ever stored; the student's own
  data never leaves the phone. Phase 3 step 2 makes an existing promise
  true rather than changing it.

## 5. Risks and the wrong fixes

- Shortening the look-back to 28 days to dodge Canvas's default: wrong,
  it just moves the dead window. Pass the end date.
- Exempting announcements from the gone rule without an age-out: the
  table grows forever and old posts keep being handed to phones. Do both.
- Raising `max_rows`: the next class over the new limit truncates again,
  silently. Paginate.
- Fixing the validator by lowering the standard (allowing empty text):
  an empty document is retrievable by nothing. Skip it on the phone and
  reject it alone on the server.
- Adding a second table for posts: the phone's search, the manifest and
  the id scheme all assume one table; the census/window split is a
  policy, not a schema.

## 6. Sequence and gates

1. Phase 1 on `v8`, compiled and on the phone, then the DB count check.
2. Phase 2 steps 1 to 4 deployed as `sync` v11 (go needed), then step 5's
   migration (go needed) and step 6.
3. Phase 3, compiled, on the phone, with the CIS 3990 check.
4. Phase 4 when the owners decide.

Pending from before and unrelated to this plan: the semester fix on
`v8` (`396e464`) is still not deployed; 11 catalog rows still hold
Spring 2027 sections.
