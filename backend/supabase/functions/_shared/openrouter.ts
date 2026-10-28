// The one place this backend calls a model. Both entry points --
// `chatCompletionStream` for `ask`, `chatCompletionJSON` for the two
// extract functions -- take `fetchImpl` as a parameter rather than calling
// the global `fetch` themselves, so every test in `openrouter.test.ts` can
// hand in a fake and this file never needs a live OpenRouter key, or the
// network, to be exercised at all. `ask/index.ts` and the extract functions
// are what pass the real global `fetch` in at the edges.
import { reasoningFor } from "./fallback.ts";

export interface ChatMessage {
  role: string;
  content: string;
}

export interface ProviderPreferences {
  /** `LHF_PROVIDER_ORDER`, parsed to a list. Only included in the request
   *  body when non-empty -- see `buildRequestBody`. */
  order?: string[];
}

/** Thrown for both a non-2xx OpenRouter response and a transport-level
 *  `fetch` failure (network down, DNS, timeout, an aborted signal), after
 *  whatever fallback retry applies has already been attempted. `status` is
 *  the HTTP status when there was one; absent for a network-level failure,
 *  since there is no status to report. Callers (`ask/index.ts`, the two
 *  extract functions) catch this and turn it into the appropriate
 *  protocol-shaped error -- 502 JSON before any streaming has started, an
 *  `error` SSE event once it has -- rather than this file knowing about
 *  HTTP responses or SSE at all. */
export class UpstreamError extends Error {
  readonly status?: number;
  constructor(message: string, status?: number) {
    super(message);
    this.name = "UpstreamError";
    this.status = status;
  }
}

/** The three event shapes a streaming completion can produce, reduced from
 *  OpenRouter's full per-chunk JSON to only what `ask/index.ts` acts on.
 *  `reasoningTokens` on the `usage` event is only present at all when
 *  OpenRouter's own chunk carried `usage.completion_tokens_details
 *  .reasoning_tokens` -- omitted, not zero, when the field wasn't there,
 *  so a caller can tell "no reasoning happened" apart from "this response
 *  didn't report reasoning token counts at all" (some providers behind
 *  OpenRouter don't). This is what lets `ask/index.ts` record how much of
 *  a thinking model's output cap went to hidden reasoning versus visible
 *  content -- the exact split the 2026-09-14 incident had no record of. */
export type StreamEvent =
  | { type: "delta"; text: string }
  | {
    type: "usage";
    promptTokens: number;
    completionTokens: number;
    cachedTokens: number;
    reasoningTokens?: number;
  }
  | { type: "done" };

export interface ChatCompletionStreamOptions {
  fetchImpl: typeof fetch;
  apiKey: string;
  model: string;
  /** When set, one retry against this model is attempted after a primary-
   *  model failure that looks retryable (see `isFallbackEligible`). */
  fallbackModel?: string;
  messages: ChatMessage[];
  provider?: ProviderPreferences;
  maxTokens: number;
  temperature?: number;
  /** OpenRouter's unified reasoning control -- forwarded verbatim as the
   *  request body's `reasoning` field when present. Untyped past `unknown`
   *  because the shape OpenRouter (or the provider behind it) will actually
   *  accept is not yet known -- `{ enabled: false }` was rejected with a
   *  400 on its first live call (see the comment on `buildRequestBody`) --
   *  and `ask-canary` exists specifically to let a harness try other
   *  shapes without a code change here every time. Omitted entirely (not
   *  just left `undefined` inside an object) when the caller doesn't set
   *  it, which is what keeps the extract functions' request body
   *  byte-for-byte unchanged. */
  reasoning?: unknown;
  /** Forwarded verbatim as the request body's `provider` field, *replacing*
   *  the `data_collection`/`allow_fallbacks`/`order` object `provider`
   *  above would otherwise build, rather than merging with it -- only
   *  `ask-canary` ever sets this, to let a harness try a different
   *  provider routing shape against the identical prompt/model/messages
   *  production `ask` would send. `undefined` (the default) leaves
   *  `provider` built from `provider`/`ProviderPreferences` exactly as
   *  before this field existed. */
  providerOverride?: unknown;
  signal?: AbortSignal;
}

export interface ChatCompletionJSONOptions {
  fetchImpl: typeof fetch;
  apiKey: string;
  model: string;
  fallbackModel?: string;
  messages: ChatMessage[];
  provider?: ProviderPreferences;
  maxTokens: number;
  temperature?: number;
  signal?: AbortSignal;
}

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

/**
 * A `content_block_delta`-style stream of OpenAI-shaped chunks. Consumes
 * `response.body` incrementally rather than buffering the whole response,
 * which is the entire reason `ask` can start forwarding `delta` events to
 * the student before the model has finished answering.
 */
