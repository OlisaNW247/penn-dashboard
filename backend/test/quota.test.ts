import { strict as assert } from "node:assert";
import {
  checkQuota,
  limitsFromEnv,
  lookupUsageCounts,
  nextUTCMidnight,
  nextUTCMonthStart,
  quotaDecision,
  recordUsage,
  type RPCClientLike,
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
