# The extract-facts bench: Phase 0 result (2026-11-03)

Phase 0 of `docs/DAY_PLANNER_RESEARCH_2026-11-03.md` asked for a labelled
bench and a model chosen by measured precision, before any app or server
code. This is what it measured, in one day, on
`phase0/extract-facts-bench`. The harness is `backend/bench/extract-facts/`
(its README has the commands and the labelling guide); the prompt, schema
and parser it measured are `backend/supabase/functions/_shared/facts.ts`,
written as the Phase 2 Edge Function's pure core.

## The corpus

- **36 synthetic documents** (`corpus/synthetic/`, tracked): invented Penn
  courses, every edge case from the research addendum.
- **85 real documents off Marco's phone** (`corpus/phone/marco/`,
  untracked, backed up in `~/lhf-bench/`): 45 Ed threads, 22 Canvas
  announcements, 9 modules, 6 pages, 3 syllabi, over CIS 2620, CIS 3990,
  PHYS 0151, FNAR 0010 and TAP 2028. Hand-labelled; 36 expected facts
  and 55 "nothing changes" cases after two correction rounds. Zero real
  cancellations in the set, so the wrong-cancel gate rests on the
  synthetic cases until a real one appears.

## Two rounds

Round 1 ran the first prompt. Every model failed the gates on both sets.
Two independent reviews of the two front-runners' misses (61 for Haiku,
84 for gpt-6-luna) agreed: about 70% prompt gaps, a tenth label errors,
the rest model errors, and not one date arithmetic mistake. The prompt
was rewritten as rules (commit `b9d31ce`) and the labels corrected.

Round 2, the rewritten prompt, `reasoning: low`, max 4000 tokens,
temperature 0. Ship gates: no false new task and no invented quote, no
false cancel, no failed call.

| model | synthetic P/R | gates | real P/R | gates | real new_task P | real reschedule P/R | median latency | cost per real doc |
|---|---|---|---|---|---|---|---|---|
| **anthropic/claude-haiku-5.5** | 89% / 93% | PASS | **90% / 85%** | **PASS** | 100% | 100% / 100% | 1.2 s | $0.0004 |
| deepseek/deepseek-v4.1-flash | 84% / 96% | PASS | 85% / 85% | FAIL (2 false tasks, 3 parse failures) | | | 1.1 s | $0.0004 |
| openai/gpt-6.1-terra | 74% / 96% | FAIL | 61% / 85% | FAIL | | | 1.9 s | $0.0025 |
| openai/gpt-6-luna | 78% / 93% | PASS | 54% / 67% | FAIL (1 false cancel) | | | 1.4 s | $0.0003 |
| z-ai/glm-5.3-flash (today's extractor) | 74% / 93% | PASS | 52% / 70% | FAIL (3 invented quotes, 2 false cancels) | | | 0.9 s | $0.0001 |

Haiku's five remaining real misses are all missed new tasks (recall
55% on that type): a midterm announced in an Ed post, a presentation
slot in a syllabus, an attendance request, and the two "Quiz 3" posts
below. Nothing it emitted on the real set was a wrong task, date or
cancellation.

## Decision

**Claude Haiku 5.5 for `extract-facts`**, strict JSON schema, low
reasoning effort. It is the only model that passes the gates on real
documents, it is the cheapest of the passing candidates per document,
and at $0.0004 a document the pooled design's cost estimate stands.
`glm-5.3-flash`, which runs today's announcement extractor, invented
three quotes and two cancellations on the real set; the research's
suspicion about it was right. Whether `ask` should move to Haiku too is
a separate bench (the citation probe set).

## What the bench taught beyond the number

- A Canvas announcement can carry its whole fact in the title; the quote
  check covers title plus body.
- Ed's `updatedAt` is the last edit, not the post date; Phase 2 needs
  `posted_at` on the document.
- The pool's index is today's state. The live path runs at post time, so
  facts are extracted against the index as it was; the bench rewinds
  each file's index by hand.
- Canvas's "Quiz 3" is the instructor's "Quiz 2 for Chap. 22". No prompt
  can bridge that; the identity layer (research addendum C, item 1)
  merges by date proximity. The bench expects a new task there.
- `provider.require_parameters` on OpenRouter 404s every Haiku request;
  strict `json_schema` alone is honoured. Anthropic's schema mode rejects
  `null` inside an enum list; use `anyOf`.
- CIS 2620 has no `assignment` documents in the pool at all, and the
  phone's course-material sync reports `manifest failed · uploaded 0 ·
  errors 7` (Olisa's area, untouched).

## Left

- Marco's pass over the `LABELS-*.md` judgment calls (about 40), mainly
  coverage notes versus noise, optional dated events, recurring syllabus
  rules.
- A second phone's documents (Olisa), and the first real cancellation.
- Phase 1 (structured sources, no model) and the identity layer can
  start now; Phase 2 needs Olisa's go.
