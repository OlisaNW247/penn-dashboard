import { strict as assert } from "node:assert";
import {
  checkQuota,
  limitsFromEnv,
  lookupUsageCounts,
  nextUTCMidnight,
  nextUTCMonthStart,
  NO_LEASE,
  quotaDecision,
  recordUsage,
  reserveUsage,
  type RPCClientLike,
  settleUsage,
  type UsageLookup,
} from "../supabase/functions/_shared/quota.ts";

const NOON_JAN_15 = new Date("2026-01-15T12:00:00.000Z");

Deno.test("checkQuota allows a request comfortably under both limits", () => {
  const result = checkQuota({
    todayRequests: 5,
    monthRequests: 500,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.allowed, true);
});

Deno.test("checkQuota denies at exactly the daily limit (boundary is exclusive)", () => {
  const result = checkQuota({
    todayRequests: 40,
    monthRequests: 0,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.allowed, false);
});

Deno.test("checkQuota allows one below the daily limit", () => {
  const result = checkQuota({
    todayRequests: 39,
    monthRequests: 0,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.allowed, true);
});

Deno.test("checkQuota denies at exactly the monthly global limit", () => {
  const result = checkQuota({
    todayRequests: 0,
    monthRequests: 100000,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.allowed, false);
});

Deno.test("checkQuota resetAt is next UTC midnight when the daily limit binds", () => {
  const result = checkQuota({
    todayRequests: 40,
    monthRequests: 0,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.resetAt.toISOString(), "2026-01-16T00:00:00.000Z");
});

Deno.test("checkQuota resetAt is first of next month when only the monthly limit binds", () => {
  const result = checkQuota({
    todayRequests: 0,
    monthRequests: 100000,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.resetAt.toISOString(), "2026-02-01T00:00:00.000Z");
});

Deno.test("checkQuota prefers the sooner daily reset when both limits are exceeded", () => {
  const result = checkQuota({
    todayRequests: 40,
    monthRequests: 100000,
    dailyLimit: 40,
    monthlyGlobalLimit: 100000,
    now: NOON_JAN_15,
  });
  assert.equal(result.allowed, false);
  assert.equal(result.resetAt.toISOString(), "2026-01-16T00:00:00.000Z");
});

Deno.test("nextUTCMidnight rolls over a December 31st into January 1st of the next year", () => {
  const now = new Date("2026-12-31T23:59:59.000Z");
  assert.equal(nextUTCMidnight(now).toISOString(), "2027-01-01T00:00:00.000Z");
});

Deno.test("nextUTCMonthStart rolls December into January of the next year", () => {
  const now = new Date("2026-12-15T08:00:00.000Z");
  assert.equal(nextUTCMonthStart(now).toISOString(), "2027-01-01T00:00:00.000Z");
});

Deno.test("limitsFromEnv falls back to protocol defaults when unset", () => {
  const env = new Map<string, string>();
  const limits = limitsFromEnv({ get: (key) => env.get(key) });
  assert.equal(limits.dailyLimit, 40);
  assert.equal(limits.monthlyGlobalLimit, 100000);
});

Deno.test("limitsFromEnv reads valid overrides", () => {
  const env = new Map([["ASK_DAILY_LIMIT", "10"], ["ASK_MONTHLY_GLOBAL_LIMIT", "500"]]);
  const limits = limitsFromEnv({ get: (key) => env.get(key) });
  assert.equal(limits.dailyLimit, 10);
  assert.equal(limits.monthlyGlobalLimit, 500);
});

Deno.test("limitsFromEnv falls back to defaults on a non-numeric or non-positive override", () => {
  const env = new Map([["ASK_DAILY_LIMIT", "not-a-number"], ["ASK_MONTHLY_GLOBAL_LIMIT", "-5"]]);
  const limits = limitsFromEnv({ get: (key) => env.get(key) });
  assert.equal(limits.dailyLimit, 40);
  assert.equal(limits.monthlyGlobalLimit, 100000);
});

// ---------------------------------------------------------------------
// lookupUsageCounts / quotaDecision / recordUsage
//
// These pin down the 2026-09-13 incident fix: `ask_usage_counts` hitting a
// ~60s PostgREST gateway timeout must never turn into a 502, so the lookup
// gets a short client-side deadline and reports a timeout/error as a value
// rather than throwing, and `quotaDecision` fails a call OPEN whenever the
// lookup couldn't be trusted. The fake client below stands in for
// supabase-js's `.rpc(...).abortSignal(...)` thenable-builder shape.
// ---------------------------------------------------------------------

type RPCOutcome =
  | { kind: "resolve"; data: unknown; error: { message: string } | null }
  | { kind: "reject"; error: unknown }
  | { kind: "hang" };

/** A minimal stand-in for a service-role `SupabaseClient` that only needs
 *  to satisfy `RPCClientLike`: `.rpc(fn, params).abortSignal(signal)`
 *  returning something thenable. `onAbort` lets a test observe that
 *  `lookupUsageCounts`/`recordUsage` actually wired the deadline into the
 *  signal, not just raced a timer alongside an ignored one. */
function fakeRPCClient(outcome: RPCOutcome, onAbort?: () => void): RPCClientLike {
  return {
    rpc(_fn: string, _params: Record<string, unknown>) {
      return {
        abortSignal(signal: AbortSignal) {
          if (onAbort) signal.addEventListener("abort", onAbort);
          switch (outcome.kind) {
            case "resolve":
              return Promise.resolve({ data: outcome.data, error: outcome.error });
            case "reject":
              return Promise.reject(outcome.error);
            case "hang":
              // Never settles -- the only way `lookupUsageCounts`/
              // `recordUsage` can still return is via their own deadline.
              return new Promise(() => {});
          }
        },
      };
    },
  };
}

Deno.test("lookupUsageCounts: times out and aborts the signal when the client never resolves", async () => {
  let aborted = false;
  const client = fakeRPCClient({ kind: "hang" }, () => {
    aborted = true;
  });

  const started = Date.now();
  const result = await lookupUsageCounts(client, "user-1", 50);
  const elapsed = Date.now() - started;

  assert.equal(result.ok, false);
  assert.equal((result as { reason: string }).reason, "timeout");
  // Generous upper bound -- this only needs to prove it didn't wait for
  // something close to PostgREST's ~60s gateway timeout, not pin an exact
  // number under test-runner jitter.
  assert.ok(elapsed < 2000, `expected a fast timeout, took ${elapsed}ms`);
  assert.equal(aborted, true);
});

Deno.test("lookupUsageCounts: reports ok:false reason:error when the rpc resolves with an error", async () => {
  const client = fakeRPCClient({ kind: "resolve", data: null, error: { message: "connection reset" } });
  const result = await lookupUsageCounts(client, "user-1");
  assert.equal(result.ok, false);
  assert.equal((result as { reason: string }).reason, "error");
  assert.equal((result as { message: string }).message, "connection reset");
});

Deno.test("lookupUsageCounts: reports ok:false reason:error when the rpc rejects outright", async () => {
  const client = fakeRPCClient({ kind: "reject", error: new Error("network down") });
  const result = await lookupUsageCounts(client, "user-1");
  assert.equal(result.ok, false);
  assert.equal((result as { reason: string }).reason, "error");
  assert.equal((result as { message: string }).message, "network down");
});

Deno.test("lookupUsageCounts: reads counts from a single-row response", async () => {
  const client = fakeRPCClient({
    kind: "resolve",
    data: { today_requests: 3, month_requests: 4000 },
    error: null,
  });
  const result = await lookupUsageCounts(client, "user-1");
  assert.equal(result.ok, true);
  assert.deepEqual((result as { counts: unknown }).counts, { todayRequests: 3, monthRequests: 4000 });
});

Deno.test("lookupUsageCounts: reads counts from an array response (postgrest's actual RPC shape)", async () => {
  const client = fakeRPCClient({
    kind: "resolve",
    data: [{ today_requests: 7, month_requests: 12000 }],
    error: null,
  });
  const result = await lookupUsageCounts(client, "user-1");
  assert.equal(result.ok, true);
  assert.deepEqual((result as { counts: unknown }).counts, { todayRequests: 7, monthRequests: 12000 });
});

Deno.test("lookupUsageCounts: defaults missing counts to zero", async () => {
  const client = fakeRPCClient({ kind: "resolve", data: [], error: null });
  const result = await lookupUsageCounts(client, "user-1");
  assert.equal(result.ok, true);
  assert.deepEqual((result as { counts: unknown }).counts, { todayRequests: 0, monthRequests: 0 });
});

const LIMITS = { dailyLimit: 40, monthlyGlobalLimit: 100000 };

Deno.test("quotaDecision: fails open (allowed, degraded) when the lookup is ok:false", () => {
  const lookup: UsageLookup = { ok: false, reason: "timeout", message: "ask_usage_counts exceeded 4000ms deadline" };
  const decision = quotaDecision(lookup, LIMITS, NOON_JAN_15);
  assert.deepEqual(decision, { allowed: true, degraded: true });
});

Deno.test("quotaDecision: a successful lookup over the daily limit still blocks", () => {
  const lookup: UsageLookup = { ok: true, counts: { todayRequests: 40, monthRequests: 0 } };
  const decision = quotaDecision(lookup, LIMITS, NOON_JAN_15);
  assert.equal(decision.allowed, false);
  assert.equal((decision as { resetAt: Date }).resetAt.toISOString(), "2026-01-16T00:00:00.000Z");
});

Deno.test("quotaDecision: a successful lookup under both limits allows, not degraded", () => {
  const lookup: UsageLookup = { ok: true, counts: { todayRequests: 5, monthRequests: 500 } };
  const decision = quotaDecision(lookup, LIMITS, NOON_JAN_15);
  assert.deepEqual(decision, { allowed: true, degraded: false });
});

Deno.test("recordUsage: never throws when the rpc resolves with an error", async () => {
  const client = fakeRPCClient({ kind: "resolve", data: null, error: { message: "write failed" } });
  await recordUsage(client, "user-1", 10, 20);
});

Deno.test("recordUsage: never throws when the rpc rejects outright", async () => {
  const client = fakeRPCClient({ kind: "reject", error: new Error("network down") });
  await recordUsage(client, "user-1", 10, 20);
});

Deno.test("recordUsage: never throws and returns promptly when the rpc hangs past the deadline", async () => {
  const client = fakeRPCClient({ kind: "hang" });
  const started = Date.now();
  await recordUsage(client, "user-1", 10, 20, 50);
  assert.ok(Date.now() - started < 2000);
});

// ---------------------------------------------------------------------
// reserveUsage / settleUsage / UsageLease (hardening BE-C)
//
// The reservation is one RPC that checks and charges together
// (`reserve_ask_usage`), and a lease settles it exactly once afterwards.
// The SQL half is pinned by test/rls.test.sql; these pin the client half:
// what is sent, how each answer is read, and that every way the call can
// fail leaves the request running (fail open) rather than refused.
// ---------------------------------------------------------------------

type Recorded = { fn: string; params: Record<string, unknown>; signal?: AbortSignal };

/** A fake service client that answers per function name and records every
 *  call, so a test can assert both what came back and what was sent. */
function recordingClient(
  answers: Record<string, RPCOutcome>,
): { client: RPCClientLike; calls: Recorded[] } {
  const calls: Recorded[] = [];
  const client: RPCClientLike = {
    rpc(fn: string, params: Record<string, unknown>) {
      const call: Recorded = { fn, params };
      calls.push(call);
      return {
        abortSignal(signal: AbortSignal) {
          call.signal = signal;
          const outcome = answers[fn] ?? { kind: "resolve", data: null, error: null };
          switch (outcome.kind) {
            case "resolve":
              return Promise.resolve({ data: outcome.data, error: outcome.error });
            case "reject":
              return Promise.reject(outcome.error);
            case "hang":
              return new Promise(() => {});
          }
        },
      };
    },
  };
  return { client, calls };
}

const GRANTED_ROW = { allowed: true, reserved_day: "2026-01-15", today_requests: 5, month_requests: 900 };

Deno.test("reserveUsage: sends the user, the daily limit and the monthly limit, and grants with a live lease", async () => {
  const { client, calls } = recordingClient({ reserve_ask_usage: { kind: "resolve", data: [GRANTED_ROW], error: null } });
  const reservation = await reserveUsage(client, "user-1", { dailyLimit: 40, monthlyGlobalLimit: 100000 }, NOON_JAN_15);
  assert.equal(reservation.status, "granted");
  assert.equal((reservation as { degraded: boolean }).degraded, false);
  assert.notEqual((reservation as { lease: unknown }).lease, NO_LEASE);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].fn, "reserve_ask_usage");
  assert.deepEqual(calls[0].params, { p_user_id: "user-1", p_daily_limit: 40, p_monthly_global_limit: 100000 });
});

Deno.test("reserveUsage: reads a single-object response as well as PostgREST's array", async () => {
  const { client } = recordingClient({ reserve_ask_usage: { kind: "resolve", data: GRANTED_ROW, error: null } });
  const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15);
  assert.equal(reservation.status, "granted");
  assert.equal((reservation as { degraded: boolean }).degraded, false);
});

Deno.test("reserveUsage: denied at the daily limit resets at the next UTC midnight", async () => {
  const { client } = recordingClient({
    reserve_ask_usage: {
      kind: "resolve",
      data: [{ allowed: false, reserved_day: "2026-01-15", today_requests: 40, month_requests: 500 }],
      error: null,
    },
  });
  const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15);
  assert.equal(reservation.status, "denied");
  assert.equal((reservation as { resetAt: Date }).resetAt.toISOString(), "2026-01-16T00:00:00.000Z");
});

Deno.test("reserveUsage: denied at the monthly limit alone resets on the first of next month", async () => {
  const { client } = recordingClient({
    reserve_ask_usage: {
      kind: "resolve",
      data: [{ allowed: false, reserved_day: "2026-01-15", today_requests: 3, month_requests: 100000 }],
      error: null,
    },
  });
  const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15);
  assert.equal(reservation.status, "denied");
  assert.equal((reservation as { resetAt: Date }).resetAt.toISOString(), "2026-02-01T00:00:00.000Z");
});

Deno.test("reserveUsage: fails open on an rpc error, a rejection and a malformed answer, with no lease to settle", async () => {
  const answers: RPCOutcome[] = [
    { kind: "resolve", data: null, error: { message: "Gateway Timeout" } },
    { kind: "reject", error: new Error("network down") },
    { kind: "resolve", data: [], error: null },
    { kind: "resolve", data: [{ today_requests: 1 }], error: null },
    // Granted, but with no day a settle could target.
    { kind: "resolve", data: [{ allowed: true, today_requests: 1, month_requests: 1 }], error: null },
  ];
  for (const outcome of answers) {
    const { client, calls } = recordingClient({ reserve_ask_usage: outcome });
    const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15);
    assert.equal(reservation.status, "granted");
    assert.equal((reservation as { degraded: boolean }).degraded, true);
    const lease = (reservation as { lease: { settle(a: number, b: number): Promise<void>; release(): Promise<void> } }).lease;
    await lease.settle(10, 10);
    await lease.release();
    assert.equal(calls.length, 1, "an unmetered request has nothing to settle, so no second rpc");
  }
});

