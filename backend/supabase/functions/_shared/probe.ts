// Canary-only request overrides for `ask`'s streamed answer. `ask-canary`
// exists so a harness can try a different model, token cap, reasoning
// shape, provider order or trimmed context against the *exact same*
// prompt-building and streaming code production `ask` runs, rather than a
// parallel reimplementation that could quietly drift from what `ask`
// actually does -- a canary result is only worth anything if it predicts
// production. `ask/index.ts`'s exported `handleAsk` takes an
// `allowProbeOverrides` flag; production `ask` passes `false` and this
// module makes that the single place the decision is enforced, so a
// `probe` field in an ordinary request body is silently inert rather than
// rejected -- a client that happens to send one (or a future harness
// pointed at the wrong URL) doesn't get a 400 for it, per the brief this
// was built against.
//
// Field-level validation here is loose on purpose: this only ever reaches
// `ask-canary`, which is not customer-facing, so a malformed field is
// simply dropped (falls back to `ask`'s own default) rather than failing
// the whole request the way a real request body's fields are validated in
// `ask/index.ts`'s `parseAskRequestBody`.
export interface AskProbeOverrides {
  model?: string;
  maxTokens?: number;
  /** Forwarded verbatim as OpenRouter's `reasoning` request field --
   *  intentionally untyped past `unknown`, since the whole reason this
   *  exists is that the shape OpenRouter/the provider behind it actually
   *  accepts is not yet known (PROTOCOL.md's "ask" section, the
   *  2026-09-14 400 on `{ enabled: false }`). */
  reasoning?: unknown;
  temperature?: number;
  /** Forwarded verbatim as OpenRouter's `provider` request field, replacing
   *  (not merging with) the `data_collection`/`allow_fallbacks` object
   *  `ask` normally sends -- see `_shared/openrouter.ts`'s
   *  `providerOverride`. */
  provider?: unknown;
  contextTrimChars?: number;
}

/**
 * Reads `body.probe` when overrides are allowed for this call, otherwise
 * always returns `undefined` regardless of what the body contains -- the
 * one place that decides whether a `probe` field does anything, so
 * production `ask` and `ask-canary` share every other line of `handleAsk`.
 */
export function extractProbeOverrides(rawBody: unknown, allowed: boolean): AskProbeOverrides | undefined {
  if (!allowed) return undefined;
  if (typeof rawBody !== "object" || rawBody === null) return undefined;
  const probe = (rawBody as Record<string, unknown>).probe;
  if (typeof probe !== "object" || probe === null) return undefined;
  const p = probe as Record<string, unknown>;

  const overrides: AskProbeOverrides = {};
  if (typeof p.model === "string" && p.model.length > 0) {
    overrides.model = p.model;
  }
  if (typeof p.maxTokens === "number" && Number.isFinite(p.maxTokens) && p.maxTokens > 0) {
    overrides.maxTokens = Math.floor(p.maxTokens);
  }
  if (Object.prototype.hasOwnProperty.call(p, "reasoning")) {
    overrides.reasoning = p.reasoning;
  }
  if (typeof p.temperature === "number" && Number.isFinite(p.temperature)) {
    overrides.temperature = p.temperature;
  }
  if (Object.prototype.hasOwnProperty.call(p, "provider")) {
    overrides.provider = p.provider;
  }
  if (typeof p.contextTrimChars === "number" && Number.isFinite(p.contextTrimChars) && p.contextTrimChars >= 0) {
    overrides.contextTrimChars = Math.floor(p.contextTrimChars);
  }
  return overrides;
}

/** Truncates `contextDocument` to `contextTrimChars` characters when a
 *  canary probe requested it; returns it unchanged otherwise. Split out as
 *  its own pure function mainly so it's testable without going through
 *  `extractProbeOverrides`/`handleAsk` at all -- shrinking the context
 *  document is the one override that lets a harness reproduce the
 *  2026-09-14 "reasoning ate the whole cap" failure at a chosen prompt
 *  size without needing a real 14.5k-token syllabus fixture on hand. */
export function applyContextTrim(contextDocument: string, contextTrimChars: number | undefined): string {
  if (contextTrimChars === undefined) return contextDocument;
  return contextDocument.slice(0, contextTrimChars);
}

const PROBE_TAG_PATTERN = /^[A-Za-z0-9-]{1,40}$/;

/**
 * Reads the free-form `x-lhf-probe` tag any caller -- production `ask`
 * included, not just `ask-canary` -- may set to label an `ask_outcomes`
 * row as belonging to a specific harness run rather than a real student's
 * question. Independent of `allowProbeOverrides`: tagging a row doesn't
 * change how the request is served, only how its outcome row reads later,
 * so there's no reason to gate it behind the canary-only flag the way
 * `extractProbeOverrides` gates the body overrides. Returns `null` for a
 * missing or malformed header (over 40 characters, or containing anything
 * but letters, digits and dashes) rather than throwing, since a bad tag on
 * an otherwise-normal request should degrade to "untagged", not fail the
 * question.
 */
export function readProbeTag(req: Request): string | null {
  const raw = req.headers.get("x-lhf-probe");
  if (!raw) return null;
  return PROBE_TAG_PATTERN.test(raw) ? raw : null;
}
