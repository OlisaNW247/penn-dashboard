# extract-facts prompt: the owner's "clear action words" rule (2026-11-05)

Status: two drafts written and benched, neither deployed. The tree's
`backend/supabase/functions/_shared/facts.ts` is the deployed prompt, unchanged.

## The rule, verbatim

"the announcements put into your assignments are only those which have clear
action words that the AI looks at and discerns. This is an assignment that
needs to be here and needs to be submitted."

## What triggered it

The first production run on a PHYS 0151 course produced two `new_task` facts
the owner does not want on a to-do list:

- `new_task high | Final exam | quote "Final exam:"` (a bare title fragment).
- `new_task high | optional: Midterm 2 point redemption session in DRL A1 |
  quote "Midterm 2 point redemption on Thursday, November 5 at 5:15 p.m. in DRL A1."`
  (optional work, which the deployed prompt tells the model to emit as a
  new_task prefixed "optional").

## Drafts (in `docs/facts-prompt-drafts/`)

- `facts.deployed-2026-11-05.ts`: the prompt in production (HEAD).
- `facts.round1-ownerrule.ts`: new_task needs an explicit student-directed
  instruction with an action verb and a date; optional opportunities are never
  new_task (note on the indexed item, else no fact); the quote must contain
  the instruction, not a title fragment, else needs_review. Reconstructed from
  my own edits by swapping round 2's two paragraphs back for round 1's text;
  the reconstruction was not re-benched byte for byte, so treat it as
  equivalent, not proven identical.
- `facts.round2-ownerrule.ts`: the file exactly as benched in round 2. Rule 3
  accepts the item's own title line when it carries a verb and a date; rule 2
  gains the sentence that it only blocks creating a task, never cancel,
  reschedule, scope_change or note on an indexed item; a code comment flags
  the exam assumption.

## Bench (Haiku 5.5, 121 documents, single run per column)

Labels: `before` used the original labels; round 1 and round 2 used the three
relabels below (round 2 also relabelled ed-8443930; the first two columns did
not have that relabel, so `new_task` FN counts are not strictly comparable).

| | before (deployed) | round 1 | round 2 |
|---|---|---|---|
| Gate | FAIL (FP new_task 1) | PASS | FAIL (FP cancel 1) |
| Overall P / R | 79% / 87% | 82% / 78% | 70% / 78% |
| new_task TP/FP/FN (P / R) | 12/1/5 (92% / 71%) | 7/0/8 (100% / 47%) | 5/0/9 (100% / 36%) |
| cancel TP/FP/FN | 4/0/0 | 4/0/0 | 4/1/0 |
| reschedule TP/FP/FN | 18/1/1 | 16/0/3 | 16/1/3 |
| scope_change TP/FP/FN | 4/2/0 | 4/1/0 | 4/1/0 |
| note TP/FP/FN | 8/9/2 | 10/6/2 | 11/13/1 |
| needs_review TP/FP/FN | 6/1/0 | 6/3/0 | 6/4/0 |

Result files (gitignored): `backend/bench/extract-facts/results/{before,after,after2}-ownerrule.{jsonl,md}`.

### Changed outcomes, before -> round 1

- Better: ed:1949818:8303661 (scope_change FP + note FN -> note TP);
  ed:1949818:8447254 (needs_review FP + reschedule FN -> reschedule TP);
  ed:1947653:8211957, announcement:1949400:11298483, 11311145, 11388438,
  synthetic-03, -23, -30, -35 (extra note or reschedule FP -> none).
- As intended: ed-8456134 and 11395632 (optional new_task -> note on the indexed item).
- Worse: 11331706 (3 reschedule TP -> 3 FN + note FP on 15044540); the PHYS
  syllabus (final exam new_task TP -> needs_review, plus note and needs_review
  FPs); synthetic-18 (2 new_task TP -> 2 needs_review FP); ed:1949400:11347044
  (note TP -> FN); 11373672 (none -> note FP); ed:1947653:8397649 (extra note FP).

### Changed outcomes, before -> round 2

- Better: same as round 1 for 8303661, 8447254, 11388438, synthetic-23, -35;
  ed-8456134 and 11395632 as intended; ed-8443930 only by relabel.
