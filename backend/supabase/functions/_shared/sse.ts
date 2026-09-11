// Encodes the three event shapes PROTOCOL.md's "ask" section defines into
// the wire format `EventSource`/plain SSE clients expect, and wraps that in
// a `Response` an Edge Function's `Deno.serve` handler can return directly.
//
// `corsHeaders` below is intentionally its own small object literal, not an
// import from `../_shared/http.ts` even though that module is documented to
// export a value of the same name. `http.ts` is another agent's file, being
// written in parallel, and this module's own tests must be able to run
// standalone against no more than what this file itself defines -- a test
// suite that can only pass once a *different* agent's unrelated module
// happens to exist and compile is a fragile, hidden coupling for a handful
// of static header strings. If the two ever need to be literally identical
// (a browser-based client would care; this backend's only client is the
// iOS/macOS app's `URLSession`, which does not enforce CORS at all), that is
// a one-line change to import from `http.ts` once both files are merged and
// can be checked together.
export const corsHeaders: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

/** The three event shapes `ask`'s response stream can emit, exactly as
 *  PROTOCOL.md specifies them. */
export type SSEEvent =
  | { type: "delta"; text: string }
  | {
    type: "done";
    usage: { promptTokens: number; completionTokens: number; cachedTokens: number };
  }
  | {
    type: "error";
    code: "quota_exceeded" | "upstream" | "bad_request";
    message: string;
  };

/** One `data: {...}\n\n` chunk, ready to hand to a `ReadableStream`
 *  controller or write directly to a socket. The blank line after the JSON
 *  is what terminates an SSE event per the spec -- a single `\n` only ends
 *  the `data:` field, not the event. */
export function encodeSSEEvent(event: SSEEvent): Uint8Array {
  return new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`);
}

/**
 * Drains `events` into a `text/event-stream` `Response`. The generator is
 * consumed lazily inside the `ReadableStream`'s `start`, so nothing about
 * calling this function forces the caller's async generator to run ahead of
 * the client actually reading -- important for `ask`, whose generator makes
 * the OpenRouter call and only starts producing `delta` events once that
 * call is underway.
 *
 * If `events` throws mid-iteration -- something this module's own callers
 * are expected to guard against by catching around their upstream call and
 * yielding an `{ type: "error" }` event themselves -- this still emits one
 * best-effort `error` event before closing, rather than leaving the HTTP
 * response truncated with no explanation. That is a safety net, not the
 * primary error path: `ask/index.ts` is what decides *when* an error is a
 * plain JSON response (nothing streamed yet) versus a mid-stream `error`
 * event, because only it knows whether any `delta` has gone out yet.
 */
export function streamResponse(events: AsyncIterable<SSEEvent>): Response {
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const event of events) {
          controller.enqueue(encodeSSEEvent(event));
        }
      } catch (_err) {
        controller.enqueue(encodeSSEEvent({
          type: "error",
          code: "upstream",
          message: "the stream ended unexpectedly",
        }));
      } finally {
        controller.close();
      }
    },
  });

  return new Response(body, {
    status: 200,
    headers: {
      ...corsHeaders,
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      "x-accel-buffering": "no",
    },
  });
}
