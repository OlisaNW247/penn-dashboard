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

// An UpstreamError's message is logged and, for `ask`, stored in
// `ask_outcomes.detail`. A provider's refusal can quote the request back, and
// the request is a student's course material and question, so the message
// carries the status and the body's length and never its text (hardening
// BE-16). It used to carry the first 400 characters.
Deno.test("an UpstreamError carries the status and the body's length, never the body's text", async () => {
  const errorBody = JSON.stringify({
    error: { message: "context length exceeded near: SECRET-QUESTION about my grades in PHYS 0151" },
  });
  const { fetchImpl } = scriptedFetch([new Response(errorBody, { status: 400 })]);

  await assert.rejects(
    () => collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl })),
    (err: unknown) => {
      assert.ok(err instanceof UpstreamError);
      const message = (err as UpstreamError).message;
      assert.equal((err as UpstreamError).status, 400);
      assert.match(message, /400/);
      assert.match(message, new RegExp(`${errorBody.length} chars`));
      assert.doesNotMatch(message, /SECRET-QUESTION|context length|PHYS 0151/);
      return true;
    },
  );
});

Deno.test("the fallback request's UpstreamError also leaves the body out", async () => {
  const primaryBody = JSON.stringify({ error: { message: "PRIMARY-LEAK" } });
  const fallbackBody = JSON.stringify({ error: { message: "FALLBACK-LEAK" } });
  const { fetchImpl } = scriptedFetch([
    new Response(primaryBody, { status: 503 }),
    new Response(fallbackBody, { status: 502 }),
  ]);

  await assert.rejects(
    () => collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fallbackModel: "openai/gpt-5.6-luna", fetchImpl })),
    (err: unknown) => {
      assert.ok(err instanceof UpstreamError);
      const message = (err as UpstreamError).message;
      assert.equal((err as UpstreamError).status, 502);
      assert.match(message, /fallback responded 502/);
      assert.doesNotMatch(message, /LEAK/);
      return true;
    },
  );
});

Deno.test("an unreadable error body is reported as such, and the status still comes through", async () => {
  const broken = new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        controller.error(new Error("connection reset"));
      },
    }),
    { status: 500 },
  );
  const { fetchImpl } = scriptedFetch([broken]);
  await assert.rejects(
    () => collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl })),
    (err: unknown) => {
      assert.ok(err instanceof UpstreamError);
      assert.equal((err as UpstreamError).status, 500);
      assert.match((err as UpstreamError).message, /unreadable/);
      return true;
    },
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

Deno.test("chatCompletionStream sets reasoning.enabled false when asked (ask disables reasoning)", async () => {
  const { fetchImpl, calls } = scriptedFetch([sseResponse("data: [DONE]\n\n")]);
  await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, reasoning: { enabled: false }, fetchImpl }));
  const body = JSON.parse(await calls[0].clone().text());
  assert.deepEqual(body.reasoning, { enabled: false });
});

Deno.test("chatCompletionStream omits reasoning entirely when not configured", async () => {
  const { fetchImpl, calls } = scriptedFetch([sseResponse("data: [DONE]\n\n")]);
  await collect(chatCompletionStream({ ...BASE_STREAM_OPTIONS, fetchImpl }));
  const body = JSON.parse(await calls[0].clone().text());
  assert.equal(Object.prototype.hasOwnProperty.call(body, "reasoning"), false);
});

// This test used to pin `z-ai/glm-5.3-flash` to *no* reasoning field ("the
// JSON-mode extract functions never set it"). That was the 2026-10-23 bug:
// the thinking model spent `max_tokens` on hidden reasoning and answered with
// null content, which reached a phone as a 502. It now pins the half of the
// rule that still holds -- a model with no business receiving `reasoning`
// does not get one -- and the `z-ai/` half is asserted just below.
Deno.test("chatCompletionJSON's request body has no reasoning field for a model that is not z-ai", async () => {
  const payload = { choices: [{ message: { content: "{}" } }] };
  const { fetchImpl, calls } = scriptedFetch([new Response(JSON.stringify(payload), { status: 200 })]);
  await chatCompletionJSON({
    apiKey: "k",
    model: "openai/gpt-4.1-mini",
    messages: [{ role: "user", content: "extract" }],
    maxTokens: 500,
    fetchImpl,
  });
  const body = JSON.parse(await calls[0].clone().text());
  assert.equal(Object.prototype.hasOwnProperty.call(body, "reasoning"), false);
});

