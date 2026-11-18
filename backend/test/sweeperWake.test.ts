// The Sweeper wake's rules: what a phone may upload, the memory store's claim
// (once, never twice, two minutes forgiven), pruning, and the tick's handling
// of every answer Apple can give.
import { strict as assert } from "node:assert";
import {
  type ApnsSender,
  type ClaimedRow,
  MemorySweeperWakeStore,
  runTick,
  validateWakeBody,
} from "../supabase/functions/_shared/sweeperWake.ts";
import type { ApnsEnvironment, ApnsOutcome, ApnsResult } from "../supabase/functions/_shared/apns.ts";

const NOW = new Date("2026-11-20T04:30:20.000Z");
const TOKEN = "ab".repeat(32);
const good = (over: Record<string, unknown> = {}) => ({
  action: "put",
  token: TOKEN,
  environment: "production",
  moments: ["2026-11-20T04:34:00Z"],
  plan: "0123456789abcdef",
  ...over,
});

Deno.test("validate: a good body, lowercased and truncated to the minute", () => {
  const r = validateWakeBody(good({ token: TOKEN.toUpperCase(), moments: ["2026-11-20T04:46:59.999Z", "2026-11-20T04:34:30Z"], plan: "0123456789ABCDEF" }), NOW);
  assert.ok(r.ok);
  assert.strictEqual(r.value.token, TOKEN);
  assert.deepStrictEqual(r.value.moments.map((m) => m.toISOString()), ["2026-11-20T04:34:00.000Z", "2026-11-20T04:46:00.000Z"]);
  assert.strictEqual(r.value.planHash, "0123456789abcdef");
});

Deno.test("validate: refusals, each with its own reason", () => {
  const why = (body: unknown) => {
    const r = validateWakeBody(body, NOW);
    return r.ok ? "ok" : r.reason;
  };
  assert.strictEqual(why(good({ assignment_id: "x" })), "forbidden_field");
  assert.strictEqual(why(good({ title: "HW3" })), "forbidden_field");
  assert.strictEqual(why(good({ token: "abc" })), "invalid_token");
  assert.strictEqual(why(good({ token: "g".repeat(64) })), "invalid_token");
  assert.strictEqual(why(good({ token: "a".repeat(201) })), "invalid_token");
  assert.strictEqual(why(good({ token: "a".repeat(64) })), "ok");
  assert.strictEqual(why(good({ token: "a".repeat(200) })), "ok");
  assert.strictEqual(why(good({ environment: "staging" })), "invalid_environment");
  assert.strictEqual(why(good({ moments: "2026-11-20T04:34:00Z" })), "invalid_moments");
  assert.strictEqual(why(good({ moments: [12345] })), "invalid_moment");
  assert.strictEqual(why(good({ moments: ["not a date"] })), "invalid_moment");
  assert.strictEqual(why(good({ plan: "xyz" })), "invalid_plan");
  assert.strictEqual(why(good({ plan: 12 })), "invalid_plan");
  assert.strictEqual(why(null), "invalid_body");
  assert.strictEqual(why([]), "invalid_body");
  assert.strictEqual(why("x"), "invalid_body");
});

Deno.test("validate: 24 moments pass, 25 are refused, even if some are past", () => {
  const mk = (n: number) => Array.from({ length: n }, (_, i) => new Date(NOW.getTime() + (i + 2) * 60_000).toISOString());
  const ok = validateWakeBody(good({ moments: mk(24) }), NOW);
  assert.ok(ok.ok);
  assert.strictEqual(ok.value.moments.length, 24);
  const r = validateWakeBody(good({ moments: mk(25) }), NOW);
  assert.ok(!r.ok);
  assert.strictEqual(r.reason, "too_many_moments");
});