Deno.test("reserveUsage: fails open within the deadline when the rpc hangs, and aborts it (quota fails open at 1.5 s)", async () => {
  const { client, calls } = recordingClient({ reserve_ask_usage: { kind: "hang" } });
  const started = Date.now();
  const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15, 50);
  assert.ok(Date.now() - started < 2000);
  assert.equal(reservation.status, "granted");
  assert.equal((reservation as { degraded: boolean }).degraded, true);
  assert.equal(calls[0].signal?.aborted, true);
});

Deno.test("the lease settles tokens once, against the day the reservation was made", async () => {
  const { client, calls } = recordingClient({ reserve_ask_usage: { kind: "resolve", data: [GRANTED_ROW], error: null } });
  const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15);
  const lease = (reservation as { lease: { settle(a: number, b: number): Promise<void>; release(): Promise<void> } }).lease;
  await lease.settle(120, 45);
  await lease.settle(999, 999);
  await lease.release();
  assert.equal(calls.length, 2);
  assert.equal(calls[1].fn, "settle_ask_usage");
  assert.deepEqual(calls[1].params, {
    p_user_id: "user-1",
    p_day: "2026-01-15",
    p_prompt_tokens: 120,
    p_completion_tokens: 45,
    p_refund: false,
  });
});

Deno.test("the lease gives the request back once, and never after it was settled", async () => {
  const { client, calls } = recordingClient({ reserve_ask_usage: { kind: "resolve", data: [GRANTED_ROW], error: null } });
  const reservation = await reserveUsage(client, "user-1", LIMITS, NOON_JAN_15);
  const lease = (reservation as { lease: { settle(a: number, b: number): Promise<void>; release(): Promise<void> } }).lease;
  await lease.release();
  await lease.release();
  await lease.settle(5, 5);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].params.p_refund, true);
  assert.equal(calls[1].params.p_prompt_tokens, 0);

  const second = recordingClient({ reserve_ask_usage: { kind: "resolve", data: [GRANTED_ROW], error: null } });
  const settledFirst = (await reserveUsage(second.client, "user-1", LIMITS, NOON_JAN_15)) as {
    lease: { settle(a: number, b: number): Promise<void>; release(): Promise<void> };
  };
  await settledFirst.lease.settle(1, 1);
  await settledFirst.lease.release();
  assert.equal(second.calls.length, 2, "a release after a settle must not refund");
  assert.equal(second.calls[1].params.p_refund, false);
});