export async function* chatCompletionStream(
  options: ChatCompletionStreamOptions,
): AsyncGenerator<StreamEvent> {
  const body = buildRequestBody({
    model: options.model,
    messages: options.messages,
    maxTokens: options.maxTokens,
    temperature: options.temperature,
    provider: options.provider,
    stream: true,
    reasoning: options.reasoning,
    providerOverride: options.providerOverride,
  });

  const { response } = await requestWithFallback(
    options.fetchImpl,
    options.apiKey,
    body,
    options.fallbackModel,
    options.signal,
  );

  if (!response.body) {
    throw new UpstreamError("OpenRouter response had no body");
  }

  yield* parseSSEStream(response.body);
}

/**
 * Non-streaming variant used by the two extract functions, which want one
 * complete JSON object back, not a stream of text fragments.
 *
 * Two things here exist because of a real failure (2026-10-23, a phone, one
 * 255-word Canvas announcement that failed twice with a 502 while a 53-word
 * one succeeded). `extract-announcement`'s default model is `z-ai/glm-5.3-
 * flash`, a thinking model, and with `reasoning` unset it can spend the whole
 * `maxTokens` cap on hidden reasoning and come back HTTP 200 with
 * `choices[0].message.content` null or empty. That is not a failure
 * `requestWithFallback` can see -- it only tries `fallbackModel` when the
 * HTTP request itself fails -- so the call fell through to "missing content",
 * the handler turned it into a 502, and because the model's behaviour on a
 * given prompt is deterministic at temperature 0, retrying the same request
 * failed the same way. So:
 *
 * 1. Every body carries `reasoning: reasoningFor(<the model that body
 *    targets>)`: `{ effort: "low" }` for a `z-ai/` model, which cuts its
 *    reasoning to a handful of tokens, and no field at all for anything else
 *    (a non-thinking model may reject one). The fallback body is built for
 *    the *fallback* model, not copied from the primary's with the model id
 *    swapped, because the two may differ -- the default pairing is exactly a
 *    `z-ai/` primary and a non-`z-ai` fallback.
 * 2. A 200 with no usable content (null, missing, or empty/whitespace) gets
 *    one attempt against `fallbackModel` before this throws. If the fallback
 *    already ran because the primary 5xx'd, it is not asked a second time.
 *
 * The wrong fixes: raising `maxTokens` alone (it makes the failure rarer and
 * dearer, and a long enough post still exhausts it); and treating an empty
 * 200 as success, which this function used to for an empty *string* and which
 * `parseAssignments` then turned into "this announcement has no tasks" -- a
 * confident wrong answer where a retry or an honest error was owed.
 */
export async function chatCompletionJSON(
  options: ChatCompletionJSONOptions,
): Promise<string> {
  const bodyFor = (model: string) =>
    buildRequestBody({
      model,
      messages: options.messages,
      maxTokens: options.maxTokens,
      temperature: options.temperature,
      provider: options.provider,
      stream: false,
      responseFormat: { type: "json_object" },
      reasoning: reasoningFor(model),
    });

  const { response, usedFallback } = await requestWithFallback(
    options.fetchImpl,
    options.apiKey,
    bodyFor(options.model),
    options.fallbackModel,
    options.signal,
    bodyFor,
  );

  const content = await readUsableContent(response);
  if (content !== undefined) return content;

  if (options.fallbackModel === undefined || usedFallback) {
    throw new UpstreamError("OpenRouter response was missing choices[0].message.content");
  }

  // Model ids only -- never the prompt or the post -- so this is safe to log,
  // and it is the one place anyone learns that the primary is coming back
  // empty instead of the fallback quietly absorbing it on every request.
  console.warn(
    `chatCompletionJSON: ${options.model} returned no usable content, trying ${options.fallbackModel}`,
  );
  const fallbackResponse = await requestFallback(
    options.fetchImpl,
    options.apiKey,
    bodyFor(options.fallbackModel),
    options.signal,
  );
  const fallbackContent = await readUsableContent(fallbackResponse);
  if (fallbackContent === undefined) {
    throw new UpstreamError("OpenRouter fallback response was missing choices[0].message.content");
  }
  return fallbackContent;
}

/** `choices[0].message.content` when it is a string with something in it;
 *  `undefined` for null, missing, or empty/whitespace. A body that is not
 *  JSON at all still throws -- that is a broken response, not an empty
 *  answer, and no model swap is promised for it. */
