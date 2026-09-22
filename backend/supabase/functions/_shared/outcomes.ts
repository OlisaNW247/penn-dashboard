// `ask_outcomes` telemetry -- the "measure" half of the measure-fix-verify
// loop this was built for. Deliberately separate from quota.ts's
// `ask_usage`/`recordUsage`: `ask_usage` counts requests for the quota,
// forever, at day granularity, scoped only to who made a request; this
// exists to say *why* a request came out the way it did (the exact
// 2026-09-14 shape -- a thinking model spending the whole output cap on
// hidden reasoning and streaming zero content -- that until now left no
// trace but an unwatched `console.warn` line), and carries no promise of
// being kept forever the way the quota ledger does.
//
// Split into a pure classification function (testable with no Postgres,
// mirroring quota.ts's own `checkQuota`) and an RPC caller that never
// throws and carries its own deadline, for the identical reason
// `recordUsage` does: this is invoked from inside `ask`'s SSE generator,
// after the response the student is going to read has already been fully
// decided (in most cases, after it has already been sent -- see
// `ask/index.ts`'s use of `EdgeRuntime.waitUntil`), so a stall here must
// cost at most one missing row, never a delayed or broken stream.

/** The taxonomy `ask_outcomes.outcome`'s check constraint enforces
 *  (20260922090000_ask_outcomes.sql). `timeout` is reserved for a future
 *  caller (a canary harness pinning its own client-side deadline, for
 *  instance) -- nothing in `ask/index.ts` classifies a request as
 *  `timeout` today, since every failure path it currently has already has
 *  a more specific bucket (`upstream_error`, `quota`, `client_error`). */
export type AskOutcome =
  | "answered"
  | "empty"
  | "upstream_error"
  | "quota"
  | "timeout"
  | "client_error";

export interface StreamOutcomeInput {
  /** Characters of `delta.content` that actually reached the student. */
  contentChars: number;
  /** Whether the stream ended via a mid-stream failure (an `error` SSE
   *  event) rather than a clean `done`. */
  streamFailed: boolean;
}

/**
 * Classifies a stream that ran to completion (clean `done`) or failed
 * mid-flight: `upstream_error` when the stream itself broke, otherwise
 * `answered` when any content reached the student and `empty` when it
 * didn't -- the `empty` case is exactly the 2026-09-14 incident's shape,
 * which is the entire reason this table exists.
 */
export function classifyStreamOutcome(
  input: StreamOutcomeInput,
): "answered" | "empty" | "upstream_error" {
  if (input.streamFailed) return "upstream_error";
  return input.contentChars > 0 ? "answered" : "empty";
}

export interface RecordOutcomeInput {
  userId: string;
  model: string;
  outcome: AskOutcome;
  promptTokens?: number;
  completionTokens?: number;
  reasoningTokens?: number;
  cachedTokens?: number;
  contentChars?: number;
  deltaCount?: number;
  latencyMs?: number;
  firstDeltaMs?: number;
  upstreamStatus?: number;
  /** An error class or message only -- already capped at 400 characters by
   *  `_shared/openrouter.ts`'s `readErrorBody` upstream of this, and capped
   *  again here defensively. Never the question, context document,
   *  excerpts or answer -- there is no field on this table that could hold
   *  any of those, and this one specifically must never be handed one. */
  detail?: string;
  probe?: string | null;
  /** `ask/index.ts`'s `timing.preRace` -- wall-clock time from the start of
   *  the request to the moment the model race begins (auth, body parsing,
   *  the quota check, and loading enrollment/profiles/catalog). Undefined
   *  for any outcome recorded before that point is reached (a malformed
   *  request, a quota rejection, a missing API key), since there is no
   *  meaningful number yet. */
  preRaceMs?: number;
  /** `ask/index.ts`'s `timing.race` -- wall-clock time spent in
   *  `runHedgedRace` itself, from the first model call to a winning delta
   *  or a failure. Undefined whenever the request never reached the race. */
  raceMs?: number;
}

/** Minimal shape of a service-role Supabase client this module needs --
 *  same seam `quota.ts`'s `RPCClientLike` uses, repeated here rather than
 *  imported so this module has no dependency on quota.ts's internals. */
export interface RPCClientLike {
  rpc(fn: string, params: Record<string, unknown>): {
    abortSignal(signal: AbortSignal): PromiseLike<{ data: unknown; error: { message: string } | null }>;
  };
}

const DEFAULT_OUTCOME_DEADLINE_MS = 4000;
const MAX_DETAIL_CHARS = 200;

/**
 * Never throws -- the same fail-open posture `quota.ts`'s `recordUsage`
 * holds itself to, for the same reason: telemetry about a request must
 * never be able to make the request itself slower or less reliable. A
 * timeout or a database error is logged and dropped, one missing outcome
 * row, nothing more.
 *
 * The "exceeded deadline" warning below used to fire on every request
 * regardless of how fast the write actually landed, because only
 * `abortTimer` was cleared in `finally` -- the warning's own `setTimeout`
 * kept ticking even after `request` won the race, and `EdgeRuntime
 * .waitUntil` kept the isolate alive long enough for it to fire anyway (see
 * `quota.ts`'s `recordUsage`, which had the identical bug, for the full
 * incident writeup). `warnTimer` is now kept and cleared alongside
 * `abortTimer`, so this warning firing now means what it says: the write
 * really did not return inside `deadlineMs`.
 */
export async function recordOutcome(
  serviceClient: RPCClientLike,
  input: RecordOutcomeInput,
  deadlineMs = DEFAULT_OUTCOME_DEADLINE_MS,
): Promise<void> {
  const controller = new AbortController();
  const abortTimer = setTimeout(() => controller.abort(), deadlineMs);

  const request = (async (): Promise<void> => {
    const t0 = Date.now();
    try {
      const { error } = await serviceClient
        .rpc("record_ask_outcome", {
          p_user_id: input.userId,
          p_model: input.model,
          p_outcome: input.outcome,
          p_prompt_tokens: input.promptTokens ?? null,
          p_completion_tokens: input.completionTokens ?? null,
          p_reasoning_tokens: input.reasoningTokens ?? null,
          p_cached_tokens: input.cachedTokens ?? null,
          p_content_chars: input.contentChars ?? 0,
          p_delta_count: input.deltaCount ?? 0,
          p_latency_ms: input.latencyMs ?? null,
          p_first_delta_ms: input.firstDeltaMs ?? null,
          p_upstream_status: input.upstreamStatus ?? null,
          p_detail: input.detail ? input.detail.slice(0, MAX_DETAIL_CHARS) : null,
          p_probe: input.probe ?? null,
          p_pre_race_ms: input.preRaceMs ?? null,
          p_race_ms: input.raceMs ?? null,
        })
        .abortSignal(controller.signal);
      if (error) {
        console.warn("ask: record_ask_outcome failed:", error.message);
      } else {
        console.log(`ask: record_ask_outcome ok in ${Date.now() - t0}ms`);
      }
    } catch (err) {
      console.warn("ask: record_ask_outcome failed:", err instanceof Error ? err.message : String(err));
    }
  })();

  let warnTimer: number | undefined;
  const timeout = new Promise<void>((resolve) => {
    warnTimer = setTimeout(() => {
      console.warn(`ask: record_ask_outcome exceeded ${deadlineMs}ms deadline`);
      resolve();
    }, deadlineMs);
  });

  try {
    await Promise.race([request, timeout]);
  } finally {
    clearTimeout(abortTimer);
    clearTimeout(warnTimer);
  }
}