Deno.test("validate: past moments are dropped silently, the horizon is 48 hours", () => {
  const r = validateWakeBody(good({ moments: ["2026-11-20T04:00:00Z", "2026-11-20T04:30:00Z", "2026-11-20T04:31:00Z"] }), NOW);
  assert.ok(r.ok);
  assert.deepStrictEqual(r.value.moments.map((m) => m.toISOString()), ["2026-11-20T04:31:00.000Z"]);
  const edge = new Date(Math.floor(NOW.getTime() / 60_000) * 60_000 + 48 * 3600_000);
  assert.ok(validateWakeBody(good({ moments: [edge.toISOString()] }), NOW).ok);
  const beyond = validateWakeBody(good({ moments: [new Date(edge.getTime() + 60_000).toISOString()] }), NOW);
  assert.ok(!beyond.ok);
  assert.strictEqual(beyond.reason, "moment_beyond_horizon");
  const three = validateWakeBody(good({ moments: ["2026-11-23T04:34:00Z"] }), NOW);
  assert.ok(!three.ok && three.reason === "moment_beyond_horizon");
  // Duplicates after truncation collapse, and an empty list is a valid "nothing to wake for".
  const dup = validateWakeBody(good({ moments: ["2026-11-20T04:34:10Z", "2026-11-20T04:34:50Z"] }), NOW);
  assert.ok(dup.ok && dup.value.moments.length === 1);
  assert.ok(validateWakeBody(good({ moments: [] }), NOW).ok);
  // The plan is optional.
  const noPlan = validateWakeBody({ token: TOKEN, environment: "development", moments: [] }, NOW);
  assert.ok(noPlan.ok && noPlan.value.planHash === undefined);
});

const at = (iso: string) => new Date(iso);
const row = (token: string, moments: string[], over: { userId?: string; environment?: ApnsEnvironment } = {}) => ({
  token,
  userId: over.userId ?? "u1",
  environment: over.environment ?? ("production" as ApnsEnvironment),
  moments: moments.map(at),
});

Deno.test("memory store: a row is claimed once for its minute, never twice", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("t1", ["2026-11-20T04:34:00Z", "2026-11-20T04:46:00Z"]));
  assert.strictEqual((await store.claim(at("2026-11-20T04:33:00Z"), 10)).length, 0);
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 10)).length, 1);
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 10)).length, 0);
  assert.strictEqual((await store.claim(at("2026-11-20T04:46:00Z"), 10)).length, 1);
  // An older minute cannot be claimed again after a newer one.
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 10)).length, 0);
});

Deno.test("memory store: the limit bounds a claim, upsert keeps last_sent_for, delete is per user", async () => {
  const store = new MemorySweeperWakeStore();
  for (const t of ["a", "b", "c"]) await store.upsert(row(t, ["2026-11-20T04:34:00Z"], { userId: t === "c" ? "u2" : "u1" }));
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 2)).length, 2);
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 2)).length, 1);
  await store.upsert(row("a", ["2026-11-20T04:34:00Z"])); // a re-upload does not re-arm a sent moment
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 5)).length, 0);
  assert.strictEqual(await store.deleteForUser("u1"), 2);
  assert.deepStrictEqual([...store.rows.keys()], ["c"]);
});

Deno.test("memory store: prune drops old moments from the named rows only", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:00:00Z", "2026-11-20T04:25:00Z", "2026-11-20T05:00:00Z"]));
  await store.upsert(row("b", ["2026-11-20T04:00:00Z"]));
  await store.pruneMoments(at("2026-11-20T04:20:00Z"), ["a"]);
  assert.deepStrictEqual(store.rows.get("a")!.moments.map((m) => m.toISOString()), ["2026-11-20T04:25:00.000Z", "2026-11-20T05:00:00.000Z"]);
  assert.strictEqual(store.rows.get("b")!.moments.length, 1);
});

// ---- the tick ----

function fakeApns(script: (row: ClaimedRow, call: number) => ApnsResult | Error) {
  const calls: string[] = [];
  const forgot: string[] = [];
  const perToken = new Map<string, number>();
  const sender: ApnsSender = {
    send: (r) => {
      calls.push(r.token);
      const n = (perToken.get(r.token) ?? 0) + 1;
      perToken.set(r.token, n);
      const answer = script(r, n);
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
    },
    forget: (e) => {
      forgot.push(e);
    },
  };
  return { sender, calls, forgot };
}
const answer = (status: number, outcome: ApnsOutcome, reason?: string): ApnsResult => ({ status, outcome, ...(reason ? { reason } : {}) });