async function readUsableContent(response: Response): Promise<string | undefined> {
  let payload: unknown;
  try {
    payload = await response.json();
  } catch (err) {
    throw new UpstreamError(`OpenRouter response was not JSON: ${describeError(err)}`);
  }
  const content = extractMessageContent(payload);
  return typeof content === "string" && content.trim().length > 0 ? content : undefined;
}

// ---------------------------------------------------------------------
// Request construction
// ---------------------------------------------------------------------

interface BuildRequestBodyOptions {
  model: string;
  messages: ChatMessage[];
  maxTokens: number;
  temperature?: number;
  provider?: ProviderPreferences;
  stream: boolean;
  responseFormat?: { type: string };
  reasoning?: unknown;
  providerOverride?: unknown;
}

/**
 * `z-ai/glm-5.3-flash` -- once `ask`'s only model, now its hedge/fallback
 * (see `ask/index.ts`'s long comment on `HEDGE_AFTER_MS`) -- is a thinking
 * model: unless told otherwise it spends output tokens on a
 * `delta.reasoning` stream before it ever emits `delta.content` (OpenRouter
 * forwards both; `parseSSEStream` above only reads the latter). Against a
 * real 14.5k-token prompt of full syllabi (2026-09-14, a phone asking
 * "when's my next exam?") the model reasoned until `max_tokens` was
 * exhausted and produced zero content -- 35s of streaming, a 200, and
 * nothing the student could read. Synthetic test prompts of the same size
 * reason briefly and still answer, which is why this shipped unnoticed.
 * `reasoning: { enabled: false }` -- OpenRouter's unified switch for turning
 * reasoning off outright -- was rejected with a 400 on its first live call
 * and is not used; `reasoning: { effort: "low" }` (`_shared/fallback.ts`'s
 * `reasoningFor`, applied only to `z-ai/` models) is accepted and cuts the
 * reasoning spend to a handful of tokens, but 2026-09-22 canary runs found
 * it does not fix this model's real problem -- a long tail of slow
 * *provider* responses unrelated to reasoning at all -- which is why `ask`
 * no longer waits this model out alone: `openai/gpt-4.1-mini`, which sends
 * no `reasoning` field here at all, is the primary now, and this model is
 * raced in only once the primary has gone quiet for `HEDGE_AFTER_MS`. The
 * JSON-mode extract functions now send `reasoningFor(model)` too (see
 * `chatCompletionJSON`: their default model is this same thinking model, and
 * the same empty-answer failure reached a phone as a 502 on 2026-10-23). The
 * wrong fix, still, is raising
 * `MAX_TOKENS` alone: it only makes the empty-answer failure rarer and the
 * bill bigger, and a long enough prompt still exhausts it.
 */
function buildRequestBody(options: BuildRequestBodyOptions): Record<string, unknown> {
  // `providerOverride` (only ever set by `ask-canary`) replaces this whole
  // computed object rather than merging with it -- a harness trying a
  // different provider-routing shape wants exactly what it asked for, not
  // that shape merged with defaults it may be specifically trying to rule
  // out.
  let provider: unknown;
  if (options.providerOverride !== undefined) {
    provider = options.providerOverride;
  } else {
    const computedProvider: Record<string, unknown> = {
      data_collection: "deny",
      allow_fallbacks: true,
    };
    // Only present when the caller actually configured an order -- an empty
    // `order: []` is a different, and more restrictive, instruction to
    // OpenRouter than simply not mentioning the field at all.
    if (options.provider?.order && options.provider.order.length > 0) {
      computedProvider.order = options.provider.order;
    }
    provider = computedProvider;
  }

  const body: Record<string, unknown> = {
    model: options.model,
    messages: options.messages,
    max_tokens: options.maxTokens,
    stream: options.stream,
    provider,
  };
  if (options.temperature !== undefined) {
    body.temperature = options.temperature;
  }
  if (options.stream) {
    // Without this, OpenRouter's streaming responses omit the final
    // `usage` chunk entirely -- and `record_ask_usage` has nothing else to
    // report token counts from.
    body.usage = { include: true };
  }
  if (options.responseFormat) {
    body.response_format = options.responseFormat;
  }
  if (options.reasoning !== undefined) {
    // Forwarded verbatim -- see `ChatCompletionStreamOptions.reasoning`'s
    // doc comment for why this is no longer typed as `{ enabled: boolean }`.
    body.reasoning = options.reasoning;
  }
  return body;
}

async function postChatCompletions(
  fetchImpl: typeof fetch,
  apiKey: string,
  body: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<Response> {
  return await fetchImpl(OPENROUTER_URL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://lhf.app",
      "X-Title": "Low Hanging Fruit",
    },
    body: JSON.stringify(body),
    signal,
  });
}

