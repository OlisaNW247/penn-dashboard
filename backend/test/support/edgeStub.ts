// A stub for everything an Edge Function talks to over `fetch`: Supabase's
// auth and PostgREST on one side, OpenRouter on the other, plus the
// `reserve_ask_usage` / `settle_ask_usage` / `record_ask_outcome` RPCs. Shared
// by the handler-level tests (`askHandler.test.ts`,
// `extractAnnouncementHandler.test.ts`), which pin the order of events around
// the quota reservation. Not a test file itself (no `.test.` in the name), so
// `deno test test/` imports it without running it.
//
// The stub implements the atomic semantic the database provides: `reserve`
// decides, call by call, so a test can model "at most N reservations however
// many arrive at once". The atomicity itself is the SQL's
// (test/rls.test.sql); what these tests show is that a handler trusts the
// answer and does no unprotected read of its own.

export const USER_ID = "11111111-1111-1111-1111-111111111111";
const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_ANON_KEY: "anon-key",
  SUPABASE_SERVICE_ROLE_KEY: "service-key",
  OPENROUTER_API_KEY: "or-key",
};

export interface Stub {
  /** Every request, in the order it was made: "rpc:<name>", "openrouter", "auth", "rest:<table>". */
  log: string[];
  rpcParams: Array<{ fn: string; params: Record<string, unknown> }>;
  openrouterSignals: Array<{ abortedAtCall: boolean; signal: AbortSignal }>;
  restore(): void;
}

export type OpenRouterBehaviour =
  /** Streams `text`, then usage, then [DONE]. */
  | { kind: "answer"; text?: string; promptTokens?: number; completionTokens?: number }
  /** A non-streaming JSON completion whose message content is `content`. */
  | { kind: "json"; content: string; delayMs?: number }
  /** Streams one delta, then goes quiet until its request is aborted. */
  | { kind: "stall-after-first-delta" }
  /** Sends nothing until its request is aborted. */
  | { kind: "stall-before-first-byte" }
  | { kind: "fail"; status: number };

export interface StubRequest {
  method: string;
  url: URL;
  /** The request body as text ("" when there is none). */
  body: string;
  /** The request's abort signal, so a route can model a call that hangs until it is cancelled. */
  signal?: AbortSignal;
}

export interface StubOptions {
  /** First refusal on every non-OpenRouter request: return a Response to
   *  answer it, or `undefined` to fall through to the defaults below. How a
   *  test gives GoTrue's admin API or a table its own behaviour. */
  route?: (request: StubRequest) => Response | undefined | Promise<Response | undefined>;
  /** What `reserve_ask_usage` answers. A function is called once per reservation. */
  reserve: () => unknown;
  /** Non-200 status for `reserve_ask_usage`, to simulate a stalled or broken counter. */
  reserveStatus?: number;
  openrouter: OpenRouterBehaviour;
}

export const GRANTED = { allowed: true, reserved_day: "2026-10-27", today_requests: 1, month_requests: 1 };
export const DENIED = { allowed: false, reserved_day: "2026-10-27", today_requests: 40, month_requests: 40 };

export function sse(lines: string[]): string {
  return lines.map((line) => `data: ${line}\n\n`).join("");
}

export function installStub(options: StubOptions): Stub {
  const original = globalThis.fetch;
  const previousEnv = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(ENV)) {
    previousEnv.set(key, Deno.env.get(key));
    Deno.env.set(key, value);
  }
  const stub: Stub = {
    log: [],
    rpcParams: [],
    openrouterSignals: [],
    restore() {
      globalThis.fetch = original;
      for (const [key, value] of previousEnv) {
        if (value === undefined) Deno.env.delete(key);
        else Deno.env.set(key, value);
      }
    },
  };

  const json = (status: number, body: unknown) =>
    new Response(body === null ? null : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });

  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request ? input : undefined;
    const url = new URL(request ? request.url : String(input));
    const signal = init?.signal ?? request?.signal ?? undefined;

    if (url.hostname === "openrouter.ai") {
      stub.log.push("openrouter");
      stub.openrouterSignals.push({ abortedAtCall: signal?.aborted ?? false, signal: signal ?? new AbortController().signal });
      const behaviour = options.openrouter;
      if (signal?.aborted) throw new DOMException("aborted", "AbortError");
      if (behaviour.kind === "fail") return new Response("upstream is down", { status: behaviour.status });
      if (behaviour.kind === "json") {
        if (behaviour.delayMs) {
          // Slow to answer, but gives up if its request is aborted, as a real fetch does.
          await new Promise<void>((resolve, reject) => {
            const timer = setTimeout(resolve, behaviour.delayMs);
            signal?.addEventListener("abort", () => {
              clearTimeout(timer);
              reject(new DOMException("aborted", "AbortError"));
            }, { once: true });
          });
        }
        return new Response(JSON.stringify({ choices: [{ message: { content: behaviour.content } }] }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      const encoder = new TextEncoder();
      if (behaviour.kind === "answer") {
        const text = behaviour.text ?? "hello";
        return new Response(
          sse([
            JSON.stringify({ choices: [{ delta: { content: text } }] }),
            JSON.stringify({
              choices: [{ delta: {} }],
              usage: { prompt_tokens: behaviour.promptTokens ?? 100, completion_tokens: behaviour.completionTokens ?? 7 },
            }),
            "[DONE]",
          ]),
          { status: 200, headers: { "content-type": "text/event-stream" } },
        );
      }
      // Stalls: a body that ends in an error when (and only when) the request is aborted, as a real fetch's does.
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          if (behaviour.kind === "stall-after-first-delta") {
            controller.enqueue(encoder.encode(sse([JSON.stringify({ choices: [{ delta: { content: "partial" } }] })])));
          }
          signal?.addEventListener("abort", () => controller.error(new DOMException("aborted", "AbortError")), { once: true });
        },
      });
      if (behaviour.kind === "stall-before-first-byte") {
        return await new Promise<Response>((_resolve, reject) => {
          signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
        });
      }
      return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
    }

    if (options.route) {
      const body = request ? await request.clone().text() : String(init?.body ?? "");
      const answered = await options.route({ method: request?.method ?? init?.method ?? "GET", url, body, signal });
      if (answered) {
        stub.log.push(`route:${url.pathname}`);
        return answered;
      }
    }

    if (url.pathname === "/auth/v1/user") {
      stub.log.push("auth");
      return json(200, { id: USER_ID, aud: "authenticated", role: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-01-01T00:00:00Z" });
    }

    const rpc = /^\/rest\/v1\/rpc\/(.+)$/.exec(url.pathname);
    if (rpc) {
      const fn = rpc[1];
      stub.log.push(`rpc:${fn}`);
      const raw = request ? await request.text() : String(init?.body ?? "{}");
      stub.rpcParams.push({ fn, params: JSON.parse(raw || "{}") });
      if (fn === "reserve_ask_usage") {
        if (options.reserveStatus) return json(options.reserveStatus, { message: "Gateway Timeout" });
        return json(200, [options.reserve()]);
      }
      return new Response(null, { status: 204 });
    }

    if (url.pathname.startsWith("/rest/v1/")) {
      stub.log.push(`rest:${url.pathname.slice("/rest/v1/".length)}`);
      return json(200, []);
    }
    throw new Error(`unstubbed request: ${url}`);
  }) as typeof fetch;
  return stub;
}


export const tick = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms));
