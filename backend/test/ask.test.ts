// Covers the pure, testable-without-Postgres-or-a-live-stream pieces of
// `ask`'s outcome telemetry and `ask-canary`'s probe overrides
// (20260922090000_ask_outcomes.sql; `_shared/outcomes.ts`,
// `_shared/probe.ts`). Nothing in `ask/index.ts` itself is imported here --
// every other test file in this directory tests `_shared/*` rather than a
// function's own `index.ts`, and that convention matters more than usual
// for `ask/index.ts` specifically: it calls `Deno.serve` at module load
// (guarded by `import.meta.main`, but still evaluated when imported), and
// there's nothing this suite needs from it that isn't already pulled out
// into `_shared/outcomes.ts` and `_shared/probe.ts`.
import { strict as assert } from "node:assert";
import { classifyStreamOutcome } from "../supabase/functions/_shared/outcomes.ts";
import { applyContextTrim, extractProbeOverrides, readProbeTag } from "../supabase/functions/_shared/probe.ts";

// ---------------------------------------------------------------------
// classifyStreamOutcome
// ---------------------------------------------------------------------

Deno.test("classifyStreamOutcome: any content chars is answered", () => {
  assert.equal(classifyStreamOutcome({ contentChars: 1, streamFailed: false }), "answered");
  assert.equal(classifyStreamOutcome({ contentChars: 500, streamFailed: false }), "answered");
});

Deno.test("classifyStreamOutcome: a clean stream with zero chars is empty (the 2026-09-14 shape)", () => {
  assert.equal(classifyStreamOutcome({ contentChars: 0, streamFailed: false }), "empty");
});

Deno.test("classifyStreamOutcome: a failed stream is upstream_error even if some content already went out", () => {
  assert.equal(classifyStreamOutcome({ contentChars: 40, streamFailed: true }), "upstream_error");
  assert.equal(classifyStreamOutcome({ contentChars: 0, streamFailed: true }), "upstream_error");
});

// ---------------------------------------------------------------------
// extractProbeOverrides
// ---------------------------------------------------------------------

Deno.test("extractProbeOverrides: returns undefined when overrides are not allowed, even if the body has one", () => {
  const body = { probe: { model: "some/other-model", maxTokens: 50 } };
  assert.equal(extractProbeOverrides(body, false), undefined);
});

Deno.test("extractProbeOverrides: returns undefined when allowed but the body has no probe field", () => {
  assert.equal(extractProbeOverrides({ question: "hi" }, true), undefined);
  assert.equal(extractProbeOverrides({}, true), undefined);
});

Deno.test("extractProbeOverrides: reads every field when allowed", () => {
  const body = {
    probe: {
      model: "some/other-model",
      maxTokens: 500,
      reasoning: { effort: "low" },
      temperature: 0.7,
      provider: { order: ["x"] },
      contextTrimChars: 1000,
    },
  };
  const overrides = extractProbeOverrides(body, true);
  assert.deepEqual(overrides, {
    model: "some/other-model",
    maxTokens: 500,
    reasoning: { effort: "low" },
    temperature: 0.7,
    provider: { order: ["x"] },
    contextTrimChars: 1000,
  });
});

Deno.test("extractProbeOverrides: drops malformed fields instead of failing the whole probe", () => {
  const body = {
    probe: {
      model: 12345, // wrong type -- dropped
      maxTokens: -5, // not positive -- dropped
      temperature: "warm", // wrong type -- dropped
      contextTrimChars: 1200, // valid -- kept
    },
  };
  const overrides = extractProbeOverrides(body, true);
  assert.deepEqual(overrides, { contextTrimChars: 1200 });
});

Deno.test("extractProbeOverrides: a non-object probe field yields undefined", () => {
  assert.equal(extractProbeOverrides({ probe: "not-an-object" }, true), undefined);
  assert.equal(extractProbeOverrides({ probe: null }, true), undefined);
});

// ---------------------------------------------------------------------
// applyContextTrim
// ---------------------------------------------------------------------

Deno.test("applyContextTrim: truncates to contextTrimChars", () => {
  assert.equal(applyContextTrim("the quick brown fox", 9), "the quick");
});

Deno.test("applyContextTrim: leaves the document unchanged when contextTrimChars is undefined", () => {
  assert.equal(applyContextTrim("the quick brown fox", undefined), "the quick brown fox");
});

Deno.test("applyContextTrim: a limit longer than the document is a no-op", () => {
  assert.equal(applyContextTrim("short", 9999), "short");
});

// ---------------------------------------------------------------------
// readProbeTag
// ---------------------------------------------------------------------

Deno.test("readProbeTag: reads a valid tag", () => {
  const req = new Request("https://example.test/ask", { headers: { "x-lhf-probe": "nightly-run-1" } });
  assert.equal(readProbeTag(req), "nightly-run-1");
});

Deno.test("readProbeTag: null when the header is absent", () => {
  const req = new Request("https://example.test/ask");
  assert.equal(readProbeTag(req), null);
});

Deno.test("readProbeTag: null for a tag over 40 characters or with disallowed characters", () => {
  const tooLong = new Request("https://example.test/ask", {
    headers: { "x-lhf-probe": "a".repeat(41) },
  });
  assert.equal(readProbeTag(tooLong), null);

  const badChars = new Request("https://example.test/ask", {
    headers: { "x-lhf-probe": "nightly run 1!" },
  });
  assert.equal(readProbeTag(badChars), null);
});