Deno.test("chatCompletionJSON sends reasoning effort low for a z-ai model", async () => {
  const payload = { choices: [{ message: { content: "{}" } }] };
  const { fetchImpl, calls } = scriptedFetch([new Response(JSON.stringify(payload), { status: 200 })]);
  await chatCompletionJSON({
    apiKey: "k",
    model: "z-ai/glm-5.3-flash",
    messages: [{ role: "user", content: "extract" }],
    maxTokens: 500,
    fetchImpl,
  });
  const body = JSON.parse(await calls[0].clone().text());
  assert.deepEqual(body.reasoning, { effort: "low" });
  // The rest of the JSON-mode body is untouched.
  assert.equal(body.stream, false);
  assert.deepEqual(body.response_format, { type: "json_object" });
  assert.equal(body.max_tokens, 500);
});

// ---------------------------------------------------------------------
// chatCompletionJSON: a 200 with no usable content falls back, once
// ---------------------------------------------------------------------

const JSON_BASE = {
  apiKey: "k",
  model: "z-ai/glm-5.3-flash",
  fallbackModel: "openai/gpt-5.6-luna",
  messages: [{ role: "user", content: "extract" }],
  maxTokens: 500,
};

function completion(content: unknown): Response {
  return new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
}

Deno.test("chatCompletionJSON tries the fallback when the primary answers 200 with an empty string", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(""), completion('{"ok":true}')]);
  const text = await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  assert.equal(text, '{"ok":true}');
  assert.equal(calls.length, 2);
  assert.equal(JSON.parse(await calls[0].clone().text()).model, "z-ai/glm-5.3-flash");
  assert.equal(JSON.parse(await calls[1].clone().text()).model, "openai/gpt-5.6-luna");
});

Deno.test("chatCompletionJSON tries the fallback when the primary's content is null (reasoning ate max_tokens)", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(null), completion('{"ok":true}')]);
  const text = await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  assert.equal(text, '{"ok":true}');
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON tries the fallback when the primary's content is whitespace only", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(" \n\t "), completion('{"ok":true}')]);
  const text = await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  assert.equal(text, '{"ok":true}');
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON tries the fallback when the primary has no choices at all", async () => {
  const { fetchImpl, calls } = scriptedFetch([
    new Response(JSON.stringify({ choices: [] }), { status: 200 }),
    completion('{"ok":true}'),
  ]);
  const text = await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  assert.equal(text, '{"ok":true}');
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON's empty-200 fallback body is built for the fallback model (no reasoning for a non-z-ai fallback)", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(null), completion('{"ok":true}')]);
  await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  const primaryBody = JSON.parse(await calls[0].clone().text());
  const fallbackBody = JSON.parse(await calls[1].clone().text());
  assert.deepEqual(primaryBody.reasoning, { effort: "low" });
  // The primary's reasoning must not ride along to a model that never
  // measured it -- the default pairing is exactly z-ai then non-z-ai.
  assert.equal(Object.prototype.hasOwnProperty.call(fallbackBody, "reasoning"), false);
  // Everything else about the request is the same one, re-aimed.
  assert.deepEqual(fallbackBody.messages, primaryBody.messages);
  assert.equal(fallbackBody.max_tokens, primaryBody.max_tokens);
  assert.deepEqual(fallbackBody.response_format, { type: "json_object" });
  assert.equal(fallbackBody.stream, false);
});

Deno.test("chatCompletionJSON gives a z-ai fallback its own reasoning effort when the primary is not z-ai", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(""), completion('{"ok":true}')]);
  await chatCompletionJSON({
    ...JSON_BASE,
    model: "openai/gpt-4.1-mini",
    fallbackModel: "z-ai/glm-5.3-flash",
    fetchImpl,
  });
  const primaryBody = JSON.parse(await calls[0].clone().text());
  const fallbackBody = JSON.parse(await calls[1].clone().text());
  assert.equal(Object.prototype.hasOwnProperty.call(primaryBody, "reasoning"), false);
  assert.deepEqual(fallbackBody.reasoning, { effort: "low" });
});

