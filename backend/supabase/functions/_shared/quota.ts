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
// trivial lookups on a tiny table -- hit Supabase's API gateway timeout
// (about 5 s in front of PostgREST, `sb_gateway_version: 2`, body
// `{"message":"Gateway Timeout"}`; the logs later showed Postgres itself
// idle and never slow, so the stall was the gateway-to-PostgREST hop, not
// the database) that had nothing to do with the query itself. A
// quota counter is a budget guard, not a feature gate, so it must never be
// able to turn a transient database hiccup into a dead feature: a lookup
// that times out or errors degrades to "treat this call as unmetered" (fail
// OPEN), not to a 502, and a record that times out or errors is dropped
// with a warning, not surfaced, exactly like every existing call site
// already treats a `record_ask_usage` failure.

// Reserve, then settle (hardening BE-C, 2026-10-27). The functions above
// (`lookupUsageCounts`, `quotaDecision`, `recordUsage`) check first and charge
// afterwards, which leaves two holes: requests that overlap all read the same
// count and all go through, and a request the client abandons before the
// stream ends never reaches the line that charges, although the model has
// been called and billed. `reserveUsage` below does the check and the
// charge as one database statement BEFORE the model call, and a `UsageLease`
// settles the tokens (or gives the request back) afterwards. The three old
// functions are no longer called by any Edge Function; they stay because the
// SQL they wrap does (functions deployed before the migration still use it)
// and because their tests pin the fail-open rules `reserveUsage` inherits.
// Delete them with `record_ask_usage` and `ask_usage_counts` once nothing
// deployed calls either.

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

/** `recordUsage`'s deadline: a write, never awaited by the client (it runs
 *  fire-and-forget inside `ask`'s SSE generator via `EdgeRuntime.waitUntil`),
 *  so it can afford to stay close to the ~5s API-gateway timeout that caused
 *  the 2026-09-13 incident without costing the student anything. */
const DEFAULT_RECORD_DEADLINE_MS = 4000;

/** `lookupUsageCounts`'s deadline: unlike `recordUsage` this one sits on the
 *  critical path -- `ask/index.ts` awaits it before it can start the model
 *  race -- so 2026-09-22's per-step timing work (measured pre-race time up
 *  to 2.6s on a live canary) cut it from the original 4000ms to 1500ms. The
 *  lookup already fails OPEN (`quotaDecision`), so a slow counter costs at
 *  most one under-counted request, never a lost feature; the phone would
 *  rather get an answer than a precisely-counted one.
 */
const DEFAULT_LOOKUP_DEADLINE_MS = 1500;

/**
 * Reads `ask_usage_counts` with a hard client-side deadline (default 1.5s;
 * see `DEFAULT_LOOKUP_DEADLINE_MS`). Never throws -- a timeout or a Postgres error is reported back
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
 * honor the signal. That second timer's id is kept and cleared in `finally`
 * alongside the abort timer -- see `recordUsage`'s comment on the same
 * pattern below for why an uncleared one is a real bug, not just untidy:
 * without this, a request that wins the race leaves the timeout's own timer
 * running for the rest of `deadlineMs`, doing nothing here (its `resolve()`
 * is a harmless no-op against an already-settled `Promise.race`) but still
 * holding the isolate's event loop open for that long for no reason.
 */
