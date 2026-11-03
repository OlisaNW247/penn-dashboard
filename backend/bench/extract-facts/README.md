# extract-facts bench (Phase 0)

A labelled bench for the "facts" extractor in `docs/DAY_PLANNER_RESEARCH_2026-11-03.md`
(Parts 2.1, 5, 7). It runs course documents through candidate models on
OpenRouter with the strict `json_schema` request the shipped function will use,
parses with `_shared/facts.ts`, and scores against hand labels. Choose the
extraction model on precision first, not on public benchmarks.

## Commands

Run from the repo root. Results land in `backend/bench/extract-facts/results/`.

```bash
# 1. Run (needs OPENROUTER_API_KEY). --dry-run writes results/<tag>.requests.jsonl, no network.
deno run --allow-net --allow-read --allow-write --allow-env backend/bench/extract-facts/run.ts \
  --corpus backend/bench/extract-facts/corpus --tag first --model openai/gpt-6-luna --model anthropic/claude-haiku-5.5 \
  [--limit N] [--concurrency 4] [--dry-run] [--temperature 0] [--max-tokens 1500]

# 2. Re-score a saved results file after re-labelling or changing matching rules (no model calls)
deno run --allow-read --allow-write backend/bench/extract-facts/score.ts --results backend/bench/extract-facts/results/first.jsonl

# 3. Copy a paired iPhone's course-knowledge JSON (DEBUG build only; read-only on the phone),
#    then turn it into unlabelled corpus files under corpus/phone/<label>/ (never committed)
sh backend/bench/extract-facts/pull-from-phone.sh <CoreDevice id> marco
deno run --allow-read --allow-write backend/bench/extract-facts/knowledge-to-corpus.ts \
  --knowledge course-knowledge.json --out backend/bench/extract-facts/corpus/phone [--now <ISO>] [--timezone America/New_York]

# 4. Type-check
deno check backend/bench/extract-facts/*.ts
```

## Corpus format

One JSON file per document, any depth under the corpus directory. All
`FactsDocument` fields (`id, course, kind, title, postedAt?, text, index, meetings,
timezone, now`) plus `"source": "synthetic" | "phone"` and `"expected"`:
`null` (unlabelled, skipped and counted) or `{ "facts": ExpectedFact[] }` with

```
ExpectedFact = { type, target?, title_any?: string[], due_at?, due_tolerance?: "exact"|"day"|"any", kind?, note? }
```

`source` and `expected` are stripped before the prompt is built, so labels never leak.
A document that should yield nothing is labelled `{ "facts": [] }`, which is how
invention is measured.

## Labelling guide

Each predicted fact matches at most one label and vice versa. Dates are judged
separately: a right fact with a wrong date is `date_wrong`, not TP, and is not
also an FP and FN.

- **new_task**: a deliverable or event the document creates. Matched when any
  `title_any` string is a case-insensitive substring of the predicted title, so
  list short stems (`["problem set 4", "pset 4"]`). Example: "PS4 is due Friday
  11/6 at 5pm" -> `{type:"new_task", title_any:["ps4","problem set 4"], due_at:"2026-11-06T17:00:00-05:00"}`.
- **cancel**: an existing item is cancelled. Matched on type and `target` (the
  index `sourceID`). Example: "HW3 is cancelled" -> `{type:"cancel", target:"a-1203"}`.
  Label only cancellations the text states; a wrong cancel hides real work.
- **reschedule**: an existing item moves. Same match as cancel, plus the date
  check on the new `due_at`. Use `due_tolerance:"exact"` only when the text gives
  a clock time; leave the default `"day"` for "now due Monday". Example: "Quiz 2
  moved to Nov 12" -> `{type:"reschedule", target:"q-77", due_at:"2026-11-12"}`.
- **scope_change**: an existing item's content changes (drop question 3, extra
  credit added). Matched on type and `target`; leave `due_at` out so the date is
  not checked, or set `due_tolerance:"any"`.
- **note**: information attached to an existing item with no change to what or
  when (office-hours tip, submission format). Matched on type and `target`
  (`null` target means the label expects a null target).
- **needs_review**: the document clearly changes something but the model cannot
  safely say what (ambiguous target, contradictory dates). Matched on type, and
  on `target` only if the label names one. Label sparingly; it rewards flagging
  over guessing.

`due_at: null` in a label means "no date expected" and a predicted date counts
as wrong; omit `due_at` to skip the check; `due_tolerance:"any"` also skips it.
Day comparison uses the document's `timezone`; a bare date label is that day.

## Ship gates (Part 7)

Per model, both must hold on the labelled set:

1. `FP(new_task) + invented == 0` (`invented` = facts `parseFacts` rejected for `quote_not_in_text`).
2. `FP(cancel) == 0`.

Also reported: per-type precision/recall, `date_wrong`, bad targets
(`unknown_target`), parse failures, HTTP failures, latency mean/median/p95, mean
tokens, and estimated cost. The price table in `score.ts` is a placeholder:
re-check it on OpenRouter. A call that returns nothing scores its labelled facts
as misses, so an outage cannot pass.

## Privacy

Real-phone corpora (`corpus/phone/`) and all `results/` hold real course text and
model output. They are git-ignored and are never committed. Synthetic documents
under `corpus/synthetic/` are the only corpus that may be tracked.