async function tickWith(store: MemorySweeperWakeStore, apns: ApnsSender, nowIso = "2026-11-20T04:34:20Z", extra: Record<string, unknown> = {}) {
  const lines: string[] = [];
  const counts = await runTick({ store, apns, now: () => Date.parse(nowIso), log: (l) => lines.push(l), ...extra });
  return { counts, lines };
}

Deno.test("tick: disabled does nothing", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z"]));
  const f = fakeApns(() => answer(200, "ok"));
  const { counts } = await tickWith(store, f.sender, undefined, { disabled: true });
  assert.strictEqual(counts.disabled, true);
  assert.strictEqual(f.calls.length, 0);
  assert.strictEqual((await store.claim(at("2026-11-20T04:34:00Z"), 5)).length, 1); // nothing was claimed
});

Deno.test("tick: counts, the log line, idempotence, the late minute and the pruning", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z", "2026-11-20T04:20:00Z"]));
  await store.upsert(row("late", ["2026-11-20T04:33:00Z"]));
  await store.upsert(row("later", ["2026-11-20T04:50:00Z"]));
  const f = fakeApns(() => answer(200, "ok"));
  const { counts, lines } = await tickWith(store, f.sender);
  assert.strictEqual(counts.claimed, 2); // `a` for this minute, `late` for the minute before
  assert.strictEqual(counts.sent, 2);
  assert.deepStrictEqual(counts.byStatus, { "200": 2 });
  assert.strictEqual(counts.deleted, 0);
  assert.deepStrictEqual(f.calls.sort(), ["a", "late"]);
  assert.strictEqual(lines.length, 1);
  assert.match(lines[0], /^sweeper-wake tick 2026-11-20T04:34:00\.000Z: claimed 2, sent 2, status \{"200":2\}, deleted 0, took \d+ ms$/);
  assert.ok(!/[0-9a-f]{64}/.test(lines[0]), "no token in the log line");
  // 04:20 is more than five minutes old: pruned from the claimed row only.
  assert.deepStrictEqual(store.rows.get("a")!.moments.map((m) => m.toISOString()), ["2026-11-20T04:34:00.000Z"]);
  // A second tick in the same minute sends nothing.
  const again = await tickWith(store, f.sender);
  assert.strictEqual(again.counts.claimed, 0);
  assert.strictEqual(f.calls.length, 2);
});

Deno.test("tick: a row with moments in both minutes is sent to once", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:33:00Z", "2026-11-20T04:34:00Z"]));
  const f = fakeApns(() => answer(200, "ok"));
  const { counts } = await tickWith(store, f.sender);
  assert.strictEqual(counts.claimed, 1);
  assert.strictEqual(f.calls.length, 1);
});

Deno.test("tick: a 403 remints once and retries that send; a second 403 fails the tick loudly", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z"]));
  const f = fakeApns((_r, n) => (n === 1 ? answer(403, "remint", "ExpiredProviderToken") : answer(200, "ok")));
  const { counts } = await tickWith(store, f.sender);
  assert.deepStrictEqual(f.forgot, ["production"]);
  assert.strictEqual(f.calls.length, 2);
  assert.deepStrictEqual(counts.byStatus, { "200": 1 });

  const store2 = new MemorySweeperWakeStore();
  await store2.upsert(row("b", ["2026-11-20T04:34:00Z"]));
  const bad = fakeApns(() => answer(403, "remint", "InvalidProviderToken"));
  const lines: string[] = [];
  await assert.rejects(
    runTick({ store: store2, apns: bad.sender, now: () => Date.parse("2026-11-20T04:34:20Z"), log: (l) => lines.push(l) }),
    /provider token/,
  );
  assert.strictEqual(bad.calls.length, 2);
  assert.ok(lines.some((l) => /FAILED/.test(l)));
  assert.ok(store2.rows.has("b"), "a wrong key must not delete anyone's row");
});

Deno.test("tick: many sends seeing a 403 at once forget the token once per environment", async () => {
  const store = new MemorySweeperWakeStore();
  for (const t of ["a", "b", "c", "d"]) await store.upsert(row(t, ["2026-11-20T04:34:00Z"]));
  const f = fakeApns((_r, n) => (n === 1 ? answer(403, "remint") : answer(200, "ok")));
  await tickWith(store, f.sender);
  assert.deepStrictEqual(f.forgot, ["production"]);
});

