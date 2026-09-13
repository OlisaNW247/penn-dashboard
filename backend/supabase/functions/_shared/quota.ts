// Quota bookkeeping is deliberately split from the SQL that stores the raw
// counters (see the migration's `ask_usage_counts` / `record_ask_usage`
// functions). This file is pure arithmetic over numbers a caller already
// fetched, on purpose: quota policy -- what "over quota" means, when it
// resets -- is exactly the kind of logic that benefits from being testable
// with a plain object and a `Date`, with no Postgres, no `Deno.env`, no
// network anywhere near the test.
//
// `lookupUsageCounts` / `quotaDecision` / `recordUsage` below are the one
// place every quota-checking function goes through to actually talk to
// Postgres. They exist because of a real incident (2026-09-13 20:47 UTC): a
// student's `ask` request came back 502 because `ask_usage_counts` -- two
// trivial lookups on a tiny table -- hit a ~60s PostgREST gateway timeout
// during a database stall that had nothing to do with the query itself. A
// quota counter is a budget guard, not a feature gate, so it must never be
// able to turn a transient database hiccup into a dead feature: a lookup
// that times out or errors degrades to "treat this call as unmetered" (fail
// OPEN), not to a 502, and a record that times out or errors is dropped
// with a warning, not surfaced, exactly like every existing call site
// already treats a `record_ask_usage` failure.

/** The two limits PROTOCOL.md's "ask" section defines. */
export interface QuotaLimits {
  /** Per-user, per-UTC-day request limit. Protocol default: 40. */
  dailyLimit: number;
  /** Across-all-users, per-calendar-month request limit. Protocol default: 100000. */
  monthlyGlobalLimit: number;
}

export interface CheckQuotaInput {
  /** This user's request count so far today (UTC). */
  todayRequests: number;
  /** Every user's combined request count so far this calendar month (UTC). */
  monthRequests: number;
  dailyLimit: number;
  monthlyGlobalLimit: number;
  /** Injected rather than read internally, so a test can pin any instant
   *  without touching the system clock -- the same reasoning
   *  `AssistantContextDocument` on the iOS side applies to date handling. */
  now: Date;
}

export interface QuotaResult {
  allowed: boolean;
  /**
   * The next instant at which the numbers this check saw could plausibly
   * be different. When the daily limit is what's binding (hit, or would be
   * hit first), this is the next UTC midnight; when only the monthly
   * global limit is binding, this is the first of next month (UTC). When
   * neither limit is exceeded, this is still populated (next UTC
   * midnight) for a uniform return shape, but the protocol only ever wires
   * `resetAt` into a response body on the 429 path -- callers under quota
   * have no use for it.
   */
  resetAt: Date;
}

export function checkQuota(input: CheckQuotaInput): QuotaResult {
  const dailyExceeded = input.todayRequests >= input.dailyLimit;
  const monthlyExceeded = input.monthRequests >= input.monthlyGlobalLimit;
  const allowed = !dailyExceeded && !monthlyExceeded;

  // The daily limit resets far sooner than the monthly one, so when both
  // are exceeded simultaneously the daily reset is the more actionable
  // answer for a student wondering when to try again -- "come back
  // tomorrow" beats "come back next month" even though both are true.
  const resetAt = monthlyExceeded && !dailyExceeded
    ? nextUTCMonthStart(input.now)
    : nextUTCMidnight(input.now);

  return { allowed, resetAt };
}

/** Midnight UTC on the day after `now`. `Date.UTC` normalizes an
 *  out-of-range day-of-month (e.g. day 32) into the following month by
 *  itself, so no special-casing is needed at a month boundary. */
export function nextUTCMidnight(now: Date): Date {
  return new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + 1,
    0, 0, 0, 0,
  ));
}

/** Midnight UTC on the first of the month after `now`. Same December-into-
 *  January rollover as above, courtesy of `Date.UTC` carrying the overflow
 *  into the year field automatically. */
export function nextUTCMonthStart(now: Date): Date {
  return new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth() + 1,
    1,
    0, 0, 0, 0,
  ));
}

/** Minimal shape of `Deno.env` this file needs, so a test can hand it a
 *  plain `Map`-backed object instead of mutating real process environment
 *  variables (which, in a test runner, can leak between test files). */
export interface EnvLike {
  get(key: string): string | undefined;
}

const DEFAULT_DAILY_LIMIT = 40;
const DEFAULT_MONTHLY_GLOBAL_LIMIT = 100000;

export function limitsFromEnv(env: EnvLike): QuotaLimits {
  return {
    dailyLimit: parsePositiveInt(env.get("ASK_DAILY_LIMIT"), DEFAULT_DAILY_LIMIT),
    monthlyGlobalLimit: parsePositiveInt(env.get("ASK_MONTHLY_GLOBAL_LIMIT"), DEFAULT_MONTHLY_GLOBAL_LIMIT),
  };
}

/** A blank, missing, non-numeric, zero or negative override is treated the
 *  same as "not set" and falls back to the default -- an operator typo in a
 *  function secret (`ASK_DAILY_LIMIT=""` or `"nope"`) should degrade to the
 *  documented default, not to an unlimited or always-exhausted quota. */
function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

/** Minimal shape every quota RPC call needs from a service-role client --
 *  just enough of `SupabaseClient["rpc"]`'s return type for this module to
 *  attach an abort signal and await it, so tests can hand in a fake client
 *  without importing the real `@supabase/supabase-js` types. The real
 *  client's `.rpc(...)` return value satisfies this structurally. */
export interface RPCClientLike {
  rpc(fn: string, params: Record<string, unknown>): {
    abortSignal(signal: AbortSignal): PromiseLike<{ data: unknown; error: { message: string } | null }>;
  };
}