Deno.test("chatCompletionJSON's 5xx fallback body is also built for the fallback model", async () => {
  const { fetchImpl, calls } = scriptedFetch([new Response("bad gateway", { status: 502 }), completion('{"ok":true}')]);
  await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  const primaryBody = JSON.parse(await calls[0].clone().text());
  const fallbackBody = JSON.parse(await calls[1].clone().text());
  assert.deepEqual(primaryBody.reasoning, { effort: "low" });
  assert.equal(fallbackBody.model, "openai/gpt-5.6-luna");
  assert.equal(Object.prototype.hasOwnProperty.call(fallbackBody, "reasoning"), false);
});

Deno.test("chatCompletionJSON throws UpstreamError when the fallback is empty too, after exactly two calls", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(""), completion(null)]);
  await assert.rejects(() => chatCompletionJSON({ ...JSON_BASE, fetchImpl }), UpstreamError);
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON does not ask the fallback twice when it already answered an empty 200 after a 5xx", async () => {
  const { fetchImpl, calls } = scriptedFetch([new Response("bad gateway", { status: 502 }), completion("")]);
  await assert.rejects(() => chatCompletionJSON({ ...JSON_BASE, fetchImpl }), UpstreamError);
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON throws on an empty 200 when no fallback model is configured", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion("")]);
  await assert.rejects(
    () => chatCompletionJSON({ ...JSON_BASE, fallbackModel: undefined, fetchImpl }),
    UpstreamError,
  );
  assert.equal(calls.length, 1);
});

Deno.test("chatCompletionJSON surfaces the fallback's HTTP status when the empty-200 retry itself fails", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion(null), new Response("overloaded", { status: 503 })]);
  await assert.rejects(
    () => chatCompletionJSON({ ...JSON_BASE, fetchImpl }),
    (err: unknown) => {
      assert.ok(err instanceof UpstreamError);
      assert.equal((err as UpstreamError).status, 503);
      return true;
    },
  );
  assert.equal(calls.length, 2);
});

Deno.test("chatCompletionJSON makes a single call and returns the primary's content when it is usable", async () => {
  const { fetchImpl, calls } = scriptedFetch([completion('{"ok":true}')]);
  const text = await chatCompletionJSON({ ...JSON_BASE, fetchImpl });
  assert.equal(text, '{"ok":true}');
  assert.equal(calls.length, 1);
});

Deno.test("chatCompletionJSON still throws, without trying the fallback, when a 200 body is not JSON", async () => {
  const { fetchImpl, calls } = scriptedFetch([new Response("<html>gateway page</html>", { status: 200 })]);
  await assert.rejects(() => chatCompletionJSON({ ...JSON_BASE, fetchImpl }), UpstreamError);
  assert.equal(calls.length, 1);
});

Deno.test("chatCompletionJSON does not retry a 4xx with a fallback configured", async () => {
  const { fetchImpl, calls } = scriptedFetch([new Response("unauthorized", { status: 401 })]);
  await assert.rejects(() => chatCompletionJSON({ ...JSON_BASE, fetchImpl }), UpstreamError);
  assert.equal(calls.length, 1);
});

// Pins that the JSON path's per-model bodies did not leak into the streaming
// path `ask` uses: its fallback body is still the primary's with only `model`
// swapped, `reasoning` included.
Deno.test("chatCompletionStream's fallback body is still the primary body with only the model swapped", async () => {
  const goodSSE = [`data: ${JSON.stringify({ choices: [{ delta: { content: "x" } }] })}`, "data: [DONE]", ""].join("\n\n");
  const { fetchImpl, calls } = scriptedFetch([new Response("server error", { status: 503 }), sseResponse(goodSSE)]);
  await collect(chatCompletionStream({
    ...BASE_STREAM_OPTIONS,
    fallbackModel: "openai/gpt-5.6-luna",
    reasoning: { effort: "low" },
    fetchImpl,
  }));
  const primaryBody = JSON.parse(await calls[0].clone().text());
  const fallbackBody = JSON.parse(await calls[1].clone().text());
  assert.deepEqual(fallbackBody, { ...primaryBody, model: "openai/gpt-5.6-luna" });
  assert.deepEqual(fallbackBody.reasoning, { effort: "low" });
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