Deno.test("tick: TooManyProviderTokenUpdates fails loudly", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z"]));
  const f = fakeApns(() => answer(429, "providerTokenAbuse", "TooManyProviderTokenUpdates"));
  await assert.rejects(tickWith(store, f.sender), /too often/);
});

Deno.test("tick: 410 deletes the row at once", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z"]));
  const f = fakeApns(() => answer(410, "unregistered", "Unregistered"));
  const { counts } = await tickWith(store, f.sender);
  assert.strictEqual(counts.deleted, 1);
  assert.strictEqual(store.rows.size, 0);
});

Deno.test("tick: three failures delete the row; fewer, or an upload, keep it", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z", "2026-11-20T04:35:00Z", "2026-11-20T04:36:00Z", "2026-11-20T04:37:00Z"]));
  const f = fakeApns(() => answer(400, "badToken", "BadDeviceToken"));
  await tickWith(store, f.sender, "2026-11-20T04:34:20Z");
  assert.strictEqual(store.rows.get("a")!.failures, 1);
  await tickWith(store, f.sender, "2026-11-20T04:35:20Z");
  assert.strictEqual(store.rows.get("a")!.failures, 2);
  await store.upsert(row("a", ["2026-11-20T04:36:00Z", "2026-11-20T04:37:00Z"])); // the phone uploads again: the count starts over
  assert.strictEqual(store.rows.get("a")!.failures, 0);
  await tickWith(store, f.sender, "2026-11-20T04:36:20Z");
  await tickWith(store, f.sender, "2026-11-20T04:37:20Z");
  assert.strictEqual(store.rows.get("a")!.failures, 2);

  const doomed = new MemorySweeperWakeStore();
  await doomed.upsert(row("z", ["2026-11-20T04:34:00Z", "2026-11-20T04:35:00Z", "2026-11-20T04:36:00Z"]));
  const server = fakeApns(() => answer(503, "serverError"));
  await tickWith(doomed, server.sender, "2026-11-20T04:34:20Z");
  await tickWith(doomed, server.sender, "2026-11-20T04:35:20Z");
  const last = await tickWith(doomed, server.sender, "2026-11-20T04:36:20Z");
  assert.strictEqual(last.counts.deleted, 1);
  assert.strictEqual(doomed.rows.size, 0);
});

Deno.test("tick: 429 leaves the row alone, a connection failure or a missing secret does not count against it", async () => {
  const store = new MemorySweeperWakeStore();
  await store.upsert(row("a", ["2026-11-20T04:34:00Z"]));
  await store.upsert(row("b", ["2026-11-20T04:34:00Z"]));
  await store.upsert(row("c", ["2026-11-20T04:34:00Z"]));
  const f = fakeApns((r) =>
    r.token === "a" ? answer(429, "tooMany", "TooManyRequests") : r.token === "b" ? answer(0, "failed", "TypeError") : new Error("missing function secret LHF_APNS_KEY_ID_SANDBOX")
  );
  const { counts, lines } = await tickWith(store, f.sender);
  assert.strictEqual(store.rows.size, 3);
  for (const r of store.rows.values()) assert.strictEqual(r.failures, 0);
  assert.strictEqual(counts.byStatus.error, 1);
  assert.ok(lines.some((l) => l.includes("LHF_APNS_KEY_ID_SANDBOX")));
});

Deno.test("tick: concurrency is bounded and onClaimed fires before any send", async () => {
  const store = new MemorySweeperWakeStore();
  for (let i = 0; i < 10; i++) await store.upsert(row(`t${i}`, ["2026-11-20T04:34:00Z"]));
  let inFlight = 0;
  let peak = 0;
  let sendsWhenClaimed = -1;
  let started = 0;
  const sender: ApnsSender = {
    send: async () => {
      started++;
      inFlight++;
      peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight--;
      return answer(200, "ok");
    },
    forget: () => {},
  };
  await tickWith(store, sender, undefined, { concurrency: 3, onClaimed: () => (sendsWhenClaimed = started) });
  assert.strictEqual(peak, 3);
  assert.strictEqual(sendsWhenClaimed, 0);
});
