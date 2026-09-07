import { strict as assert } from "node:assert";
import { chatCompletionJSON, chatCompletionStream, UpstreamError } from "../supabase/functions/_shared/openrouter.ts";

/** Builds a fake `fetch` that returns pre-scripted responses in order, one
 *  per call, and records every request it was given so a test can assert
 *  on headers/body/model without any real network I/O. */
function scriptedFetch(responses: Response[]): { fetchImpl: typeof fetch; calls: Request[] } {
  const calls: Request[] = [];
  let index = 0;
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push(new Request(input as string, init));
    const response = responses[index];
    index += 1;
    if (!response) throw new Error("scriptedFetch: no more responses queued");
    return response;
  }) as typeof fetch;
  return { fetchImpl, calls };
}

function sseResponse(body: string, status = 200): Response {
  return new Response(body, { status });
}

const BASE_STREAM_OPTIONS = {
  apiKey: "test-key",
  model: "z-ai/glm-5.3-flash",
  messages: [{ role: "user", content: "hi" }],
  maxTokens: 100,
};

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const item of iterable) out.push(item);
  return out;
}

Deno.test("chatCompletionStream yields delta events parsed from choices[0].delta.content", async () => {
  const sse = [
    `data: ${JSON.stringify({ choices: [{ delta: { content: "Hel" } }] })}`,
    `data: ${JSON.stringify({ choices: [{ delta: { content: "lo" } }] })}`,
    "data: [DONE]",
    "",
  ].join("\n\n");
  const { fetchImpl } = scriptedFetch([sseResponse(sse)]);

  const events = await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl }));
  const deltas = events.filter((e) => e.type === "delta");
  assert.deepEqual(deltas, [{ type: "delta", text: "Hel" }, { type: "delta", text: "lo" }]);
});

Deno.test("chatCompletionStream ignores comment lines starting with ':'", async () => {
  const sse = [
    ": OPENROUTER PROCESSING",
    `data: ${JSON.stringify({ choices: [{ delta: { content: "ok" } }] })}`,
    ": another keep-alive",
    "data: [DONE]",
    "",
  ].join("\n\n");
  const { fetchImpl } = scriptedFetch([sseResponse(sse)]);

  const events = await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl }));
  assert.deepEqual(events, [{ type: "delta", text: "ok" }, { type: "done" }]);
});

Deno.test("chatCompletionStream stops at data: [DONE] and yields a done event", async () => {
  const sse = [
    `data: ${JSON.stringify({ choices: [{ delta: { content: "x" } }] })}`,
    "data: [DONE]",
    // Anything after [DONE] must never be read.
    `data: ${JSON.stringify({ choices: [{ delta: { content: "should-not-appear" } }] })}`,
    "",
  ].join("\n\n");
  const { fetchImpl } = scriptedFetch([sseResponse(sse)]);

  const events = await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl }));
  assert.deepEqual(events, [{ type: "delta", text: "x" }, { type: "done" }]);
});

Deno.test("chatCompletionStream surfaces usage including cached_tokens", async () => {
  const sse = [
    `data: ${JSON.stringify({ choices: [{ delta: {} }], usage: { prompt_tokens: 100, completion_tokens: 20, prompt_tokens_details: { cached_tokens: 40 } } })}`,
    "data: [DONE]",
    "",
  ].join("\n\n");
  const { fetchImpl } = scriptedFetch([sseResponse(sse)]);

  const events = await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl }));
  assert.deepEqual(events, [
    { type: "usage", promptTokens: 100, completionTokens: 20, cachedTokens: 40 },
    { type: "done" },
  ]);
});

Deno.test("chatCompletionStream falls back to fallbackModel on a 5xx from the primary model", async () => {
  const goodSSE = [
    `data: ${JSON.stringify({ choices: [{ delta: { content: "fallback-answer" } }] })}`,
    "data: [DONE]",
    "",
  ].join("\n\n");
  const { fetchImpl, calls } = scriptedFetch([
    new Response("server error", { status: 503 }),
    sseResponse(goodSSE),
  ]);

  const events = await collect(chatCompletionStream({
    ...BASE_STREAM_OPTIONS,
    fallbackModel: "openai/gpt-5.6-luna",
    fetchImpl,
  }));
  assert.deepEqual(events.filter((e) => e.type === "delta"), [{ type: "delta", text: "fallback-answer" }]);
  assert.equal(calls.length, 2);
  const secondBody = JSON.parse(await calls[1].clone().text());
  assert.equal(secondBody.model, "openai/gpt-5.6-luna");
});