/**
 * A 5xx (or a transport-level failure, which carries no status at all) is
 * plausibly model- or provider-specific and worth one retry against the
 * fallback model. A 4xx is not: it means the request itself was rejected
 * (bad API key, bad request shape, rate limit tied to the key rather than
 * the model), and none of those are fixed by asking a *different* model to
 * serve the identical request with the identical credentials -- retrying
 * anyway would just double-bill a request that was always going to fail
 * the same way. This is stricter than a literal reading of "retry on any
 * non-2xx", which is what makes the auth-error case (401) fail fast with
 * no fallback attempt.
 */
function isFallbackEligible(status: number): boolean {
  return status >= 500;
}

/**
 * Issues the primary request; on a retryable failure (5xx or a thrown
 * network error) with a `fallbackModel` configured, retries exactly once
 * against that model. Any other failure -- a non-retryable status, or a
 * retryable failure with no fallback configured -- surfaces immediately as
 * `UpstreamError`. Shared by both the streaming and JSON entry points so
 * this policy exists in exactly one place.
 */
async function requestWithFallback(
  fetchImpl: typeof fetch,
  apiKey: string,
  primaryBody: Record<string, unknown>,
  fallbackModel: string | undefined,
  signal?: AbortSignal,
  /** How to build the fallback request body for `fallbackModel`. The default
   *  copies the primary body with only `model` swapped, which is what the
   *  streaming path has always done and keeps it byte-for-byte unchanged;
   *  `chatCompletionJSON` passes its own so each model gets the `reasoning`
   *  field that suits it rather than inheriting the primary's. */
  fallbackBodyFor: (model: string) => Record<string, unknown> = (model) => ({ ...primaryBody, model }),
): Promise<{ response: Response; usedFallback: boolean }> {
  let primaryResponse: Response | undefined;
  let primaryError: unknown;

  try {
    primaryResponse = await postChatCompletions(fetchImpl, apiKey, primaryBody, signal);
  } catch (err) {
    primaryError = err;
  }

  if (primaryResponse?.ok) {
    return { response: primaryResponse, usedFallback: false };
  }

  const retryable = primaryError !== undefined ||
    (primaryResponse !== undefined && isFallbackEligible(primaryResponse.status));

  if (!retryable || !fallbackModel) {
    if (primaryResponse) {
      const errorBody = await describeErrorBody(primaryResponse);
      throw new UpstreamError(
        `OpenRouter responded ${primaryResponse.status} (${errorBody})`,
        primaryResponse.status,
      );
    }
    throw new UpstreamError(`OpenRouter request failed: ${describeError(primaryError)}`);
  }

  const fallbackResponse = await requestFallback(
    fetchImpl,
    apiKey,
    fallbackBodyFor(fallbackModel),
    signal,
  );
  return { response: fallbackResponse, usedFallback: true };
}

/** The one fallback request, shared by `requestWithFallback` (after an HTTP
 *  or transport failure) and `chatCompletionJSON` (after a 200 with no
 *  usable content), so both surface a failure as the same `UpstreamError`
 *  shapes. */
