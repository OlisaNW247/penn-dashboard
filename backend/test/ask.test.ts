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
import {
  applyContextTrim,
  constantTimeEqual,
  extractProbeOverrides,
  gateCanary,
  PROBE_HEDGE_AFTER_MS_CEILING,
  PROBE_MAX_TOKENS_CEILING,
  PROBE_SECRET_HEADER,
  probePolicyFromEnv,
  ProbeRejectedError,
  readProbeTag,
} from "../supabase/functions/_shared/probe.ts";

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
  // Not even a value the policy would refuse: with overrides off the whole
  // `probe` field is inert, so production `ask` never 400s a stray one.
  const body = { probe: { model: "some/other-model", maxTokens: 50, provider: { sort: "price" } } };
  assert.equal(extractProbeOverrides(body, false), undefined);
});

Deno.test("extractProbeOverrides: returns undefined when allowed but the body has no probe field", () => {
  assert.equal(extractProbeOverrides({ question: "hi" }, true), undefined);
  assert.equal(extractProbeOverrides({}, true), undefined);
});

Deno.test("extractProbeOverrides: reads every field when allowed", () => {
  const body = {
    probe: {
      model: "openai/gpt-4.1-mini",
      maxTokens: 500,
      reasoning: { effort: "low" },
      temperature: 0.7,
      provider: { order: ["x"] },
      contextTrimChars: 1000,
      fallbackModel: "z-ai/glm-5.3-flash",
      disableFallback: true,
      hedgeAfterMs: 2500,
    },
  };
  const overrides = extractProbeOverrides(body, true);
  assert.deepEqual(overrides, {
    model: "openai/gpt-4.1-mini",
    maxTokens: 500,
    reasoning: { effort: "low" },
    temperature: 0.7,
    provider: { order: ["x"] },
    contextTrimChars: 1000,
    fallbackModel: "z-ai/glm-5.3-flash",
    disableFallback: true,
    hedgeAfterMs: 2500,
  });
});

