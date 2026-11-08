import { strict as assert } from "node:assert";
import { handleAgentSnapshot } from "../supabase/functions/agent-snapshot/index.ts";
import { MemoryAgentStore } from "../supabase/functions/_shared/agentStoreMemory.ts";
import type { AgentConnectionRow } from "../supabase/functions/_shared/agentStore.ts";
import { GRANTED, installStub, USER_ID } from "./support/edgeStub.ts";

const NOW = new Date("2026-11-10T12:00:00.000Z");

const snapshot = () => ({
  courses: [{ courseID: "1001", code: "PHYS 0151", name: "Mechanics" }],
  workList: [
    { id: "canvas:1", course: "PHYS 0151", title: "HW4", kind: "assignment", dueAt: "2026-11-11T12:00:00Z", done: false, noSubmission: false, url: null, source: "canvas" },
  ],
  manual: [{ id: "m1", course: "PHYS 0151", title: "Read", dueAt: null, repeatsWeekly: true }],
});

async function withHandler(
  run: (call: (body: unknown, headers?: Record<string, string>) => Promise<Response>, store: MemoryAgentStore) => Promise<void>,
) {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "fail", status: 500 } });
  try {
    const store = new MemoryAgentStore();
    const call = (body: unknown, headers: Record<string, string> = {}) =>
      handleAgentSnapshot(
        new Request("http://edge.test/agent-snapshot", {
          method: "POST",
          headers: { authorization: "Bearer user-jwt", "content-type": "application/json", ...headers },
          body: typeof body === "string" ? body : JSON.stringify(body),
        }),
        { store, now: () => NOW },
      );
    await run(call, store);
  } finally {
    stub.restore();
  }
}

const connection = (id: string, userId: string): AgentConnectionRow => ({
  id,
  userId,
  clientId: "https://claude.ai/c",
  clientName: "Claude",
  scopes: ["read"],
  createdAt: NOW.toISOString(),
  lastUsedAt: null,
  revokedAt: null,
});

Deno.test("agent-snapshot: put, status, put again, delete", async () => {
  await withHandler(async (call, store) => {
    const empty = await call({ action: "status" });
    assert.deepStrictEqual(await empty.json(), { hasSnapshot: false, writtenAt: null, items: 0 });

    const put = await call({ action: "put", snapshot: { ...snapshot(), extra: "dropped" } });
    assert.strictEqual(put.status, 200);
    assert.deepStrictEqual(await put.json(), { writtenAt: NOW.toISOString(), items: 2 });
    const row = store.snapshots.get(USER_ID)!;
    assert.strictEqual(row.writtenAt, NOW.toISOString());
    assert.strictEqual((row.workList as unknown[]).length, 1);

    const status = await call({ action: "status" });
    assert.deepStrictEqual(await status.json(), { hasSnapshot: true, writtenAt: NOW.toISOString(), items: 2 });

    const gone = await call({ action: "delete" });
    assert.strictEqual(gone.status, 200);
    assert.deepStrictEqual(await gone.json(), { deleted: true, revoked: 0 });
    assert.strictEqual(store.snapshots.size, 0);
  });
});

Deno.test("agent-snapshot: delete revokes this student's connections only", async () => {
  await withHandler(async (call, store) => {
    await store.insertConnection(connection("c1", USER_ID));
    await store.insertConnection(connection("c2", USER_ID));
    await store.insertConnection(connection("c3", "someone-else"));
    await call({ action: "put", snapshot: snapshot() });
    const res = await call({ action: "delete" });
    assert.deepStrictEqual(await res.json(), { deleted: true, revoked: 2 });
    assert.strictEqual((await store.selectConnection("c1"))?.revokedAt, NOW.toISOString());
    assert.strictEqual((await store.selectConnection("c2"))?.revokedAt, NOW.toISOString());
    assert.strictEqual((await store.selectConnection("c3"))?.revokedAt, null);
  });
});

Deno.test("agent-snapshot: refusals", async () => {
  await withHandler(async (call, store) => {
    const bad = await call({ action: "put", snapshot: { ...snapshot(), workList: [{ ...snapshot().workList[0], score: 97 }] } });
    assert.strictEqual(bad.status, 400);
    const body = await bad.json();
    assert.strictEqual(body.error, "bad_request");
    assert.strictEqual(body.message, "forbidden_field");
    assert.strictEqual(store.snapshots.size, 0);

    assert.strictEqual((await call({ action: "nope" })).status, 400);
    assert.strictEqual((await call("{not json")).status, 400);
    assert.strictEqual((await call({ action: "put" })).status, 400);

    const big = await call({ action: "put", snapshot: snapshot() }, { "content-length": String(1_048_577) });
    assert.strictEqual(big.status, 413);
    assert.strictEqual(store.snapshots.size, 0);

    const noAuth = await handleAgentSnapshot(
      new Request("http://edge.test/agent-snapshot", { method: "POST", body: JSON.stringify({ action: "status" }) }),
      { store, now: () => NOW },
    );
    assert.strictEqual(noAuth.status, 401);
    const get = await handleAgentSnapshot(new Request("http://edge.test/agent-snapshot"), { store });
    assert.strictEqual(get.status, 405);
  });
});