- Worse: 11331706 (still 3 reschedule FN + note FP); PHYS syllabus (new_task
  FN, 3 note FPs, 1 needs_review FP); synthetic-18 (2 FN + 2 needs_review FP,
  unchanged by the rewrite); announcement:1948237:11303222 (new_task TP -> FN);
  announcement:1949400:11313868 (new_task TP -> FN + needs_review FP);
  synthetic-03 (cancel FP on c-7212, breaks the gate); synthetic-02, -28,
  11367332 (new note FPs); ed:1947653:8234356 (new reschedule FP).

## Root causes found

1. The real corpus's module lines are "<Name> (type). Due <date>" with no verb
   (synthetic-18: "Pipelining Worksheet (file). Due Tuesday, November 10 at
   1:45 PM"). The model reads the rule literally, calls these "no explicit
   instruction" and emits needs_review. My round 2 examples ("Submit ..., due
   Oct 3") did not match the real text, so the rewrite changed nothing there.
2. The optional rule bleeds into reschedules on indexed items. 11331706 dates
   undated indexed "MT1 Px Redemption" items; with the optional rule the model
   emits a note on Midterm 1 instead. The extra sentence added in round 2 did
   not fix it.
3. Possible run-to-run noise. Each column is one run. The round 2 cancel FP on
   synthetic-03 and the new note FPs on documents the edits do not target
   (synthetic-02, -28) look like drift, not prompt effect. Not confirmed; a
   repeat run of the same prompt would tell.

## Relabels (phone corpus, untracked; backup in `~/lhf-bench/relabels-2026-11-05/`)

Reason for all: owner rule 2026-11-04.

- cis-3990 ed-8456134: new_task -> note on indexed Project 1 (15013597). Optional never new_task.
- phys-0151 announcement-11395632: new_task -> note on indexed Midterm 2 (15044541). Optional never new_task.
- cis-3990 ed-8443930 (Salesforce, "please attend!"): new_task -> no fact. Attendance not stated as required.

Synthetic corpus: no changes (no optional-credit new_task labels there).
11331706 keeps its three reschedule labels; they were not changed.

## Assumption on exams

The owner has not excluded exams. Both drafts treat a required exam or quiz
with a stated date as a new_task of kind "event". If the owner wants exams off
the to-do list, that is a further change.

## Open question for the owner

Does "Due <date>" with no verb ("Pipelining Worksheet (file). Due Tuesday,
November 10") count as clear action words? If yes, rule 3 can accept a
module/syllabus line of that shape and should restore synthetic-18 and
probably the PHYS final exam. If no, the model's needs_review on those lines
is correct and recall stays low.

## Recommendation (two options, not chosen)

(a) Deploy round 1. Gate passes with zero false tasks (new_task P 100%,
cancel FP 0). Recall is 47%, and the misses are mostly module items, which
Phase 1's structured sources already bring to the dashboard without a model.
Known regressions: 11331706 reschedules, the PHYS syllabus final exam.

(b) Stay on the deployed prompt until a draft restores recall. It carries the
two false tasks the owner objected to and fails the gate on one FP, but keeps
71% new_task recall.

To deploy a chosen draft: copy it over
`backend/supabase/functions/_shared/facts.ts`, run
`cd backend && deno task test && deno task check`, then
`node backend/scripts/deploy-function.mjs extract-facts`, then
`node backend/scripts/deploy-facts.mjs --step 3`. Re-bench first if the draft
is changed or if round 1's reconstruction matters.

## Round 3 (2026-11-05)

Owner's answer to the open question: a line with a due date counts as clear
action words even with no verb. Round 3 is round 1 plus (1) rule 3 accepting a
module, syllabus or announcement line that names the work and states its due
date ("Pipelining Worksheet (file). Due Tuesday, November 10 at 1:45 PM",
"Final exam: Dec 15, 9am", "Quiz 2 for Chap. 22 on Friday"), the quote
containing that line with its date, while a bare title with no date and no
verb still goes to needs_review; (2) round 2's sentence that the optional rule
only blocks CREATING a task, never a cancel, reschedule, scope_change or note
on an indexed item; (3) a code comment recording the exam assumption as
confirmed by the owner on 2026-11-04. Draft:
`docs/facts-prompt-drafts/facts.round3-ownerrule.ts`. Labels unchanged (the
three relabels). Haiku, two runs, tags `after3a-ownerrule`, `after3b-ownerrule`.
Deno with round 3 in place: 686 passed, 0 failed; check clean. `facts.ts`
restored to HEAD afterwards.

| | before (deployed) | round 1 | after3a | after3b |
|---|---|---|---|---|
| Gate | FAIL (FP new_task 1) | PASS | PASS | PASS |
| Overall P / R | 79% / 87% | 82% / 78% | 82% / 86% | 79% / 78% |
| new_task TP/FP/FN (P / R) | 12/1/5 (92% / 71%) | 7/0/8 (100% / 47%) | 9/0/5 (100% / 64%) | 8/0/6 (100% / 57%) |
| cancel TP/FP/FN | 4/0/0 | 4/0/0 | 4/0/0 | 4/0/0 |
| reschedule TP/FP/FN | 18/1/1 | 16/0/3 | 19/1/0 | 14/0/5 |
| scope_change TP/FP/FN | 4/2/0 | 4/1/0 | 4/2/0 | 3/2/1 |
| note TP/FP/FN | 8/9/2 | 10/6/2 | 9/5/3 | 11/5/1 |
| needs_review TP/FP/FN | 6/1/0 | 6/3/0 | 6/3/0 | 6/5/0 |

Both runs pass the gate (new_task FP 0, cancel FP 0). new_task recall is 64%
(3a) and 57% (3b) against the 71% baseline: not fully back, closer than rounds
1 and 2. The baseline column used the original labels, so its FN counts are
not strictly comparable.

new_task FN, 3a: syllabus:1947653 (CIS 3990 presentations), 11298483,
11311145, syllabus:1949400 (PHYS final exam), synthetic-16. 3b adds
announcement 11313868. synthetic-18 is now recovered in both runs.

### after3a vs before (changed outcomes)

- Better: 8303661 (scope_change FP + note FN -> note TP); 8447254 (needs_review
  FP + reschedule FN -> reschedule TP); 11331706 reschedules restored (not in
  the diff: same as before); ed:1947653:8211957, 11298483, 11311145 and
  synthetic-23 (extra note/reschedule FP -> none); synthetic-18 stays TP.
- As intended: ed-8456134 and 11395632 (optional new_task -> note TP);
  ed-8443930 only by relabel.
- Worse: PHYS syllabus (final exam new_task TP + FP -> new_task FN +
  needs_review FP; the line is "Final exam Mon 12/14/26 6-8 PM ANNS 110 ..."
  and the model still flags it, probably because it is not in the index);
  11312118 (extra scope_change FP); 11315709 and 11347044 (note TP -> FN);
  8234356 (new reschedule FP); 8454505 (new needs_review FP); synthetic-03
  (note FP became needs_review FP on c-7212, not a cancel).

### 3a vs 3b (noise estimate)

Twelve documents differ between two runs of the same prompt: 8232363,
8447254, ed:1947653:8234356, 8454505, 11293273, 11313868, 11315709, 11331706,
11347044, 11373672, synthetic-03, synthetic-35. 11331706 alone flips between
3 reschedule TPs (3a) and 3 FNs (3b), and 11313868 flips new_task TP vs
needs_review. Overall recall moved 86% vs 78% on an unchanged prompt, so
differences of that size between rounds 1, 2 and 3 are partly noise; a single
run per round is not enough to rank them. Run each candidate three or more
times before choosing, and do not trust a per-document diff of one run.

## Deployed (2026-11-05 02:03 UTC)

Marco's answer to the open question: a line with a due date counts as clear
action words even with no verb. On that, and with his go, round 3
(`facts-prompt-drafts/facts.round3-ownerrule.ts`, now the content of
`_shared/facts.ts`) was deployed as `extract-facts` version 2 and `sync`
version 18. `sync` had to go too: it bundles the same prompt, because it
runs extraction in-process right after a phone uploads documents, and
without the redeploy uploads would have extracted under the old rule. Deno
686/0 and `deno task check` clean before the deploy;
`deploy-facts.mjs --step 3` green after it (the six stored facts and their
quotes unchanged, since documents are only re-read when their hash
changes). The two PHYS 0151 tasks extracted under the old prompt remain
stored until those documents revise or their rows are cleared by hand.

## PHYS 0151 re-extracted under round 3 (2026-11-05 02:10 UTC)

With Marco's "do whatever is necessary", the course's six old-rule facts and
ten extraction rows were deleted (`delete from course_facts / course_fact_extractions
where course_id = '1949400'`) and the course re-run in three hand-triggered
batches (10, 10, 7 documents): 27 extractions, all `done`, 0 rejected,
17 facts, $0.0178 in total. What came out: 1 `new_task` (the final exam,
Dec 14, medium confidence, quote still the bare "Final exam:" despite rule
3), 13 `note`s each targeting a real assignment (Midterm 2 x5, Midterm 1 x2,
Quiz 3, Quiz 4, Midterm 1 Upload, the three MT1 redemption items), and 3
`needs_review` (Quiz 5's September date, "Quiz 2 moved to Sep 23" which the
model says is not in the index, and Worksheet 3.1's second problem made
optional). The two unwanted tasks are gone. Three identical notes
(seq 17-19) target the three MT1 redemption items from one announcement,
which is the "at most one note per target per document" rule working as
written; whether the phone should collapse them is a UI question.

## "Quiz 2 is not in the item index" was true (checked 2026-11-05, 20:50 UTC)

Suspected as model error, since the server holds assignment `15120154`
"Quiz 2" for PHYS 0151. A read of the code found no cap or filter that
could drop it: `buildItemIndex` (`_shared/factsExtraction.ts`) takes every
live `assignment` row plus dated `module` rows, caps at 200 lines (dated
first), and filters only on `gone_at is null`. The row itself answers it:
`15120154` has `gone_at = 2026-09-11 20:19 UTC` (due `2026-09-21`), so
Canvas stopped listing that quiz in the feed ten days before it was due,
and the index excluded it as designed. The model reported the index it was
given accurately.

What this leaves open is a design choice, not a bug: should gone items stay
in the index so that a reschedule or cancel can still target them? The
phone's ledger keeps gone items flagged `isGoneFromFeed`, so such a fact
would have something to land on, but the announcement here was from
September, and a fact on a gone item would mostly describe work that is
over. Left as is; if gone items are ever included, the index line should
say `gone` so the model does not create a `new_task` for a vanished item.
The other two `needs_review` facts (Quiz 5 against a September document,
Worksheet 3.1) are the stale-document noise already noted above.

## Round 4: stale documents (2026-11-05)

**Problem.** On a first sync the function extracts months of old posts against
today's ITEM INDEX. PHYS 0151, 2026-11-05: a September post said "Quiz 5 on
capacitors will be on Sep 19th" while the index (Canvas, newer than the post)
shows Quiz 5 due Oct 19, and the model emitted needs_review "date conflicts";
a September post "Quiz 2 for Chap.22 is rescheduled to Sep 23" (Quiz 2 not
indexed, now November) produced a new_task for a date long past. Both should
be no fact. The bench could not see either: it rewinds the index per file and
the phone corpus sets `now` to the sync time while its labels assume post-time
extraction.

**The rule.** One prompt paragraph after the "names an indexed item and gives
or resolves a date" paragraph: a document posted more than 7 days before the
current date is older than the index, so a differing stated date for an indexed
item was superseded (no reschedule, no needs_review about that date); notes
about coverage, format, materials or location and a cancel on a still-indexed
item still apply; work dated before the current date is over (no new_task).
The wrong fix, recorded in the code comment: skipping old documents outright,
since a syllabus is old and still the only source of an unindexed final.

**The guards** (`parseFacts`, `facts.ts`; both counted in `rejectReasons`
generically, nothing else needed a change):
- `due_in_past`: a new_task whose `due_at` is before `doc.now`. Only a
  plausible date counts (within the existing 400-day skew); 1900 / 9999 /
  unparseable still go to the existing null-the-date path, which an existing
  test pins. A date-only `due_at` for today parses as UTC midnight and so reads
  as past; not handled.
- `stale_document`: a reschedule when `postedAt` parses and `now - postedAt >
  STALE_DOCUMENT_MS` (exported, 7 days). Undated documents untouched.
Tests: 6 added in `backend/test/facts.test.ts`.

**Bench.** New `--fresh` flag in `run.ts`: `now` = `postedAt` + 1 hour, same
offset, `"fresh": true` on each result line; documents without `postedAt`
(all Ed documents) keep their `now`. Corpus for the three table columns: the
phone corpus plus synthetic 01-36 (121 documents, the same set as Round 3; the
six new documents run separately, since `--fresh` would turn the stale ones
into fresh ones). Haiku 5.5, one run each, tags `round3-fresh` (HEAD prompt),
`round4a-stale`, `round4b-stale`. Deno: 699 passed, 0 failed; check clean.

| | round3-fresh | round4a | round4b | round4c |
|---|---|---|---|---|
| Gate | PASS | PASS | PASS | PASS |
| Overall P / R | 74% / 88% | 79% / 83% | 81% / 85% | 76% / 90% |
| new_task TP/FP/FN | 8/0/6 | 8/0/6 | 8/0/6 | 9/0/5 |
| cancel TP/FP/FN | 4/0/0 | 4/0/0 | 4/0/0 | 4/0/0 |
| reschedule TP/FP/FN | 19/2/0 | 16/1/3 | 17/1/2 | 19/1/0 |
| scope_change TP/FP/FN | 4/8/0 | 4/1/0 | 4/1/0 | 4/8/0 |
| note TP/FP/FN | 11/7/1 | 11/9/1 | 11/8/1 | 11/6/1 |
| needs_review TP/FP/FN | 6/1/0 | 6/2/0 | 6/2/0 | 6/2/0 |

**Six synthetic documents** (`corpus/synthetic/38-43`, tag
`round4-synthetic-stale`, no `--fresh`, now 2026-11-05 except 42): gate PASS,
overall P 100% / R 100%, 6 of 6 as labelled (after the 38 relabel below; rescored from the saved result, no new model call).
- 38 stale Quiz 5 conflict: one note on Quiz 5 ("covers sections 3.1 through 3.4"), no reschedule or needs_review. Relabelled from "no facts" to exactly one note on Quiz 5: coverage still applies under the rule. As expected.
- 39 HW4 cancel / HW5 superseded: cancel on HW4 only. As expected.
- 40 Midterm 1 note: one note on Midterm 1, no reschedule, no needs_review.
  As expected.
- 41 past unindexed Quiz 2: none. As expected.
- 42 fresh Lab 7 reschedule: reschedule to 2026-11-13T23:59-05:00. As expected.
- 43 old syllabus final: new_task "Take the final exam" 2026-12-14T18:00-05:00.
  As expected.

**Changed outcomes vs round3-fresh, and which hold.** Identical prompts
already differ by about twelve documents run to run (see 3a vs 3b). No
`stale_document` or `due_in_past` rejection appears in any `--fresh` run,
because `--fresh` makes nothing stale. A change is stable only if 4a, 4b and
4c all show it.

Stable across 4a / 4b / 4c:
- 11298483: note -> none (the `new_task` label is a miss either way).
- synthetic-23: none -> note FP.
- synthetic-35: extra note FP (on d-9312 in 4a/4b, d-9311 in 4c).

Stable in 4b and 4c only: 11313868 none -> `new_task` 2026-09-23 (a TP; 4a had
`needs_review`).

One-run noise (flips back or varies):
- ed:1949818:8209157: seven `scope_change` FPs vanish in 4a and 4b, return in
  4c (the 4c scope_change FP total, 8, is round3-fresh's).
- ed:1949818:8251419, ed:1949818:8447254, ed:1947653:8378902: reschedule or
  `new_task` TP lost in 4b only.
- 11331706 (three reschedule TPs): lost in 4a only.
- 11367332 note FP: absent in 4a only.
- 11373672: reschedule FP -> none, none, `needs_review` (4c).
- 11311145, syllabus:1947653, syllabus:1949400, ed:1947653:8211957,
  ed:1947653:8397649, synthetic-03, synthetic-28, synthetic-30, synthetic-36:
  an extra or missing note or `needs_review` in one run each.

**Fixes after round 4a/4b.** `due_in_past` compares calendar days in
`doc.timezone` (new `dayKey` helper in `facts.ts`), not instants, so work due
later today and a date-only `due_at` for today are kept; only a due day
strictly before today's is rejected (3 tests: 23:59 today kept, date-only
today kept, yesterday rejected). Synthetic 38 was relabelled to expect one note
on Quiz 5. Round 4c ran on the corrected `facts.ts`; Deno 702 passed, check
clean.

Reading: the stale paragraph does not move the headline numbers outside
run-to-run noise: reschedule recall is back to 100% in 4c, so the 4a/4b dip was
noise, not the paragraph. The stable effects are small (synthetic-23 and -35
gain a note FP, 11298483 loses a note). Total spend for the five bench runs:
about $0.27 (estimated by `score.ts`).

The six stale cases were re-run once more against the corrected prompt and
validator (tag `round4-synthetic-stale2`, $0.0032): 6 of 6 documents as
labelled, 5 facts, 0 FP, 0 FN. Round 4 is committed on `v10` and NOT
deployed; deploying it means `extract-facts` and `sync` both, since `sync`
bundles `_shared/facts.ts`, and needs a person's go.
