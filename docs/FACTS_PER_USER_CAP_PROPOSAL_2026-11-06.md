# Per-user cap on fact extraction: a proposal for the owners (2026-11-06)

Status: proposal only, nothing here is built. It answers bug hunt item 22
(`docs/V10_BUG_HUNT_2026-11-05.md`): "One account can spend the global
monthly cap. Enrollment is only asserted (extract-facts/index.ts:47-63); the
per-course cap exists, no per-user cap across courses." It was parked as
"needs a schema decision (owner)". The decision has a privacy cost, so it is
Marco's and Olisa's, not a session's. Line numbers are as read on 2026-11-06
on `v10`.

## 1. The problem

Anyone holding an anonymous account can make the server pay for model calls.
Two doors lead to the same meter. `sync` schedules extraction after every
upload that changed an eligible document (`sync/index.ts:457`, through
`scheduleFactExtraction`, `_shared/factsExtraction.ts:712-731`), and
`extract-facts` runs it on request for every course the caller is enrolled
in (`extract-facts/index.ts:47-63`, capped at `MAX_COURSES = 60`, :24, :61).
Enrollment is a row written when a manifest call lists a course
(`20260907000000_init.sql:90-106`; PROTOCOL.md's Limitations, ~:1316, says
it is asserted, not proven). An edited document is a new
`(document_id, content_hash)` pair and is paid for again
(`20261104090000_course_facts.sql:87`), so a client that uploads a document
with a changed byte on every call mints a fresh paid extraction each time.

Today's bounds are all per course, plus one global: 60 a day and 400 a month
per course, 5000 a month overall (`claim_fact_extraction`, course_facts.sql
:174-267; env overrides at `factsExtraction.ts:572-574`). A per-course cap
stops one account from draining one course; it does not stop one account from
walking across many. The effective ceiling for an account enrolled in N
courses is min(N x 400, 5000) extractions a month, and 13 courses reach it.
A failed call still spends a unit (the comment at course_facts.sql:131-132
says so, and each retry is a new claim, :263-266), so a document that fails
all three attempts costs three units.

Worked number. Recorded cost per extraction on Haiku 5.5 was 0.000403 to
0.001150 USD, about 0.0067 USD for ten (`docs/DEPLOY_FACTS_2026-11-04.md`
Run record, ~:150-160), say 0.00067 USD average.

- One account, one month, at the global cap: 5000 extractions, about 2.02 USD
  at the low figure, 3.35 at the average, 5.75 at the high.
- The same account inside a single course: 400 extractions, about 0.27 USD.
- Cost is therefore small. The real damage is the other half of the cap: once
  one account has spent the 5000, every other course's documents are marked
  `skipped_budget` ('monthly global cap', course_facts.sql:225-230) until the
  1st, so every student loses new facts. This is a denial of service on a
  shared feature that happens to cost a few dollars, not a billing risk.
- It can also happen by accident: a bug that re-uploads a changing document
  (a timestamp inside page text) does the same thing without malice.

Unverified here, and worth a minute from Olisa: whether a manifest call can
create enrollments in course ids that no real student has (fabricated ids),
and whether enrollments per user are bounded across calls. The per-call limit
is 60 (`sync/index.ts:73`), but nothing I read bounds the total.

## 2. Facts the decision rests on

