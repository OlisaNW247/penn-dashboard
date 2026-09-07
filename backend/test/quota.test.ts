import { strict as assert } from "node:assert";
import { checkQuota, limitsFromEnv, nextUTCMidnight, nextUTCMonthStart } from "../supabase/functions/_shared/quota.ts";

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
