// Small, boring HTTP helpers shared by every edge function in this
// project. Kept separate from auth.ts and manifest.ts so those two stay
// free of Response/Headers plumbing and are easier to unit test.

/** CORS is only relevant to callers made from a browser context; the iOS
 * app itself doesn't need it. It costs nothing to allow and saves whoever
 * eventually builds a web admin tool or a browser-based test harness from
 * rediscovering the same OPTIONS-preflight dance, so every function
 * answers OPTIONS with these headers up front. */
export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(status: number, body: unknown, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders, ...extraHeaders },
  });
}

export function errorResponse(code: string, message: string, status: number): Response {
  return json(status, { error: code, message });
}

/** A typed error carrying the HTTP status it should become, so a function
 * body can `throw new HttpError(...)` from deep inside a helper (auth.ts,
 * db.ts) and have `index.ts`'s single top-level catch turn it into the
 * right response, instead of every call site having to know how to build
 * a Response itself. */
export class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message?: string) {
    super(message ?? code);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

// Matches the protocol's "maximum request body 6 MB" cap on sync's upload
// step; enforced here so every function gets it for free rather than each
// one remembering to check.
const MAX_BODY_BYTES = 6 * 1024 * 1024;

/** Reads and JSON-parses a request body, rejecting anything over the 6 MB
 * cap before attempting to parse it (an oversized body is refused on size
 * alone, never on "JSON.parse ran out of memory" a few call frames later)
 * and rejecting anything that isn't valid JSON. Both failures are
 * `HttpError`s so callers don't need their own try/catch around this. */
export async function readJSON<T>(req: Request): Promise<T> {
  const contentLengthHeader = req.headers.get("content-length");
  if (contentLengthHeader && Number(contentLengthHeader) > MAX_BODY_BYTES) {
    throw new HttpError(413, "payload_too_large", `request body exceeds ${MAX_BODY_BYTES} bytes`);
  }

  const buffer = await req.arrayBuffer();
  if (buffer.byteLength > MAX_BODY_BYTES) {
    throw new HttpError(413, "payload_too_large", `request body exceeds ${MAX_BODY_BYTES} bytes`);
  }

  const text = new TextDecoder().decode(buffer);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new HttpError(400, "bad_request", "request body is not valid JSON");
  }
}
