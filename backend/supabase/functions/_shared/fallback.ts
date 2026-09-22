// Pure decision helpers behind `ask`'s two-model hedged race for a fast,
// non-empty answer -- split out of `ask/index.ts` for the same reason
// `_shared/outcomes.ts` and `_shared/probe.ts` already are: this directory's
// tests exercise `_shared/*`, not a function's own `index.ts` (see
// `ask.test.ts`'s header comment), and none of what's here needs a live
// stream or a Postgres connection to be worth testing on its own.
//
// Background, all measured live against the deployed function on
// 2026-09-22, is worth keeping next to the code because it's the reason the
// shape below is a *race*, not a sequential "try the fast one, then the
// slow one" or "try the slow one, then the fast one":
//
//   - `z-ai/glm-5.3-flash` (the original default model) with `reasoning`
//     left unset spends the whole output cap on hidden reasoning on a real
//     syllabus-sized prompt and answers with nothing -- the 2026-09-14
//     incident this file's sibling `_shared/outcomes.ts` exists to catch a
//     second time.
//   - The same model with `reasoning: { effort: "low" }` fixed the *amount*
//     of reasoning (about 6 tokens instead of ~300) but not the *tail*: 30
//     timed probes still saw 12 take over 8s to first delta and one take
//     66s, and several of the slow runs reported *zero* reasoning tokens --
//     meaning the slowness past that point is provider time-to-first-token,
//     not thinking, and no `reasoning` setting fixes a queueing delay on
//     OpenRouter's or the underlying provider's side. Waiting a fixed
//     timeout and *then* retrying elsewhere (the shape this file replaced
//     mid-build) just adds that timeout on top of the wait instead of
//     covering it.
//   - `openai/gpt-4.1-mini` was 10/10 between 1.9s and 3.0s to first delta,
//     correct about dates, with zero reasoning tokens (it isn't a thinking
//     model) -- fast enough on its own to be the primary rather than the
//     fallback.
//   - Cheaper models tried along the way (Gemini Flash/Flash-Lite,
//     `glm-4.5-air`, `deepseek-v3.1`) were fast but got a plain "what's due
//     tomorrow?" wrong -- ruled out on correctness, not latency, which is
//     why they aren't in the rotation at all rather than being a second
//     fallback tier.
//
// The owner's rule from those numbers is "never more than a 10 second
// wait": `openai/gpt-4.1-mini` is the primary with no `reasoning` field
// (it has no use for one), and if it hasn't produced a content delta by
// `HEDGE_AFTER_MS` this file's `shouldStartHedge` says to start
// `z-ai/glm-5.3-flash` (with low-effort reasoning, via `reasoningFor`)
// *concurrently* rather than waiting the primary out first -- whichever
// model answers first wins, and the loser is aborted. A primary that fails
// or empties outright, before the hedge would even fire, skips straight to
// the fallback alone (see `ask/index.ts`'s `runHedgedRace`), which is the
// one case this is still effectively sequential, not a race.

/** OpenRouter's unified reasoning control. Only ever handed to a model
 *  whose id starts with `"z-ai/"` (see `reasoningFor`) -- `openai/gpt-4.1-mini`
 *  is not a thinking model and has no `reasoning` field in its request body
 *  at all, which is also what keeps a non-`z-ai` fallback model (a canary
 *  overriding `probe.fallbackModel`) from getting a reasoning shape it was
 *  never measured against. */
export const DEFAULT_REASONING = { effort: "low" };

/**
 * OpenRouter's `reasoning` request field for `model`, or `undefined` when
 * the model has no business receiving one. Keyed on the `"z-ai/"` provider
 * prefix rather than a hardcoded model-id list, so swapping
 * `z-ai/glm-5.3-flash` for a sibling `z-ai` model (or pointing `LHF_MODEL`/
 * `LHF_FALLBACK_MODEL`/a canary's `probe.fallbackModel` at one) keeps
 * getting the measured low-effort setting without a code change here --
 * the actual cost of guessing wrong in either direction is small (an
 * unwanted `reasoning` field is rejected outright by a model that doesn't
 * support it, per the 2026-09-14 `{enabled:false}` 400; a missing one on a
 * thinking model just reverts to that model's own default reasoning
 * amount), so this stays a cheap heuristic rather than an exhaustive list
 * to maintain.
 */
export function reasoningFor(model: string): unknown {
  return model.startsWith("z-ai/") ? DEFAULT_REASONING : undefined;
}

export interface ShouldStartHedgeInput {
  /** When the eventual winner's first content delta arrived, in
   *  `Date.now()` terms -- `undefined` when no racer has produced one yet.
   *  Once this is set, the race is already decided and nothing should ever
   *  start a hedge after the fact, which is what makes this `false`
   *  unconditionally. */
  firstDeltaAt: number | undefined;
  now: number;
  startedAt: number;
  hedgeAfterMs: number;
}

/**
 * Whether `ask`'s hedge (see `ask/index.ts`'s `runHedgedRace`) should start
 * the fallback model *alongside* an already-running, still-silent primary,
 * rather than waiting for it to finish or fail first. `firstDeltaAt` being
 * set makes this always `false` -- the whole point of a hedge is to cover a
 * primary that hasn't said anything yet, and once *any* racer has produced
 * content the race is over (see the module doc comment on the loser being
 * aborted, never resurrected).
 */
export function shouldStartHedge(input: ShouldStartHedgeInput): boolean {
  if (input.firstDeltaAt !== undefined) return false;
  return input.now - input.startedAt >= input.hedgeAfterMs;
}

/**
 * How many milliseconds of `totalBudgetMs` are left as of `now`, floored at
 * zero -- never negative, so a caller can use this directly as a
 * `setTimeout` delay without an extra `Math.max` at every call site.
 * `ask/index.ts` uses this to bound the whole pre-stream race (primary and,
 * once hedged, fallback together) to one shared 45s ceiling rather than
 * giving each model its own full budget.
 */
export function remainingBudget(startedAt: number, now: number, totalBudgetMs: number): number {
  return Math.max(0, totalBudgetMs - (now - startedAt));
}

/**
 * The `ask_outcomes.detail` line for a request that only ever ran the
 * fallback model because the primary failed or emptied *before* the hedge
 * would have started it anyway (so there was never a race to describe) --
 * `reason` is `"empty"` or `"upstream_error"`, the same vocabulary
 * `AskOutcome` already uses. Kept well under 200 characters on any
 * reasonable input; `_shared/outcomes.ts`'s `recordOutcome` still caps it
 * again defensively, the same belt-and-braces posture it already takes
 * toward every other caller's `detail` string.
 */
export function outcomeDetailForFallback(primaryModel: string, reason: string): string {
  return `fallback from ${primaryModel} after ${reason}`;
}

/**
 * The `ask_outcomes.detail` line for a request the hedge actually raced --
 * the primary was still silent at `hedgeAfterMs`, the fallback started
 * alongside it, and `winnerModel` is whichever of the two produced the
 * first content delta (which may still be the primary; a hedge starting
 * doesn't mean the primary lost, only that it was slow enough to no longer
 * be racing alone).
 */
export function outcomeDetailForHedgeWin(hedgeAfterMs: number, winnerModel: string): string {
  return `hedged at ${hedgeAfterMs}ms; winner ${winnerModel}`;
}
