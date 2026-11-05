// Covers the 2026-11-05 move of `ask`'s primary to Anthropic Haiku: the
// cache breakpoint (`prompt.ts` `withCacheBreakpoint`), the reasoning
// default and env override, and the hedge delay env. See CLAUDE.md -> ask:
// the model, the hedge, and the loop that tunes them.
import { strict as assert } from "node:assert";
import { buildMessages, SYSTEM_INSTRUCTIONS, withCacheBreakpoint } from "../supabase/functions/_shared/prompt.ts";
import { chatCompletionStream } from "../supabase/functions/_shared/openrouter.ts";
import {
  DEFAULT_HEDGE_AFTER_MS,
  DEFAULT_REASONING,
  hedgeAfterMsFromEnv,
  reasoningFor,
  reasoningFromEnv,
} from "../supabase/functions/_shared/fallback.ts";

const INPUT = {
  contextDocument: "CTX",
  catalog: [],
  profiles: { a: 1 },
  history: [{ role: "user" as const, content: "hi" }, { role: "assistant" as const, content: "hello" }],
  excerpts: "EXCERPTS",
  question: "Q?",
  askedAt: "2026-09-07T12:00:00.000Z",
};

async function bodyFor(model: string): Promise<string> {
  let captured = "";
  const fetchImpl = (async (_url: unknown, init: RequestInit) => {
    captured = init.body as string;
    return new Response("data: [DONE]\n\n", { status: 200 });
  }) as unknown as typeof fetch;
  try {
    for await (
      const _ of chatCompletionStream({
        fetchImpl,
        apiKey: "k",
        model,
        messages: withCacheBreakpoint(buildMessages(INPUT), model),
        maxTokens: 10,
        temperature: 0.2,
      })
    ) { /* drain */ }
  } catch { /* the body is all that matters */ }
  return captured;
}

// Built from the code as it stood before withCacheBreakpoint existed
// (2026-11-05), with the instructions text swapped for a placeholder.
const GOLDEN_OPENAI =
  '{"model":"openai/gpt-4.1-mini","messages":[{"role":"system","content":"__SYS__"},{"role":"system","content":"CTX"},{"role":"system","content":"COURSE PROFILES (extracted from syllabi):\\n{\\"a\\":1}"},{"role":"user","content":"hi"},{"role":"assistant","content":"hello"},{"role":"user","content":"Current date: 2026-09-07T12:00:00.000Z\\n\\nEXCERPTS\\n\\nQUESTION: Q?"}],"max_tokens":10,"stream":true,"provider":{"data_collection":"deny","allow_fallbacks":true},"temperature":0.2,"usage":{"include":true}}';

Deno.test("cache: a non-Anthropic model's request body is byte-identical to the pre-change golden", async () => {
  const golden = GOLDEN_OPENAI.replace("__SYS__", () => JSON.stringify(SYSTEM_INSTRUCTIONS).slice(1, -1));
  assert.equal(await bodyFor("openai/gpt-4.1-mini"), golden);
  // The fallback model gets the same plain messages.
  assert.equal(
    await bodyFor("z-ai/glm-5.3-flash"),
    golden.replace("openai/gpt-4.1-mini", "z-ai/glm-5.3-flash"),
  );
});

Deno.test("cache: an Anthropic model carries exactly one marker, on the last stable message", () => {
  const out = withCacheBreakpoint(buildMessages(INPUT), "anthropic/claude-haiku-5.5");
  const marked = out.flatMap((m, i) =>
    Array.isArray(m.content) && m.content.some((p) => p.cache_control !== undefined) ? [i] : []
  );
  assert.deepEqual(marked, [2], "the COURSE PROFILES message, the last system message");
  const m = out[2];
  assert.equal(m.role, "system");
  assert.deepEqual(m.content, [{
    type: "text",
    text: "COURSE PROFILES (extracted from syllabi):\n{\"a\":1}",
    cache_control: { type: "ephemeral" },
  }]);
  // Everything before is the plain stable text...
  assert.equal(out[0].content, SYSTEM_INSTRUCTIONS);
  assert.equal(out[1].content, "CTX");
  // ...and everything after the marker is per-turn: history, then date, excerpts, question.
  assert.deepEqual(out.slice(3).map((x) => x.content), [
    "hi",
    "hello",
    "Current date: 2026-09-07T12:00:00.000Z\n\nEXCERPTS\n\nQUESTION: Q?",
  ]);
  // The stable prefix holds no clock, excerpts, history or question.
  const stable = JSON.stringify(out.slice(1, 3)); // the instructions legitimately name EXCERPTS and QUESTION
  for (const volatile of ["Current date", "EXCERPTS", "QUESTION:", "hello", "2026-09-07"]) {
    assert.ok(!stable.includes(volatile), volatile);
  }
});

Deno.test("cache: the marker stays on the last system message when COURSE STRUCTURE is present", () => {
  const messages = buildMessages(INPUT);
  messages.splice(2, 0, { role: "system", content: "COURSE STRUCTURE (from the Penn registrar via Penn Labs):\nx" });
  const out = withCacheBreakpoint(messages, "anthropic/claude-haiku-5.5");
  const marked = out.flatMap((m, i) => Array.isArray(m.content) ? [i] : []);
  assert.deepEqual(marked, [3]);
});

Deno.test("cache: the marker reaches the wire body for Anthropic and not for others", async () => {
  const body = JSON.parse(await bodyFor("anthropic/claude-haiku-5.5"));
  assert.equal(JSON.stringify(body).split("cache_control").length - 1, 1);
  assert.equal(body.reasoning, undefined, "reasoning is the caller's job, not the body builder's");
});

Deno.test("reasoningFor: anthropic low, z-ai low, openai none", () => {
  assert.deepEqual(reasoningFor("anthropic/claude-haiku-5.5"), DEFAULT_REASONING);
  assert.deepEqual(reasoningFor("z-ai/glm-5.3-flash"), DEFAULT_REASONING);
  assert.equal(reasoningFor("openai/gpt-4.1-mini"), undefined);
});

Deno.test("reasoningFromEnv: a JSON object is used; unset is silent; the rest is ignored with one warning", () => {
  assert.deepEqual(reasoningFromEnv('{"effort":"medium"}'), { effort: "medium" });
  assert.equal(reasoningFromEnv(undefined), undefined);
  assert.equal(reasoningFromEnv(""), undefined);

  const warnings: unknown[][] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => {
    warnings.push(args);
  };
  try {
    for (const bad of ["{nope", "[1]", '"low"', "null", "7"]) {
      assert.equal(reasoningFromEnv(bad), undefined, bad);
    }
  } finally {
    console.warn = original;
  }
  assert.equal(warnings.length, 5, "one warning per bad value");
  assert.ok(warnings.every((w) => w.length === 1), "one argument, and never the value");
});

Deno.test("hedgeAfterMsFromEnv: integers from 1000 to 30000, else 5000", () => {
  const table: [string | undefined, number][] = [
    [undefined, 5000],
    ["8000", 8000],
    ["1000", 1000],
    ["30000", 30000],
    ["500", 5000],
    ["99999", 5000],
    ["abc", 5000],
    ["", 5000],
    ["8000.5", 5000],
    ["Infinity", 5000],
  ];
  for (const [raw, expected] of table) {
    assert.equal(hedgeAfterMsFromEnv(raw), expected, String(raw));
  }
  assert.equal(DEFAULT_HEDGE_AFTER_MS, 5000);
});
