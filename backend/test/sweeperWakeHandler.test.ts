// The three routes of `sweeper-wake` against a memory store and a fake APNs:
// the student's put and delete (version header required, bearer verified, the
// body's keys policed) and pg_cron's tick (its own secret, the kill switch,
// answering before the sends finish).
import { strict as assert } from "node:assert";
import { handleSweeperWake, type SweeperWakeDeps } from "../supabase/functions/sweeper-wake/index.ts";
import { MemorySweeperWakeStore, type ApnsSender } from "../supabase/functions/_shared/sweeperWake.ts";
import { resetVersionCache } from "../supabase/functions/_shared/version.ts";
import { GRANTED, installStub, USER_ID } from "./support/edgeStub.ts";

const NOW = new Date("2026-11-20T04:30:20.000Z");
const TOKEN = "cd".repeat(32);
const MANIFEST = () => Promise.resolve(new Response(JSON.stringify({ minimumVersion: "3.4.1" })));

function fakeSender(onSend: () => Promise<void> | void = () => {}) {
  const sent: string[] = [];
  const apns: ApnsSender = {
    send: async (row) => {
      sent.push(row.token);
      await onSend();
      return { status: 200, outcome: "ok" };
    },
    forget: () => {},
  };
  return { apns, sent };
}

async function withHandler(
  run: (ctx: {
    student: (body: unknown, headers?: Record<string, string>) => Promise<Response>;
    tick: (headers?: Record<string, string>) => Promise<Response>;
    store: MemorySweeperWakeStore;
    sent: string[];
    setEnv: (k: string, v: string | undefined) => void;
  }) => Promise<void>,
  opts: { onSend?: () => Promise<void> | void; waitUntil?: SweeperWakeDeps["waitUntil"] } = {},
) {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "fail", status: 500 } });
  resetVersionCache();
  try {
    const store = new MemorySweeperWakeStore();
    const { apns, sent } = fakeSender(opts.onSend);
    const vars: Record<string, string | undefined> = { LHF_SWEEPER_TICK_SECRET: "tick-secret-value" };
    const deps: SweeperWakeDeps = {
      store,
      apns,
      now: () => NOW,
      env: (k) => vars[k],
      version: { fetchFn: MANIFEST as unknown as typeof fetch },
      waitUntil: opts.waitUntil,
    };
    const student = (body: unknown, headers: Record<string, string> = { "x-smooth-version": "3.5.0" }) =>
      handleSweeperWake(
        new Request("http://edge.test/functions/v1/sweeper-wake", {
          method: "POST",
          headers: { authorization: "Bearer user-jwt", "content-type": "application/json", ...headers },
          body: typeof body === "string" ? body : JSON.stringify(body),
        }),
        deps,
      );
    const tick = (headers: Record<string, string> = { "x-sweeper-tick-secret": "tick-secret-value" }) =>
      handleSweeperWake(new Request("http://edge.test/functions/v1/sweeper-wake/tick", { method: "POST", headers, body: "{}" }), deps);
    await run({ student, tick, store, sent, setEnv: (k, v) => void (vars[k] = v) });
  } finally {
    resetVersionCache();
    stub.restore();
  }
}

const put = (over: Record<string, unknown> = {}) => ({
  action: "put",
  token: TOKEN,
  environment: "production",
  moments: ["2026-11-20T04:46:00Z", "2026-11-20T04:34:00Z"],
  plan: "0123456789abcdef",
  ...over,
});

Deno.test("sweeper-wake: put stores the row for the caller and answers the next moment", async () => {
  await withHandler(async ({ student, store }) => {
    const res = await student(put());
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(await res.json(), { stored: 2, nextMoment: "2026-11-20T04:34:00.000Z" });
    const row = store.rows.get(TOKEN)!;
    assert.strictEqual(row.userId, USER_ID);
    assert.strictEqual(row.environment, "production");
    assert.strictEqual(row.planHash, "0123456789abcdef");
    // A token that moves to another account follows the new owner (same user here; replaced, not duplicated).
    await student(put({ moments: [] }));
    assert.strictEqual(store.rows.size, 1);
    const empty = await student(put({ moments: [] }));
    assert.deepStrictEqual(await empty.json(), { stored: 0, nextMoment: null });
  });
});

Deno.test("sweeper-wake: delete removes every row of the caller", async () => {
  await withHandler(async ({ student, store }) => {
    await student(put());
    await student(put({ token: "ef".repeat(32) }));
    await store.upsert({ token: "other", userId: "someone-else", environment: "production", moments: [] });
    const res = await student({ action: "delete" });
    assert.deepStrictEqual(await res.json(), { deleted: 2 });
    assert.deepStrictEqual([...store.rows.keys()], ["other"]);
  });
});

Deno.test("sweeper-wake: refusals are 400 with the reason, and nothing is written", async () => {
  await withHandler(async ({ student, store }) => {
    const forbidden = await student(put({ assignment_id: "a1" }));
    assert.strictEqual(forbidden.status, 400);
    assert.deepStrictEqual(await forbidden.json(), { error: "bad_request", message: "forbidden_field" });

    const many = await student(put({ moments: Array.from({ length: 25 }, (_, i) => new Date(NOW.getTime() + (i + 2) * 60_000).toISOString()) }));
    assert.strictEqual(many.status, 400);
    assert.strictEqual((await many.json()).message, "too_many_moments");

    const far = await student(put({ moments: ["2026-11-23T04:34:00Z"] }));
    assert.strictEqual(far.status, 400);
    assert.strictEqual((await far.json()).message, "moment_beyond_horizon");

    const delExtra = await student({ action: "delete", assignment_id: "x" });
    assert.strictEqual(delExtra.status, 400);
    assert.strictEqual((await delExtra.json()).message, "forbidden_field");
    const notJSON = await student("{nope");
    assert.strictEqual(notJSON.status, 400);
    const noAction = await student({ token: TOKEN });
    assert.strictEqual(noAction.status, 400);
    assert.strictEqual(store.rows.size, 0);
  });
});

