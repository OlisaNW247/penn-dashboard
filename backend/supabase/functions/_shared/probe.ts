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
// Two controls sit in front of this, added 2026-10-27 (hardening BE-A).
// Until then `ask-canary` was deployed with nothing in front of it but a
// valid Supabase JWT, and anyone can mint an anonymous one, so any caller
// could choose the model, `maxTokens` and provider routing on LHF's own
// OpenRouter key. First, the function answers only a request carrying
// `x-lhf-probe-secret` equal to the `LHF_PROBE_SECRET` env var, and with
// that env var unset it answers 404 to everyone (`gateCanary`, below), so
// a deploy that forgets the secret is closed, not open. Second, even a
// request that passes is held to `ProbePolicy`: the model must be on an
// allow-list, `maxTokens` and the other numbers are clamped to a ceiling,
// and `provider` and `reasoning` are reduced to the few keys a harness has
// a use for. A bad *malformed* field (wrong type) is still dropped, as it
// always was, but a well-formed field the policy refuses throws
// `ProbeRejectedError`, which `handleAsk` turns into a 400 naming the
// field. The wrong version of that is dropping it quietly: the harness
// asked for model X, got the default model's numbers back, and recorded
// them under X's tag.
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
  /** Overrides `ask/index.ts`'s default fallback model (`LHF_FALLBACK_MODEL`
   *  or `z-ai/glm-5.3-flash`) for this call only -- lets a harness point
   *  `model` at a bogus id to force the primary to fail before any content,
   *  then confirm this fallback model is what actually answers, without
   *  waiting on env configuration or touching production traffic. */
  fallbackModel?: string;
  /** Skips both the fallback and the hedge race entirely for this call, so
   *  a harness can measure the primary model alone -- e.g. to reproduce the
   *  pre-hedge `empty`/`upstream_error` shape without a second model
   *  answering underneath it and masking the result. */
  disableFallback?: boolean;
  /** Overrides `ask/index.ts`'s `HEDGE_AFTER_MS` (how long the primary gets
   *  before the fallback starts racing it) for this call only -- lets a
   *  harness force the hedge to fire near-immediately (a small value) to
   *  exercise the race path deterministically, or push it out to confirm
   *  the primary alone would have answered in time. */
  hedgeAfterMs?: number;
}

/** What a passing canary request may still ask for. The defaults are the
 *  two models production races (`openai/gpt-4.1-mini` and
 *  `z-ai/glm-5.3-flash`), plus whatever `LHF_MODEL` and
 *  `LHF_ASK_FALLBACK_MODEL` currently name, plus the comma-separated
 *  `LHF_PROBE_MODELS` for a candidate under test, so trying a new model is
 *  one secret edit and no code change. Any id starting `invalid/` is also
 *  allowed: it names no provider OpenRouter has, so it fails at once and
 *  costs nothing, and it is how a harness forces the primary to fail to
 *  prove the fallback alone can answer (PROTOCOL.md, `fallbackModel`). */
export interface ProbePolicy {
  models: ReadonlySet<string>;
  /** Production's `MAX_TOKENS` is 3000; a probe may go a little higher to
   *  watch a thinking model's reasoning eat the cap, and no further. */
  maxTokensCeiling: number;
  /** Past `ask`'s 45 s race budget a larger hedge delay could never fire. */
  hedgeAfterMsCeiling: number;
}

export const PROBE_MAX_TOKENS_CEILING = 4096;
export const PROBE_HEDGE_AFTER_MS_CEILING = 30_000;
const DEFAULT_PROBE_MODELS = ["openai/gpt-4.1-mini", "z-ai/glm-5.3-flash"];
const NEVER_RUNS_PREFIX = "invalid/";

export function probePolicyFromEnv(env: { get(name: string): string | undefined }): ProbePolicy {
  const models = new Set<string>(DEFAULT_PROBE_MODELS);
  for (const name of ["LHF_MODEL", "LHF_ASK_FALLBACK_MODEL"]) {
    const value = env.get(name)?.trim();
    if (value) models.add(value);
  }
  for (const entry of (env.get("LHF_PROBE_MODELS") ?? "").split(",")) {
    const value = entry.trim();
    if (value) models.add(value);
  }
  return {
    models,
    maxTokensCeiling: PROBE_MAX_TOKENS_CEILING,
    hedgeAfterMsCeiling: PROBE_HEDGE_AFTER_MS_CEILING,
  };
}