Deno.test("chatCompletionStream does not retry a 4xx auth error even with a fallback configured", async () => {
  const { fetchImpl, calls } = scriptedFetch([new Response("unauthorized", { status: 401 })]);

  await assert.rejects(
    () => collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fallbackModel: "openai/gpt-5.6-luna", fetchImpl })),
    UpstreamError,
  );
  assert.equal(calls.length, 1);
});

Deno.test("chatCompletionStream throws UpstreamError with no fallback configured", async () => {
  const { fetchImpl } = scriptedFetch([new Response("server error", { status: 500 })]);
  await assert.rejects(
    () => collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl })),
    UpstreamError,
  );
});

Deno.test("chatCompletionStream retries once on a thrown network error and then succeeds", async () => {
  const sse = [`data: ${JSON.stringify({ choices: [{ delta: { content: "ok" } }] })}`, "data: [DONE]", ""].join("\n\n");
  let calls = 0;
  const fetchImpl = (async () => {
    calls += 1;
    if (calls === 1) throw new TypeError("network down");
    return sseResponse(sse);
  }) as typeof fetch;

  const events = await collect(chatCompletionStream({
    ...BASE_STREAM_OPTIONS,
    fallbackModel: "openai/gpt-5.6-luna",
    fetchImpl,
  }));
  assert.deepEqual(events.filter((e) => e.type === "delta"), [{ type: "delta", text: "ok" }]);
  assert.equal(calls, 2);
});

Deno.test("chatCompletionStream request body sets stream, usage.include, and provider.data_collection deny", async () => {
  const { fetchImpl, calls } = scriptedFetch([sseResponse("data: [DONE]\n\n")]);
  await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl }));
  const body = JSON.parse(await calls[0].clone().text());
  assert.equal(body.stream, true);
  assert.deepEqual(body.usage, { include: true });
  assert.equal(body.provider.data_collection, "deny");
  assert.equal(body.provider.allow_fallbacks, true);
  assert.equal(body.provider.order, undefined);
});

Deno.test("chatCompletionStream includes provider.order only when configured", async () => {
  const { fetchImpl, calls } = scriptedFetch([sseResponse("data: [DONE]\n\n")]);
  await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, provider: { order: ["a", "b"] }, fetchImpl }));
  const body = JSON.parse(await calls[0].clone().text());
  assert.deepEqual(body.provider.order, ["a", "b"]);
});

Deno.test("chatCompletionStream sets Authorization, HTTP-Referer and X-Title headers", async () => {
  const { fetchImpl, calls } = scriptedFetch([sseResponse("data: [DONE]\n\n")]);
  await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, apiKey: "sk-test", fetchImpl }));
  const headers = calls[0].headers;
  assert.equal(headers.get("authorization"), "Bearer sk-test");
  assert.equal(headers.get("http-referer"), "https://lhf.app");
  assert.equal(headers.get("x-title"), "Low Hanging Fruit");
});

Deno.test("chatCompletionJSON returns the assistant message content on success", async () => {
  const payload = { choices: [{ message: { content: '{"latePolicy":"none"}' } }] };
  const { fetchImpl, calls } = scriptedFetch([
    new Response(JSON.stringify(payload), { status: 200 }),
  ]);
  const text = await chatCompletionJSON({
    apiKey: "k",
    model: "z-ai/glm-5.3-flash",
    messages: [{ role: "user", content: "extract" }],
    maxTokens: 500,
    fetchImpl,
  });
  assert.equal(text, '{"latePolicy":"none"}');
  const body = JSON.parse(await calls[0].clone().text());
  assert.equal(body.stream, false);
  assert.deepEqual(body.response_format, { type: "json_object" });
});

Deno.test("chatCompletionJSON falls back on a 5xx and returns the fallback's content", async () => {
  const payload = { choices: [{ message: { content: "fallback-json" } }] };
  const { fetchImpl, calls } = scriptedFetch([
    new Response("bad gateway", { status: 502 }),
    new Response(JSON.stringify(payload), { status: 200 }),
  ]);
  const text = await chatCompletionJSON({
    apiKey: "k",
    model: "z-ai/glm-5.3-flash",
    fallbackModel: "openai/gpt-5.6-luna",
    messages: [{ role: "user", content: "extract" }],
    maxTokens: 500,
    fetchImpl,
  });
  assert.equal(text, "fallback-json");
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON throws UpstreamError when the response has no message content", async () => {
  const { fetchImpl } = scriptedFetch([new Response(JSON.stringify({ choices: [] }), { status: 200 })]);
  await assert.rejects(
    () => chatCompletionJSON({
      apiKey: "k",
      model: "m",
      messages: [{ role: "user", content: "x" }],
      maxTokens: 10,
      fetchImpl,
    }),
    UpstreamError,
  );
});