Deno.test("sweeper-wake: no bearer is 401; a missing version header is 426; a version below the floor is 426", async () => {
  await withHandler(async ({ student }) => {
    const none = await handleSweeperWake(
      new Request("http://edge.test/sweeper-wake", { method: "POST", headers: { "x-smooth-version": "3.5.0" }, body: "{}" }),
      { store: new MemorySweeperWakeStore(), apns: fakeSender().apns, env: () => undefined, version: { fetchFn: MANIFEST as unknown as typeof fetch } },
    );
    assert.strictEqual(none.status, 401);
    const noHeader = await student(put(), {});
    assert.strictEqual(noHeader.status, 426);
    const old = await student(put(), { "x-smooth-version": "3.4.0" });
    assert.strictEqual(old.status, 426);
    const ok = await student(put(), { "x-smooth-version": "3.4.1" });
    assert.strictEqual(ok.status, 200);
  });
});

Deno.test("sweeper-wake: the kill switch makes put a no-op that says so", async () => {
  await withHandler(async ({ student, store, setEnv }) => {
    setEnv("LHF_SWEEPER_WAKE_DISABLED", "1");
    const res = await student(put());
    assert.deepStrictEqual(await res.json(), { stored: 0, disabled: true });
    assert.strictEqual(store.rows.size, 0);
    // A bad body is still refused: a client bug must show even while the switch is on.
    assert.strictEqual((await student(put({ assignment_id: "x" }))).status, 400);
  });
});

Deno.test("sweeper-wake: GET is 405, OPTIONS is 204", async () => {
  await withHandler(async () => {
    const deps = { store: new MemorySweeperWakeStore(), apns: fakeSender().apns, env: () => undefined };
    assert.strictEqual((await handleSweeperWake(new Request("http://edge.test/sweeper-wake"), deps)).status, 405);
    assert.strictEqual((await handleSweeperWake(new Request("http://edge.test/sweeper-wake/tick"), deps)).status, 405);
    assert.strictEqual((await handleSweeperWake(new Request("http://edge.test/sweeper-wake", { method: "OPTIONS" }), deps)).status, 204);
  });
});

Deno.test("sweeper-wake: /tick refuses a wrong, missing or unconfigured secret", async () => {
  await withHandler(async ({ tick, store, sent, setEnv }) => {
    await store.upsert({ token: TOKEN, userId: USER_ID, environment: "production", moments: [new Date("2026-11-20T04:30:00Z")] });
    assert.strictEqual((await tick({ "x-sweeper-tick-secret": "wrong" })).status, 403);
    assert.strictEqual((await tick({})).status, 403);
    assert.strictEqual((await tick({ authorization: "Bearer user-jwt" })).status, 403);
    setEnv("LHF_SWEEPER_TICK_SECRET", undefined);
    assert.strictEqual((await tick({ "x-sweeper-tick-secret": "tick-secret-value" })).status, 403);
    assert.strictEqual((await tick({ "x-sweeper-tick-secret": "" })).status, 403);
    assert.strictEqual(sent.length, 0);
  });
});

Deno.test("sweeper-wake: /tick claims, sends, and answers 202 with the count", async () => {
  await withHandler(async ({ tick, store, sent }) => {
    await store.upsert({ token: TOKEN, userId: USER_ID, environment: "production", moments: [new Date("2026-11-20T04:30:00Z")] });
    const res = await tick();
    assert.strictEqual(res.status, 202);
    assert.deepStrictEqual(await res.json(), { claimed: 1 });
    assert.deepStrictEqual(sent, [TOKEN]);
    const second = await tick();
    assert.deepStrictEqual(await second.json(), { claimed: 0 });
  });
});

Deno.test("sweeper-wake: with waitUntil the answer goes out before the sends finish", async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const background: Promise<unknown>[] = [];
  await withHandler(
    async ({ tick, store, sent }) => {
      await store.upsert({ token: TOKEN, userId: USER_ID, environment: "production", moments: [new Date("2026-11-20T04:30:00Z")] });
      const res = await tick();
      assert.strictEqual(res.status, 202);
      assert.deepStrictEqual(await res.json(), { claimed: 1 });
      assert.strictEqual(background.length, 1);
      release();
      await Promise.all(background);
      assert.deepStrictEqual(sent, [TOKEN]);
    },
    { onSend: () => gate, waitUntil: (p) => void background.push(p) },
  );
});

Deno.test("sweeper-wake: /tick with the kill switch is a no-op that says so", async () => {
  await withHandler(async ({ tick, store, sent, setEnv }) => {
    await store.upsert({ token: TOKEN, userId: USER_ID, environment: "production", moments: [new Date("2026-11-20T04:30:00Z")] });
    setEnv("LHF_SWEEPER_WAKE_DISABLED", "1");
    const res = await tick();
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(await res.json(), { disabled: true });
    assert.strictEqual(sent.length, 0);
  });
});