**The uploader is not attributable today.** `course_documents`
(`20260907000000_init.sql:45-62`) has no user column: id, course, code, kind,
source id, title, url, text, content_hash, timestamps, `gone_at`. One row per
document id, so an edit overwrites the row and there is no revision history to
attribute. `course_fact_extractions` (course_facts.sql:60-88) has no user
column either; the migration header states this on purpose ("no user id
anywhere ... which student's upload happened to trigger an extraction is
deliberately not recorded", :8-15), and so do PROTOCOL.md (~:940) and PRIVACY.md
(the facts paragraph near :180-190, "say nothing about you"). The only table
where a user id meets a course id is `enrollments`. So "which user caused this
extraction" cannot be answered by any current table.

**Extraction is pooled, so a per-user cap is really a cap on triggering.**
One extraction serves every classmate, and the model call is paid once per
revision whoever asked. A per-user limit on "my extractions" is a fiction;
what can be limited is how many extractions a person may set off, or how many
document revisions they may upload.

**Triggering is decoupled from the document batch.** A run takes the newest 10
pending documents of the courses named (`factsExtraction.ts:546`, :429-432),
and those may be documents someone else uploaded. Whoever calls
`extract-facts` makes the server work through the pool's backlog, so the
caller of `runPendingFactExtractions` and the uploader of the revision are
two different people. This matters for Option B below.

**What is promised today.** The only per-user rows the backend keeps are
anonymous-account rows, `enrollments`, and per-user daily request counts and
token totals for `ask` (`ask_usage`, via `reserve_ask_usage`,
`20261027100000_reserve_ask_usage.sql:43`, `quota.ts:466`). PRIVACY.md and
PROTOCOL.md both say facts carry no user id and that the triggering student
is not recorded. Any new per-user row for facts reverses that sentence, and
per this repo's rule PRIVACY.md changes in the same commit as the behaviour.

## 3. Options

### A. Per-user monthly trigger cap, in its own table

Delta (sketch, not a migration):

```sql
create table public.fact_trigger_budget (
  user_id   uuid not null references auth.users (id) on delete cascade,
  month     date not null,           -- first day, UTC
  triggers  integer not null default 0,
  primary key (user_id, month)
);
create function public.reserve_fact_trigger(p_user_id uuid, p_monthly_limit integer)
  returns boolean ...;   -- insert .. on conflict do update .. where triggers < limit
```

Where: a new RPC, `reserve_fact_trigger`, called by `extract-facts` before
`runPendingFactExtractions` (index.ts:63), and by `sync` before
`scheduleFactExtraction` (:457). Same shape as `reserve_ask_usage`: the
per-user counter is the atomic part.

Counts: calls that would start a run (a trigger), not extractions. One
trigger can start up to 10 extractions, so the monthly number must be read as
"runs", e.g. 100 runs, not as a spend figure.

Failure mode: fail open, like `quota.ts:473` does for ask. The meter is a
guard on a non-essential enrichment; a broken meter must not stop classmates
from getting facts. Cost of failing open: the status quo returns during an
outage of the counter.

Cannot stop: a client that makes a new anonymous account (one POST, no
email) gets a new `user_id` and a fresh allowance. It also cannot see which
trigger was junk: it limits runs, and a run that finds nothing pending is
free yet counts. Mitigation: only count a trigger when at least one document
was actually claimed, which means the RPC is called after the run and is
settled, not reserved; that loses atomicity (overshoot by in-flight calls,
which the migrations already accept for monthly caps).

PRIVACY.md must say: a per-account monthly counter of how many times the app
asked the server to read course posts, no course ids, deleted with the
account. New row, new sentence, but it is count-only like `ask_usage`.

Cost of being wrong: low. A too-tight limit makes a heavy user's manual
refresh a no-op until the 1st while `sync` still works (if sync is not
gated); a too-loose one leaves today's behaviour.

### B. Attribute each extraction to the uploader

Delta:

```sql
alter table public.course_fact_extractions add column requested_by uuid;  -- nullable, no FK cascade? see below
-- claim_fact_extraction gets: p_requested_by uuid default null,
--   p_user_monthly_limit integer default 300
-- and sums charged extractions: count(*) from course_fact_extractions
--   where requested_by = p_requested_by and updated_at >= month start
--   and status in ('running','done','failed')
```

Where: inside `claim_fact_extraction` (course_facts.sql:174), next to the
other three caps, so it shares the atomic claim. `sync` has to set
`requested_by` when it creates the pending row; today the row is only
created inside the claim (:198-200), not at upload, so either sync inserts
pending rows itself or the run passes the uploader's id down through
`FactsStore.claim` (`factsExtraction.ts:615-625`) as a new argument.

Counts: charged extractions per uploader. This is the closest to what the
cap is for, a spend limit on whoever created the revisions.

Failure mode: closed for the single user who is over the cap (their own
revisions become `skipped_budget`), open for everyone else, because the check
is a read inside the same function that already runs on every claim. If the
function itself errors, the existing behaviour holds (throws, the run ends
quietly, `factsExtraction.ts:626`).

Cannot stop: a new anonymous account again; and revisions uploaded by user
X but triggered by user Y: only the uploader is charged, so a script that
uploads junk then asks a second account to trigger does not help the
attacker, but it also means `extract-facts` callers are not limited at all.
It does nothing for a document whose revision was written by a legacy
client that has no attribution (`requested_by` null is uncapped).

PRIVACY.md must say the opposite of what it says now: each extraction row
records which anonymous account's upload caused it. This is the heaviest
change. It links a user id to a course id and a document id (and so, by
join with `course_documents.text`, to what that student pooled), which
`enrollments` alone already does at course granularity but not at document
granularity. That is the main reason to prefer something else.

Cost of being wrong: highest. The column cannot be un-recorded once rows
exist, and the migration comment (:8-15) was written to avoid exactly this.
A wrong limit is fixable; the attribution is not.

### C. Rate-limit uploads in `sync`, leave the facts tables alone

Delta: none to the facts tables. A counter of document revisions per user
per day, either a new tiny table like A's, or reusing a column in an
existing per-user daily row. `sync` refuses (or silently skips scheduling)
once a user's changed-document count for the day passes N. The natural place
is `sync/index.ts` around the before/after hash comparison (:372, :412) that
already knows how many documents changed.

Counts: uploaded revisions that changed a hash. Not extractions, not runs.
That is the most direct lever on the thing that causes spend, since an
extraction is only ever created by a changed hash.

Failure mode: fail open. If the counter errors, upload and sync proceed.

Cannot stop: `extract-facts` retries and backlog draining, since those cost
nothing in uploads; a new account; and an attacker staying below N per day on
many accounts. It also cannot tell junk edits from real ones, so a student
syncing a big course for the first time (hundreds of documents, up to 200 per
call, `sync/index.ts:74`) is the legitimate peak and must not be blocked by
the number chosen. Throttling `sync` also risks the ledger-adjacent promise
that a student's material is pooled promptly.

PRIVACY.md must say: a per-account daily count of document revisions
uploaded. Smaller than B, comparable to A.

Cost of being wrong: medium. Too tight and a first sync of a big course
stops pooling, which is the product's headline feature; the fix is a number
change, not a schema change.

## 4. Recommendation

Do A, counted after the fact on runs that actually claimed at least one
extraction, with a generous limit, fail open. Reasoning:

- It reuses a pattern the owners already accepted for `ask`
  (`reserve_ask_usage`, `ask_usage`): a per-account count with no course id
  and no content. It does not touch the sentence that matters most in this
  area, that no student is tied to a specific document or fact.
- B answers the question best and costs the one thing hard to take back.
  Do not do it unless the denial of service actually happens; the damage on
  the numbers above is a few dollars and a month of stale facts, both
  recoverable by raising `FACTS_MONTHLY_GLOBAL_LIMIT` or deleting rows.
- C protects the right resource but can break the first sync, so its limit
  would have to be set high enough to be useless against anything but the
  clumsiest loop.
- The wrong fix: lowering `FACTS_COURSE_MONTHLY_LIMIT` or the global number.
  That throttles every honest course to protect against one account, and it
  does nothing against many courses.
- The wrong fix, second kind: adding a cap and calling it done while account
  creation is free. All three options are bypassed by a new anonymous
  account; none of them is a security control. The thing they buy is
  protection against accidents and unsophisticated loops. Say so in the
  PROTOCOL.md Limitations when this lands.

Decisions the owners must make:

1. The number. Suggest 120 counted triggers per account per month for A
   (about 4 a day), against a normal student's handful per week, so an
   honest user is never near it and the loop case stops at ~1200 extractions
   (about 0.80 USD).
2. The window. Calendar month, UTC, to match every other cap here; a daily
   window would hurt the first-sync backlog spread.
3. Fail open or closed. Recommended: open, matching `quota.ts:473`.
4. Whether `sync` is gated too. Recommended: gate only the model spend
   (skip scheduling), never the upload, so pooling is unaffected.
5. Whether a per-user count row is acceptable under PRIVACY.md. If the
   answer is no, only a global solution remains (raise the alarm, not the
   wall), and the item stays parked.

## 5. Open questions and the test

- Are enrollments per user bounded, and can a manifest call create a course
  row for an id nobody holds? This changes how bad the N-courses walk is.
- Should `extract-facts` with `courseId` count differently from the
  all-courses form (index.ts:54-61)?
- Does a `skipped_budget` row from the new cap get picked up on the next
  UTC month, as the others are? It should, by the `needsExtraction` rule
  (`factsExtraction.ts:228`: skipped_budget counts as pending).

Verifying test, in the style of `backend/scripts/sql-check.sh` and
`claim_fact_extraction.test.sql` (describe only): in a rolled-back
transaction, make two users; call the new reserve function 120 times for user
one and assert all true, the 121st false and the counter at 120; assert user
two is still allowed; set the clock (or write `month` explicitly) to the next
month and assert user one is allowed again; assert `anon` and `authenticated`
cannot execute the function (`has_function_privilege`) and cannot select the
table; assert deleting the user cascades the row away. For the fail-open
promise, a Deno test with the RPC stubbed to error must show
`handleExtractFacts` still reaching `runPendingFactExtractions`. For the
accuracy of the count, a Deno test with a stubbed run that claims zero must
show the counter unchanged.