export async function lookupUsageCounts(
  serviceClient: RPCClientLike,
  userId: string,
  deadlineMs = DEFAULT_LOOKUP_DEADLINE_MS,
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

  let warnTimer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<UsageLookup>((resolve) => {
    warnTimer = setTimeout(() => {
      resolve({ ok: false, reason: "timeout", message: `ask_usage_counts exceeded ${deadlineMs}ms deadline` });
    }, deadlineMs);
  });

  try {
    return await Promise.race([request, timeout]);
  } finally {
    clearTimeout(abortTimer);
    clearTimeout(warnTimer);
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
 * Records one request against `ask_usage` with its own hard deadline
 * (default 4s; see `DEFAULT_RECORD_DEADLINE_MS`), and never throws: every
 * existing call site already treats a `record_ask_usage` failure as
 * log-and-continue (the answer has either already been decided or already
 * been delivered by the time this runs), so a stall here should degrade the
 * same way a lookup stall does -- one under-counted request, never a
 * delayed or broken response. The wrong fix would be leaving this call
 * unbounded on the theory that "it's already fire-and-forget, so a slow RPC
 * doesn't matter" -- in `ask/index.ts` this runs *inside* the SSE
 * generator, after the `done` event, and the generator's `for await` loop
 * does not close the response stream until this call settles, so an
 * unbounded stall here would hold a client's connection open long after
 * every byte it's ever going to get has already been sent.
 *
 * The "exceeded deadline" warning below used to fire on *every* request,
 * regardless of whether the write actually landed in time -- 2026-09-22's
 * canary timing work found `record_ask_usage` and `record_ask_outcome`
 * succeeding in 125-440ms (see the `console.log` in the `try` block) while
 * this warning logged anyway, ~4s later, on every single one. The bug was
 * that only `abortTimer` was ever cleared in `finally`; the warning's own
 * `setTimeout` kept running even after `request` had already won the race
 * and the isolate was kept alive regardless by `EdgeRuntime.waitUntil`, so
 * the stale timer fired and logged a lie every time. `warnTimer` is now
 * kept and cleared alongside `abortTimer`, so if this warning fires now, it
 * means what it says: the write really did not return inside `deadlineMs`.
 */
export async function recordUsage(
  serviceClient: RPCClientLike,
  userId: string,
  promptTokens: number,
  completionTokens: number,
  deadlineMs = DEFAULT_RECORD_DEADLINE_MS,
): Promise<void> {
  const controller = new AbortController();
  const abortTimer = setTimeout(() => controller.abort(), deadlineMs);

  const request = (async (): Promise<void> => {
    const t0 = Date.now();
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
      } else {
        // Timing of the successful round-trip, so the "exceeded deadline"
        // warning below can be read against how long the write really took
        // when it did land.
        console.log(`quota: record_ask_usage ok in ${Date.now() - t0}ms`);
      }
    } catch (err) {
      console.warn(
        "quota: record_ask_usage failed, one request will go under-counted:",
        err instanceof Error ? err.message : String(err),
      );
    }
  })();

  let warnTimer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<void>((resolve) => {
    warnTimer = setTimeout(() => {
      console.warn(`quota: record_ask_usage exceeded ${deadlineMs}ms deadline, one request will go under-counted`);
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

// ---------------------------------------------------------------------
// Reserve, then settle
// ---------------------------------------------------------------------

/** What a granted reservation lets its holder do afterwards, exactly once.
 *  Whichever of `settle` and `release` runs first wins; the other, and any
 *  repeat, does nothing, so every exit path of a handler can call one
 *  without tracking which already ran. Neither throws. */
export interface UsageLease {
  /** Keep the request counted and add the tokens it used. Use for every
   *  request that reached the model and was not abandoned before it
   *  started, including a stream that broke after content was sent, and
   *  one the client walked away from (`settle(0, 0)` if no usage was seen):
   *  the model was called and the provider billed it. */
  settle(promptTokens: number, completionTokens: number): Promise<void>;
  /** Give the request back. Only for a request that never reached the model,
   *  or failed before the student was shown anything while still connected.
   *  Never for a client that left: refunding an abandoned request would make
   *  "send a large prompt, hang up, get the unit back" a free loop, which is
   *  the hole this exists to close. */
  release(): Promise<void>;
}

/** The lease of a request that is not metered (the counter failed open):
 *  nothing was reserved, so there is nothing to settle or give back. */
export const NO_LEASE: UsageLease = {
  settle: () => Promise.resolve(),
  release: () => Promise.resolve(),
};

export type UsageReservation =
  | { status: "denied"; resetAt: Date }
  /** `degraded` is true when the reservation call timed out or errored and
   *  the request was let through unmetered (the 2026-09-13 rule: a counter
   *  stall must never become a dead feature). `lease` is `NO_LEASE` then. */
  | { status: "granted"; lease: UsageLease; degraded: boolean };

type RPCCall =
  | { ok: true; data: unknown }
  | { ok: false; reason: "timeout" | "error"; message: string };

/** One RPC with the deadline pattern every call in this file uses: an
 *  `AbortController` wired into `.abortSignal()` so supabase-js really
 *  cancels the fetch, a plain timer raced against it in case a builder
 *  ignores the signal, and both timers cleared in `finally` (an uncleared
 *  one keeps the isolate's event loop open and, for the warning variant,
 *  logs a lie on every request; see `recordUsage`). Never throws. */
async function callRPCWithDeadline(
  client: RPCClientLike,
  fn: string,
  params: Record<string, unknown>,
  deadlineMs: number,
): Promise<RPCCall> {
  const controller = new AbortController();
  const abortTimer = setTimeout(() => controller.abort(), deadlineMs);

  const request = (async (): Promise<RPCCall> => {
    try {
      const { data, error } = await client.rpc(fn, params).abortSignal(controller.signal);
      if (error) return { ok: false, reason: controller.signal.aborted ? "timeout" : "error", message: error.message };
      return { ok: true, data };
    } catch (err) {
      return {
        ok: false,
        reason: controller.signal.aborted ? "timeout" : "error",
        message: err instanceof Error ? err.message : String(err),
      };
    }
  })();

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<RPCCall>((resolve) => {
    timer = setTimeout(() => {
      resolve({ ok: false, reason: "timeout", message: `${fn} exceeded ${deadlineMs}ms deadline` });
    }, deadlineMs);
  });

  try {
    return await Promise.race([request, timeout]);
  } finally {
    clearTimeout(abortTimer);
    clearTimeout(timer);
  }
}

/**
 * Reserves one unit of quota for `userId` before a model call, in one
 * database statement (`reserve_ask_usage`, 20261027100000_reserve_ask_usage.sql):
 * granted only if the user's count for today is under `limits.dailyLimit`
 * (atomic against parallel requests) and the month's global count is under
 * `limits.monthlyGlobalLimit` (a snapshot, so it can overshoot by the number
 * of requests in flight). Never throws.
 *
 * The deadline is 1.5 s, the same as the lookup it replaces, and the
 * failure rule is the same: a timeout or database error lets the request
 * through unmetered (`degraded: true`, `NO_LEASE`) instead of turning a
 * stalled counter into a dead `ask`. A reservation that actually committed
 * after the client gave up on it stays counted with no tokens and no way to
 * be given back; that is one over-counted request, the safe direction.
 *
 * The wrong version of this would have been `lookupUsageCounts` followed by
 * a separate increment: that is the race this replaces, with the same
 * single round-trip saved for nothing.
 */
export async function reserveUsage(
  client: RPCClientLike,
  userId: string,
  limits: QuotaLimits,
  now: Date = new Date(),
  deadlineMs = DEFAULT_LOOKUP_DEADLINE_MS,
): Promise<UsageReservation> {
  const call = await callRPCWithDeadline(client, "reserve_ask_usage", {
    p_user_id: userId,
    p_daily_limit: limits.dailyLimit,
    p_monthly_global_limit: limits.monthlyGlobalLimit,
  }, deadlineMs);

  const failOpen = (reason: string, message: string): UsageReservation => {
    console.warn(`quota: reserve_ask_usage ${reason}, failing open: ${message}`);
    return { status: "granted", lease: NO_LEASE, degraded: true };
  };
  if (!call.ok) return failOpen(call.reason, call.message);

  const row = (Array.isArray(call.data) ? call.data[0] : call.data) as
    | { allowed?: unknown; reserved_day?: unknown; today_requests?: unknown; month_requests?: unknown }
    | null
    | undefined;
  if (!row || typeof row.allowed !== "boolean") {
    return failOpen("error", "reserve_ask_usage returned no usable row");
  }

  if (!row.allowed) {
    const result = checkQuota({
      todayRequests: Number(row.today_requests ?? 0),
      monthRequests: Number(row.month_requests ?? 0),
      dailyLimit: limits.dailyLimit,
      monthlyGlobalLimit: limits.monthlyGlobalLimit,
      now,
    });
    return { status: "denied", resetAt: result.resetAt };
  }

  if (typeof row.reserved_day !== "string") {
    // Granted but with no day to settle against: the unit is counted and
    // cannot be adjusted. Let the request run rather than fail it.
    return failOpen("error", "reserve_ask_usage returned no reserved_day");
  }
  return { status: "granted", lease: makeLease(client, userId, row.reserved_day), degraded: false };
}

function makeLease(client: RPCClientLike, userId: string, day: string): UsageLease {
  let finished = false;
  return {
    settle(promptTokens, completionTokens) {
      if (finished) return Promise.resolve();
      finished = true;
      return settleUsage(client, userId, day, promptTokens, completionTokens, false);
    },
    release() {
      if (finished) return Promise.resolve();
      finished = true;
      return settleUsage(client, userId, day, 0, 0, true);
    },
  };
}

/**
 * `settle_ask_usage` with the same 4 s deadline and never-throws rule as
 * `recordUsage`: it runs in the background after the student has their
 * answer (or after they left), so a stall costs one missing token count, or
 * with `refund` one request that stays counted, never a delayed response.
 * `day` is the UTC date the reservation was made on, so a request that
 * straddles midnight adjusts the right row.
 */
export async function settleUsage(
  client: RPCClientLike,
  userId: string,
  day: string,
  promptTokens: number,
  completionTokens: number,
  refund: boolean,
  deadlineMs = DEFAULT_RECORD_DEADLINE_MS,
): Promise<void> {
  const call = await callRPCWithDeadline(client, "settle_ask_usage", {
    p_user_id: userId,
    p_day: day,
    p_prompt_tokens: Math.max(0, Math.floor(promptTokens) || 0),
    p_completion_tokens: Math.max(0, Math.floor(completionTokens) || 0),
    p_refund: refund,
  }, deadlineMs);
  if (!call.ok) {
    console.warn(
      `quota: settle_ask_usage ${call.reason}, ${refund ? "one request stays counted" : "tokens go uncounted"}: ${call.message}`,
    );
  }
}
