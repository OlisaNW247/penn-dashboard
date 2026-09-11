// Quota bookkeeping is deliberately split from the SQL that stores the raw
// counters (see the migration's `ask_usage_counts` / `record_ask_usage`
// functions). This file is pure arithmetic over numbers a caller already
// fetched, on purpose: quota policy -- what "over quota" means, when it
// resets -- is exactly the kind of logic that benefits from being testable
// with a plain object and a `Date`, with no Postgres, no `Deno.env`, no
// network anywhere near the test.

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