export const DEFAULT_PROBE_POLICY: ProbePolicy = probePolicyFromEnv({ get: () => undefined });

/** Thrown by `extractProbeOverrides` for a well-formed value the policy
 *  refuses. The message names the field and never echoes the value. */
export class ProbeRejectedError extends Error {
  constructor(field: string, why: string) {
    super(`probe.${field} ${why}`);
    this.name = "ProbeRejectedError";
  }
}

function checkModel(field: "model" | "fallbackModel", value: string, policy: ProbePolicy): string {
  if (policy.models.has(value) || value.startsWith(NEVER_RUNS_PREFIX)) return value;
  throw new ProbeRejectedError(field, "is not on the canary's model allow-list");
}

const PROVIDER_NAME = /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}$/;

/** `provider` replaces the routing object `ask` sends (`data_collection:
 *  "deny"`, `allow_fallbacks`, `order`). Forwarded verbatim it could set
 *  `data_collection: "allow"`, a price sort, or anything OpenRouter learns
 *  next. Only the harness's actual needs survive: a provider `order` (at
 *  most 8 plain names), `allow_fallbacks`, and `data_collection`, which can
 *  only ever be "deny" here; the privacy posture is not a probe knob. */
function sanitizeProvider(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ProbeRejectedError("provider", "must be an object");
  }
  const raw = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(raw)) {
    if (key === "order") {
      const order = raw.order;
      if (
        !Array.isArray(order) || order.length > 8 ||
        !order.every((n) => typeof n === "string" && PROVIDER_NAME.test(n))
      ) {
        throw new ProbeRejectedError("provider.order", "must be at most 8 plain provider names");
      }
      out.order = order;
    } else if (key === "allow_fallbacks") {
      if (typeof raw.allow_fallbacks !== "boolean") {
        throw new ProbeRejectedError("provider.allow_fallbacks", "must be a boolean");
      }
      out.allow_fallbacks = raw.allow_fallbacks;
    } else if (key === "data_collection") {
      if (raw.data_collection !== "deny") {
        throw new ProbeRejectedError("provider.data_collection", 'may only be "deny"');
      }
      out.data_collection = "deny";
    } else {
      throw new ProbeRejectedError("provider", `has a key the canary does not forward (${key.slice(0, 40)})`);
    }
  }
  return out;
}

/** `reasoning` is forwarded to the paid request too, and OpenRouter's own
 *  `reasoning.max_tokens` is a second budget the `maxTokens` clamp does not
 *  see. Keep `effort`, `enabled` and `exclude`, which are what the
 *  2026-09-14 and 2026-09-22 experiments used. `null` is kept as "send
 *  nothing", the shape a harness uses to switch the field off. */
function sanitizeReasoning(value: unknown): unknown {
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ProbeRejectedError("reasoning", "must be an object");
  }
  const raw = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(raw)) {
    if (key === "effort") {
      if (raw.effort !== "low" && raw.effort !== "medium" && raw.effort !== "high") {
        throw new ProbeRejectedError("reasoning.effort", "must be low, medium or high");
      }
      out.effort = raw.effort;
    } else if (key === "enabled" || key === "exclude") {
      if (typeof raw[key] !== "boolean") throw new ProbeRejectedError(`reasoning.${key}`, "must be a boolean");
      out[key] = raw[key];
    } else {
      throw new ProbeRejectedError("reasoning", `has a key the canary does not forward (${key.slice(0, 40)})`);
    }
  }
  return out;
}

/**
 * Reads `body.probe` when overrides are allowed for this call, otherwise
 * always returns `undefined` regardless of what the body contains -- the
 * one place that decides whether a `probe` field does anything, so
 * production `ask` and `ask-canary` share every other line of `handleAsk`.
 * Throws `ProbeRejectedError` for a well-formed value `policy` refuses (see
 * the module comment); a wrong-typed field is dropped, as before.
 */