async function requestFallback(
  fetchImpl: typeof fetch,
  apiKey: string,
  fallbackBody: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<Response> {
  let fallbackResponse: Response;
  try {
    fallbackResponse = await postChatCompletions(fetchImpl, apiKey, fallbackBody, signal);
  } catch (err) {
    throw new UpstreamError(`OpenRouter fallback request failed: ${describeError(err)}`);
  }
  if (!fallbackResponse.ok) {
    const errorBody = await describeErrorBody(fallbackResponse);
    throw new UpstreamError(
      `OpenRouter fallback responded ${fallbackResponse.status} (${errorBody})`,
      fallbackResponse.status,
    );
  }
  return fallbackResponse;
}

function describeError(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Describes a failed response's body without repeating it: its length, or
 * "unreadable". An `UpstreamError`'s message is logged (`ask: upstream
 * failure detail`) and, for `ask`, stored in `ask_outcomes.detail`, so
 * whatever is in it is retained, and an upstream error body is not ours to
 * keep. OpenRouter forwards the provider's own message, and providers
 * sometimes quote the request back (a context-length or content-filter
 * refusal can include part of the prompt, which here is a student's course
 * material and question). The status is in the message and is what tells a
 * 4xx from a 5xx; the length is enough to tell an empty body from a verbose
 * one. This used to read and keep the first 400 characters, which is how the
 * 2026-09-14 `reasoning: {enabled:false}` 400 was finally diagnosed; the cost
 * of removing it is that an unfamiliar 4xx now has to be reproduced by hand
 * (the canary and `scripts/ask-probe.mjs` exist for that) instead of read
 * out of the log. Reading the body can itself throw (an already-consumed
 * stream, a network hiccup mid-read); that becomes "unreadable" rather than
 * replacing the real error.
 */
async function describeErrorBody(response: Response): Promise<string> {
  try {
    const text = await response.text();
    return `error body ${text.length} chars, not logged`;
  } catch {
    return "error body unreadable";
  }
}

// ---------------------------------------------------------------------
// Non-streaming response parsing
// ---------------------------------------------------------------------

function extractMessageContent(payload: unknown): unknown {
  if (typeof payload !== "object" || payload === null) return undefined;
  const choices = (payload as Record<string, unknown>).choices;
  if (!Array.isArray(choices) || choices.length === 0) return undefined;
  const first = choices[0];
  if (typeof first !== "object" || first === null) return undefined;
  const message = (first as Record<string, unknown>).message;
  if (typeof message !== "object" || message === null) return undefined;
  return (message as Record<string, unknown>).content;
}

// ---------------------------------------------------------------------
// Streaming (SSE) response parsing
// ---------------------------------------------------------------------

interface OpenRouterStreamChunk {
  choices?: Array<{ delta?: { content?: string } }>;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    prompt_tokens_details?: { cached_tokens?: number };
    /** Present on at least some OpenRouter providers/models (the thinking
     *  models this file's other comments are all about) when a completion
     *  spent output tokens on hidden reasoning -- see `StreamEvent`'s doc
     *  comment above for why this only becomes a `reasoningTokens` field
     *  on the yielded event when the source chunk actually carried it. */
    completion_tokens_details?: { reasoning_tokens?: number };
  };
}

/**
 * Reads `body` as UTF-8, splits on newlines, and interprets it as
 * OpenRouter's SSE wire format: lines starting with `:` are keep-alive
 * comments and are ignored, blank lines are the event separator and carry
 * no data, `data: [DONE]` ends the stream, and every other `data: {...}`
 * line is one JSON chunk that may carry a text delta, a `usage` block, or
 * both (the final chunk before `[DONE]` typically carries `usage` with an
 * empty `delta`).
 *
 * A malformed `data:` line (shouldn't happen against the real API, but a
 * test double or a future OpenRouter change could produce one) is skipped
 * rather than raised -- one bad chunk should not abort an otherwise-good
 * answer the student is already partway through reading.
 */
async function* parseSSEStream(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<StreamEvent> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let newlineIndex: number;
      while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
        const rawLine = buffer.slice(0, newlineIndex);
        buffer = buffer.slice(newlineIndex + 1);
        const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;

        if (line.length === 0 || line.startsWith(":")) continue;
        if (!line.startsWith("data:")) continue;

        const payload = line.slice("data:".length).trim();
        if (payload === "[DONE]") {
          yield { type: "done" };
          return;
        }

        let chunk: OpenRouterStreamChunk;
        try {
          chunk = JSON.parse(payload);
        } catch {
          continue;
        }

        const text = chunk.choices?.[0]?.delta?.content;
        if (typeof text === "string" && text.length > 0) {
          yield { type: "delta", text };
        }

        if (chunk.usage) {
          const reasoningTokens = chunk.usage.completion_tokens_details?.reasoning_tokens;
          // The conditional spread is what keeps `reasoningTokens` off the
          // event entirely (not present as a key at all, not present-but-
          // `undefined`) when the source chunk didn't carry it -- see
          // `StreamEvent`'s doc comment on why "no reasoning" and "not
          // reported" must stay distinguishable, and why this keeps the
          // existing `openrouter.test.ts` assertions (which `deepEqual` a
          // `usage` event against an object with no `reasoningTokens` key
          // at all) unaffected. Building this as one literal, rather than a
          // `let` variable mutated afterward, is also what lets it type-
          // check against the `StreamEvent` union without a discriminant
          // narrowing step this generator has no other reason to do.
          yield {
            type: "usage",
            promptTokens: chunk.usage.prompt_tokens ?? 0,
            completionTokens: chunk.usage.completion_tokens ?? 0,
            cachedTokens: chunk.usage.prompt_tokens_details?.cached_tokens ?? 0,
            ...(typeof reasoningTokens === "number" ? { reasoningTokens } : {}),
          };
        }
      }
    }
  } finally {
    reader.releaseLock();
  }

  // The real API always sends `data: [DONE]`; this is only reached if a
  // test double or a broken connection ends the body without one. Still
  // telling the caller the stream is over beats leaving `ask/index.ts`
  // awaiting an event that will never arrive.
  yield { type: "done" };
}