export interface UsageCounts {
  todayRequests: number;
  monthRequests: number;
}

export type UsageLookup =
  | { ok: true; counts: UsageCounts }
  | { ok: false; reason: "timeout" | "error"; message: string };

const DEFAULT_QUOTA_DEADLINE_MS = 4000;

/**
 * Reads `ask_usage_counts` with a hard client-side deadline (default 4s,
 * well under PostgREST's ~60s gateway timeout that caused the 2026-09-13
 * incident). Never throws -- a timeout or a Postgres error is reported back
 * as a value, not thrown, so every caller can fail OPEN (proceed as if the
 * counts were zero) rather than propagate a 502 for a lookup that has
 * nothing to do with whether the student is actually over quota.
 *
 * The deadline is enforced two ways: an `AbortController` wired into
 * `.abortSignal()` so supabase-js actually cancels the underlying fetch
 * (a stalled request doesn't keep a connection open in the background
 * after this function has already returned a timeout to its caller), and a
 * plain `setTimeout` raced against the request as a belt-and-braces
 * fallback in case a given builder -- or, in tests, a fake one -- doesn't
 * honor the signal.
 */
export async function lookupUsageCounts(
  serviceClient: RPCClientLike,
  userId: string,
  deadlineMs = DEFAULT_QUOTA_DEADLINE_MS,
): Promise<UsageLookup> {
  const controller = new AbortController();
  const abortTimer = setTimeout(() => controller.abort(), deadlineMs);

  const request = (async (): Promise<UsageLookup> => {
    try {
      const { data, error } = await serviceClient
        .rpc("ask_usage_counts", { p_user_id: userId })
        .abortSignal(controller.signal);
      if (error) {
        return { ok: false, reason: "error", message: error.message };
      }
      const row = (Array.isArray(data) ? data[0] : data) as
        | { today_requests?: number; month_requests?: number }
        | null
        | undefined;
      return {
        ok: true,
        counts: {
          todayRequests: row?.today_requests ?? 0,
          monthRequests: row?.month_requests ?? 0,
        },
      };
    } catch (err) {
      return { ok: false, reason: "error", message: err instanceof Error ? err.message : String(err) };
    }
  })();

  const timeout = new Promise<UsageLookup>((resolve) => {
    setTimeout(() => {
      resolve({ ok: false, reason: "timeout", message: `ask_usage_counts exceeded ${deadlineMs}ms deadline` });
    }, deadlineMs);
  });

  try {
    return await Promise.race([request, timeout]);
  } finally {
    clearTimeout(abortTimer);
  }
}

/**
 * The fail-open rule, stated once so every call site applies it the same
 * way: a lookup that came back `ok:false` (timeout or database error)
 * allows the request through as `degraded: true` rather than blocking it --
 * the counter protects the aggregate budget, not the individual student, so
 * a stall that makes the counter unreadable should cost at most "this one
 * call goes unmetered", never a dead feature. A successful lookup runs
 * through the existing `checkQuota` arithmetic unchanged.
 */
export function quotaDecision(
  lookup: UsageLookup,
  limits: QuotaLimits,
  now: Date,
): { allowed: true; degraded: boolean } | { allowed: false; degraded: false; resetAt: Date } {
  if (!lookup.ok) {
    return { allowed: true, degraded: true };
  }
  const result = checkQuota({
    todayRequests: lookup.counts.todayRequests,
    monthRequests: lookup.counts.monthRequests,
    dailyLimit: limits.dailyLimit,
    monthlyGlobalLimit: limits.monthlyGlobalLimit,
    now,
  });
  if (!result.allowed) {
    return { allowed: false, degraded: false, resetAt: result.resetAt };
  }
  return { allowed: true, degraded: false };
}

/**
 * Records one request against `ask_usage` with the same hard deadline
 * `lookupUsageCounts` uses, and never throws: every existing call site
 * already treats a `record_ask_usage` failure as log-and-continue (the
 * answer has either already been decided or already been delivered by the
 * time this runs), so a stall here should degrade the same way a lookup
 * stall does -- one under-counted request, never a delayed or broken
 * response. The wrong fix would be leaving this call unbounded on the
 * theory that "it's already fire-and-forget, so a slow RPC doesn't matter"
 * -- in `ask/index.ts` this runs *inside* the SSE generator, after the
 * `done` event, and the generator's `for await` loop does not close the
 * response stream until this call settles, so an unbounded stall here
 * would hold a client's connection open long after every byte it's ever
 * going to get has already been sent.
 */
export async function recordUsage(
  serviceClient: RPCClientLike,
  userId: string,
  promptTokens: number,
  completionTokens: number,
  deadlineMs = DEFAULT_QUOTA_DEADLINE_MS,
): Promise<void> {
  const controller = new AbortController();
  const abortTimer = setTimeout(() => controller.abort(), deadlineMs);

  const request = (async (): Promise<void> => {
    try {
      const { error } = await serviceClient
        .rpc("record_ask_usage", {
          p_user_id: userId,
          p_prompt_tokens: promptTokens,
          p_completion_tokens: completionTokens,
        })
        .abortSignal(controller.signal);
      if (error) {
        console.warn("quota: record_ask_usage failed, one request will go under-counted:", error.message);
      }
    } catch (err) {
      console.warn(
        "quota: record_ask_usage failed, one request will go under-counted:",
        err instanceof Error ? err.message : String(err),
      );
    }
  })();

  const timeout = new Promise<void>((resolve) => {
    setTimeout(() => {
      console.warn(`quota: record_ask_usage exceeded ${deadlineMs}ms deadline, one request will go under-counted`);
      resolve();
    }, deadlineMs);
  });

  try {
    await Promise.race([request, timeout]);
  } finally {
    clearTimeout(abortTimer);
  }
}
