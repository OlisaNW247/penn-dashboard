import { strict as assert } from "node:assert";
import { corsHeaders, encodeSSEEvent, streamResponse, type SSEEvent } from "../supabase/functions/_shared/sse.ts";

Deno.test("encodeSSEEvent renders a delta event as one data: line terminated by a blank line", () => {
  const bytes = encodeSSEEvent({ type: "delta", text: "hello" });
  const text = new TextDecoder().decode(bytes);
  assert.equal(text, `data: ${JSON.stringify({ type: "delta", text: "hello" })}\n\n`);
});

Deno.test("encodeSSEEvent renders a done event with usage", () => {
  const event: SSEEvent = {
    type: "done",
    usage: { promptTokens: 10, completionTokens: 5, cachedTokens: 2 },
  };
  const text = new TextDecoder().decode(encodeSSEEvent(event));
  assert.equal(text, `data: ${JSON.stringify(event)}\n\n`);
  assert.ok(text.endsWith("\n\n"));
});

Deno.test("encodeSSEEvent renders an error event with its code and message", () => {
  const event: SSEEvent = { type: "error", code: "quota_exceeded", message: "over quota" };
  const text = new TextDecoder().decode(encodeSSEEvent(event));
  const parsed = JSON.parse(text.slice("data: ".length, -2));
  assert.deepEqual(parsed, event);
});

async function drain(response: Response): Promise<string> {
  const buf = await response.arrayBuffer();
  return new TextDecoder().decode(buf);
}

async function* eventsOf(...events: SSEEvent[]): AsyncGenerator<SSEEvent> {
  for (const event of events) yield event;
}

Deno.test("streamResponse sets text/event-stream and no-cache headers", () => {
  async function* empty() {}
  const response = streamResponse(empty());
  assert.equal(response.headers.get("content-type"), "text/event-stream");
  assert.equal(response.headers.get("cache-control"), "no-cache");
  assert.equal(response.headers.get("x-accel-buffering"), "no");
});

Deno.test("streamResponse includes CORS headers", () => {
  async function* empty() {}
  const response = streamResponse(empty());
  for (const [key, value] of Object.entries(corsHeaders)) {
    assert.equal(response.headers.get(key), value);
  }
});

Deno.test("streamResponse concatenates every yielded event in order", async () => {
  const response = streamResponse(eventsOf(
    { type: "delta", text: "a" },
    { type: "delta", text: "b" },
    { type: "done", usage: { promptTokens: 1, completionTokens: 1, cachedTokens: 0 } },
  ));
  const body = await drain(response);
  const expected = [
    `data: ${JSON.stringify({ type: "delta", text: "a" })}\n\n`,
    `data: ${JSON.stringify({ type: "delta", text: "b" })}\n\n`,
    `data: ${JSON.stringify({ type: "done", usage: { promptTokens: 1, completionTokens: 1, cachedTokens: 0 } })}\n\n`,
  ].join("");
  assert.equal(body, expected);
});

Deno.test("streamResponse emits a best-effort error event if the generator throws mid-stream", async () => {
  async function* throwing(): AsyncGenerator<SSEEvent> {
    yield { type: "delta", text: "partial" };
    throw new Error("boom");
  }
  const response = streamResponse(throwing());
  const body = await drain(response);
  assert.ok(body.startsWith(`data: ${JSON.stringify({ type: "delta", text: "partial" })}\n\n`));
  assert.ok(body.includes('"type":"error"'));
});

Deno.test("streamResponse produces an empty body for a generator that yields nothing", async () => {
  async function* empty(): AsyncGenerator<SSEEvent> {}
  const response = streamResponse(empty());
  const body = await drain(response);
  assert.equal(body, "");
});