Deno.test("settleUsage: never throws, whatever the rpc does, and returns promptly when it hangs", async () => {
  await settleUsage(recordingClient({ settle_ask_usage: { kind: "resolve", data: null, error: { message: "write failed" } } }).client, "u", "2026-01-15", 1, 1, false);
  await settleUsage(recordingClient({ settle_ask_usage: { kind: "reject", error: new Error("network down") } }).client, "u", "2026-01-15", 1, 1, true);
  const started = Date.now();
  await settleUsage(recordingClient({ settle_ask_usage: { kind: "hang" } }).client, "u", "2026-01-15", 1, 1, false, 50);
  assert.ok(Date.now() - started < 2000);
});

Deno.test("settleUsage: negative, fractional and NaN token counts are sent as non-negative integers", async () => {
  const { client, calls } = recordingClient({});
  await settleUsage(client, "u", "2026-01-15", -5, 12.9, false);
  await settleUsage(client, "u", "2026-01-15", Number.NaN, Number.POSITIVE_INFINITY * 0, false);
  assert.equal(calls[0].params.p_prompt_tokens, 0);
  assert.equal(calls[0].params.p_completion_tokens, 12);
  assert.equal(calls[1].params.p_prompt_tokens, 0);
  assert.equal(calls[1].params.p_completion_tokens, 0);
});
