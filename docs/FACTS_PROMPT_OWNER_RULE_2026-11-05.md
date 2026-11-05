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
model wrongly says is not in the index, and Worksheet 3.1's second problem
made optional). The two unwanted tasks are gone. Three identical notes
(seq 17-19) target the three MT1 redemption items from one announcement,
which is the "at most one note per target per document" rule working as
written; whether the phone should collapse them is a UI question.
