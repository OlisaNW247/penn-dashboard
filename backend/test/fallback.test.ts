// Covers `_shared/fallback.ts`'s pure decision helpers behind `ask`'s
// two-model hedged race (`ask/index.ts`'s `runHedgedRace`). Nothing here
// exercises the race itself -- that needs two live streams racing each
// other, which is exactly what the canary (`ask-canary`, with
// `probe.fallbackModel`/`probe.disableFallback`/`probe.hedgeAfterMs`) is
// for, not a unit test. See `ask.test.ts`'s header comment for why this
// directory's tests target `_shared/*` rather than a function's own
// `index.ts`.
import { strict as assert } from "node:assert";
import {
  DEFAULT_REASONING,
  outcomeDetailForFallback,
  outcomeDetailForHedgeWin,
  reasoningFor,
  remainingBudget,
  shouldStartHedge,
} from "../supabase/functions/_shared/fallback.ts";

// ---------------------------------------------------------------------
// reasoningFor
// ---------------------------------------------------------------------

Deno.test("reasoningFor: gives z-ai models the default low-effort reasoning shape", () => {
  assert.deepEqual(reasoningFor("z-ai/glm-5.3-flash"), DEFAULT_REASONING);
  assert.deepEqual(reasoningFor("z-ai/some-future-model"), DEFAULT_REASONING);
});

Deno.test("reasoningFor: gives every other model no reasoning field at all", () => {
  assert.equal(reasoningFor("openai/gpt-4.1-mini"), undefined);
  assert.equal(reasoningFor("google/gemini-flash"), undefined);
  assert.equal(reasoningFor("deepseek/deepseek-v3.1"), undefined);
});

// ---------------------------------------------------------------------
// shouldStartHedge
// ---------------------------------------------------------------------

Deno.test("shouldStartHedge: false once a first delta has already arrived, no matter the timing", () => {
  assert.equal(
    shouldStartHedge({ firstDeltaAt: 1_000, now: 999_999, startedAt: 0, hedgeAfterMs: 5_000 }),
    false,
  );
});

Deno.test("shouldStartHedge: false before hedgeAfterMs has elapsed with no content yet", () => {
  assert.equal(
    shouldStartHedge({ firstDeltaAt: undefined, now: 4_999, startedAt: 0, hedgeAfterMs: 5_000 }),
    false,
  );
});

Deno.test("shouldStartHedge: true once hedgeAfterMs has elapsed with no content yet", () => {
  assert.equal(
    shouldStartHedge({ firstDeltaAt: undefined, now: 5_000, startedAt: 0, hedgeAfterMs: 5_000 }),
    true,
  );
  assert.equal(
    shouldStartHedge({ firstDeltaAt: undefined, now: 9_000, startedAt: 3_000, hedgeAfterMs: 5_000 }),
    true,
  );
});

// ---------------------------------------------------------------------
// remainingBudget
// ---------------------------------------------------------------------

Deno.test("remainingBudget: the difference between total and elapsed", () => {
  assert.equal(remainingBudget(0, 10_000, 45_000), 35_000);
});

Deno.test("remainingBudget: floors at zero rather than going negative", () => {
  assert.equal(remainingBudget(0, 50_000, 45_000), 0);
  assert.equal(remainingBudget(0, 45_000, 45_000), 0);
});

// ---------------------------------------------------------------------
// outcomeDetailForFallback / outcomeDetailForHedgeWin
// ---------------------------------------------------------------------

Deno.test("outcomeDetailForFallback: names the primary model and the reason", () => {
  assert.equal(
    outcomeDetailForFallback("openai/gpt-4.1-mini", "upstream_error"),
    "fallback from openai/gpt-4.1-mini after upstream_error",
  );
  assert.equal(
    outcomeDetailForFallback("openai/gpt-4.1-mini", "empty"),
    "fallback from openai/gpt-4.1-mini after empty",
  );
});

Deno.test("outcomeDetailForHedgeWin: names the hedge delay and the winner", () => {
  assert.equal(
    outcomeDetailForHedgeWin(5_000, "z-ai/glm-5.3-flash"),
    "hedged at 5000ms; winner z-ai/glm-5.3-flash",
  );
});