Deno.test("extractProbeOverrides: drops malformed fallback/hedge fields", () => {
  const body = {
    probe: {
      fallbackModel: 12345, // wrong type -- dropped
      disableFallback: "yes", // wrong type -- dropped
      hedgeAfterMs: -1, // negative -- dropped
    },
  };
  assert.deepEqual(extractProbeOverrides(body, true), {});
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
// extractProbeOverrides: the policy (hardening BE-A)
//
// Before 2026-10-27 every one of these values was forwarded verbatim to
// OpenRouter on LHF's own key for any caller holding an anonymous JWT.
// ---------------------------------------------------------------------

function rejected(probe: Record<string, unknown>, field: string): void {
  assert.throws(
    () => extractProbeOverrides({ probe }, true),
    (err: unknown) => err instanceof ProbeRejectedError && err.message.startsWith(`probe.${field}`),
  );
}

Deno.test("extractProbeOverrides: a model off the allow-list is refused, not silently replaced", () => {
  rejected({ model: "anthropic/claude-opus-4" }, "model");
  rejected({ fallbackModel: "openai/o3-pro" }, "fallbackModel");
});

Deno.test("extractProbeOverrides: the refusal never echoes the refused value", () => {
  try {
    extractProbeOverrides({ probe: { model: "expensive/secret-model-name" } }, true);
    assert.fail("should have thrown");
  } catch (err) {
    assert.ok(err instanceof ProbeRejectedError);
    assert.ok(!err.message.includes("expensive/secret-model-name"));
  }
});

Deno.test("extractProbeOverrides: invalid/ ids pass, since they cannot run (the force-the-primary-to-fail probe)", () => {
  const overrides = extractProbeOverrides({ probe: { model: "invalid/model", disableFallback: false } }, true);
  assert.equal(overrides?.model, "invalid/model");
});

Deno.test("probePolicyFromEnv: the two production models, the configured ones, and LHF_PROBE_MODELS", () => {
  const env = new Map([
    ["LHF_MODEL", "acme/primary-1"],
    ["LHF_ASK_FALLBACK_MODEL", " acme/fallback-1 "],
    ["LHF_PROBE_MODELS", "cand/one, cand/two ,,"],
  ]);
  const policy = probePolicyFromEnv(env);
  for (const id of [
    "openai/gpt-4.1-mini",
    "z-ai/glm-5.3-flash",
    "acme/primary-1",
    "acme/fallback-1",
    "cand/one",
    "cand/two",
  ]) {
    assert.ok(policy.models.has(id), id);
  }
  assert.equal(policy.models.size, 6);
  assert.equal(
    extractProbeOverrides({ probe: { model: "cand/two" } }, true, policy)?.model,
    "cand/two",
  );
  rejected({ model: "cand/three" }, "model");
});

Deno.test("extractProbeOverrides: maxTokens, hedgeAfterMs and temperature are clamped, not passed through", () => {
  const overrides = extractProbeOverrides(
    { probe: { maxTokens: 1_000_000, hedgeAfterMs: 10 ** 9, temperature: 50 } },
    true,
  );
  assert.equal(overrides?.maxTokens, PROBE_MAX_TOKENS_CEILING);
  assert.equal(overrides?.hedgeAfterMs, PROBE_HEDGE_AFTER_MS_CEILING);
  assert.equal(overrides?.temperature, 2);
  assert.equal(extractProbeOverrides({ probe: { temperature: -3 } }, true)?.temperature, 0);
  // At or under the ceiling is untouched.
  assert.equal(extractProbeOverrides({ probe: { maxTokens: 3000 } }, true)?.maxTokens, 3000);
});

Deno.test("extractProbeOverrides: provider keeps only order, allow_fallbacks and data_collection deny", () => {
  const ok = extractProbeOverrides(
    { probe: { provider: { order: ["OpenAI", "Azure"], allow_fallbacks: false, data_collection: "deny" } } },
    true,
  );
  assert.deepEqual(ok?.provider, { order: ["OpenAI", "Azure"], allow_fallbacks: false, data_collection: "deny" });

  rejected({ provider: { data_collection: "allow" } }, "provider.data_collection");
  rejected({ provider: { sort: "price" } }, "provider");
  rejected({ provider: { max_price: { prompt: 100 } } }, "provider");
  rejected({ provider: { order: Array.from({ length: 9 }, () => "x") } }, "provider.order");
  rejected({ provider: { order: ["https://evil.example/"] } }, "provider.order");
  rejected({ provider: { allow_fallbacks: "yes" } }, "provider.allow_fallbacks");
  rejected({ provider: "OpenAI" }, "provider");
  rejected({ provider: [] }, "provider");
});

Deno.test("extractProbeOverrides: reasoning keeps effort, enabled and exclude, and refuses its own token budget", () => {
  assert.deepEqual(
    extractProbeOverrides({ probe: { reasoning: { effort: "high", exclude: true } } }, true)?.reasoning,
    { effort: "high", exclude: true },
  );
  assert.deepEqual(
    extractProbeOverrides({ probe: { reasoning: { enabled: false } } }, true)?.reasoning,
    { enabled: false },
  );
  // null sets no override (the request is served as if no reasoning had been sent), exactly as before.
  assert.equal(extractProbeOverrides({ probe: { reasoning: null } }, true)?.reasoning, undefined);
  rejected({ reasoning: { max_tokens: 500_000 } }, "reasoning");
  rejected({ reasoning: { effort: "extreme" } }, "reasoning.effort");
  rejected({ reasoning: "high" }, "reasoning");
});

// ---------------------------------------------------------------------
// gateCanary and constantTimeEqual
// ---------------------------------------------------------------------

function canaryRequest(headers: Record<string, string> = {}, method = "POST"): Request {
  return new Request("https://example.test/functions/v1/ask-canary", { method, headers });
}

async function runGate(req: Request, secret: string | undefined): Promise<{ res: Response; called: number }> {
  let called = 0;
  const res = await gateCanary(req, secret, () => {
    called += 1;
    return Promise.resolve(new Response("served", { status: 200 }));
  });
  return { res, called };
}

Deno.test("gateCanary: with LHF_PROBE_SECRET unset the function is closed to everyone, secret header or not", async () => {
  for (const secret of [undefined, ""]) {
    for (const headers of [{}, { [PROBE_SECRET_HEADER]: "" }, { [PROBE_SECRET_HEADER]: "anything" }] as Array<Record<string, string>>) {
      const { res, called } = await runGate(canaryRequest(headers), secret);
      assert.equal(res.status, 404);
      assert.equal(called, 0);
    }
  }
});

Deno.test("gateCanary: a missing or wrong secret is a 404 that never reaches the handler", async () => {
  const wrongHeaders: Array<Record<string, string>> = [
    {},
    { [PROBE_SECRET_HEADER]: "wrong" },
    { [PROBE_SECRET_HEADER]: "s3cret-extra" },
    { [PROBE_SECRET_HEADER]: "s3cre" },
  ];
  for (const headers of wrongHeaders) {
    const { res, called } = await runGate(canaryRequest(headers), "s3cret");
    assert.equal(res.status, 404);
    assert.equal(called, 0);
  }
  // Not even the CORS preflight is answered without the secret.
  const preflight = await runGate(canaryRequest({}, "OPTIONS"), "s3cret");
  assert.equal(preflight.res.status, 404);
  assert.equal(preflight.called, 0);
});

Deno.test("gateCanary: the 404 reads like an undeployed function and never mentions the secret", async () => {
  const { res } = await runGate(canaryRequest({ [PROBE_SECRET_HEADER]: "wrong" }), "s3cret");
  const text = await res.text();
  assert.deepEqual(JSON.parse(text), { code: "NOT_FOUND", message: "Requested function was not found" });
  assert.ok(!text.includes("s3cret"));
});

Deno.test("gateCanary: the right secret reaches the handler and returns its response", async () => {
  const { res, called } = await runGate(canaryRequest({ [PROBE_SECRET_HEADER]: "s3cret" }), "s3cret");
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "served");
  assert.equal(called, 1);
});

Deno.test("constantTimeEqual: equal, different, different-length and empty strings", async () => {
  assert.equal(await constantTimeEqual("abc", "abc"), true);
  assert.equal(await constantTimeEqual("abc", "abd"), false);
  assert.equal(await constantTimeEqual("abc", "abcd"), false);
  assert.equal(await constantTimeEqual("", "a"), false);
  assert.equal(await constantTimeEqual("", ""), true);
  assert.equal(await constantTimeEqual("é".repeat(100), "é".repeat(100)), true);
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