export function extractProbeOverrides(
  rawBody: unknown,
  allowed: boolean,
  policy: ProbePolicy = DEFAULT_PROBE_POLICY,
): AskProbeOverrides | undefined {
  if (!allowed) return undefined;
  if (typeof rawBody !== "object" || rawBody === null) return undefined;
  const probe = (rawBody as Record<string, unknown>).probe;
  if (typeof probe !== "object" || probe === null) return undefined;
  const p = probe as Record<string, unknown>;

  const overrides: AskProbeOverrides = {};
  if (typeof p.model === "string" && p.model.length > 0) {
    overrides.model = checkModel("model", p.model, policy);
  }
  if (typeof p.maxTokens === "number" && Number.isFinite(p.maxTokens) && p.maxTokens > 0) {
    overrides.maxTokens = Math.min(Math.floor(p.maxTokens), policy.maxTokensCeiling);
  }
  if (Object.prototype.hasOwnProperty.call(p, "reasoning")) {
    const reasoning = sanitizeReasoning(p.reasoning);
    if (reasoning !== null) overrides.reasoning = reasoning;
  }
  if (typeof p.temperature === "number" && Number.isFinite(p.temperature)) {
    overrides.temperature = Math.min(Math.max(p.temperature, 0), 2);
  }
  if (Object.prototype.hasOwnProperty.call(p, "provider")) {
    overrides.provider = sanitizeProvider(p.provider);
  }
  if (typeof p.contextTrimChars === "number" && Number.isFinite(p.contextTrimChars) && p.contextTrimChars >= 0) {
    overrides.contextTrimChars = Math.floor(p.contextTrimChars);
  }
  if (typeof p.fallbackModel === "string" && p.fallbackModel.length > 0) {
    overrides.fallbackModel = checkModel("fallbackModel", p.fallbackModel, policy);
  }
  if (typeof p.disableFallback === "boolean") {
    overrides.disableFallback = p.disableFallback;
  }
  if (typeof p.hedgeAfterMs === "number" && Number.isFinite(p.hedgeAfterMs) && p.hedgeAfterMs >= 0) {
    overrides.hedgeAfterMs = Math.min(Math.floor(p.hedgeAfterMs), policy.hedgeAfterMsCeiling);
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

// ---------------------------------------------------------------------
// The secret gate
// ---------------------------------------------------------------------

export const PROBE_SECRET_HEADER = "x-lhf-probe-secret";

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/** Compares two strings without the time depending on where they first
 *  differ or on how long either is: both are hashed to 32 bytes first, then
 *  every byte of the two digests is folded in, with no early exit. A plain
 *  `===` leaks the length of the matching prefix to anyone who can time
 *  responses. */
export async function constantTimeEqual(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all([sha256(a), sha256(b)]);
  let diff = da.length ^ db.length;
  for (let i = 0; i < da.length; i++) diff |= da[i] ^ (db[i] ?? 0);
  return diff === 0;
}

/** What Supabase itself answers for a function that is not deployed, so a
 *  gated canary is indistinguishable from an absent one. */
function notFound(): Response {
  return new Response(JSON.stringify({ code: "NOT_FOUND", message: "Requested function was not found" }), {
    status: 404,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Runs `handler` only for a request whose `x-lhf-probe-secret` equals
 * `secret`; everything else, for every method including OPTIONS, gets the
 * 404 above. An unset or empty `secret` therefore closes the function for
 * everyone, which is the point: the failure to configure it must not be
 * the failure that opens it. A wrong secret and a missing one get the same
 * answer, so the response never says whether the function exists or the
 * secret was close.
 */
export async function gateCanary(
  req: Request,
  secret: string | undefined,
  handler: (req: Request) => Promise<Response>,
): Promise<Response> {
  if (!secret) return notFound();
  const presented = req.headers.get(PROBE_SECRET_HEADER);
  if (presented === null || !(await constantTimeEqual(presented, secret))) return notFound();
  return handler(req);
}
