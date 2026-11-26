import { strict as assert } from "node:assert";
import { handleAgentSnapshot } from "../supabase/functions/agent-snapshot/index.ts";
import { MemoryDraftStore } from "../supabase/functions/_shared/agentDrafts.ts";
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
  run: (call: (body: unknown, headers?: Record<string, string>) => Promise<Response>, store: MemoryAgentStore, drafts: MemoryDraftStore) => Promise<void>,
) {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "fail", status: 500 } });
  try {
    const store = new MemoryAgentStore();
    const drafts = new MemoryDraftStore();
    const call = (body: unknown, headers: Record<string, string> = {}) =>
      handleAgentSnapshot(
        new Request("http://edge.test/agent-snapshot", {
          method: "POST",
          headers: { authorization: "Bearer user-jwt", "content-type": "application/json", ...headers },
          body: typeof body === "string" ? body : JSON.stringify(body),
        }),
        { store, drafts, now: () => NOW },
      );
    await run(call, store, drafts);
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
      { store, drafts: new MemoryDraftStore(), now: () => NOW },
    );
    assert.strictEqual(noAuth.status, 401);
    const get = await handleAgentSnapshot(new Request("http://edge.test/agent-snapshot"), { store, drafts: new MemoryDraftStore() });
    assert.strictEqual(get.status, 405);
  });
});

const seedDraft = async (drafts: MemoryDraftStore, userId: string, over: Record<string, unknown> = {}) =>
  await drafts.create(userId, { assignmentId: "canvas:1", connectionId: "c1", clientName: "Claude", kind: "text", body: "my answer", ...over } as never);

Deno.test("agent-snapshot drafts: open drafts, newest first, a signed url only for files", async () => {
  await withHandler(async (call, _store, drafts) => {
    const t = await seedDraft(drafts, USER_ID);
    const f = await seedDraft(drafts, USER_ID, { kind: "file", body: undefined, file: { bytes: new Uint8Array([1, 2, 3]), name: "a b.pdf", mimeType: "application/pdf" } });
    await seedDraft(drafts, "someone-else");
    const done = await seedDraft(drafts, USER_ID);
    await drafts.transition(USER_ID, done, "declined", {}, NOW);

    const res = await call({ action: "drafts" });
    assert.strictEqual(res.status, 200);
    const list = (await res.json()).drafts as Array<Record<string, unknown>>;
    assert.deepStrictEqual(list.map((d) => d.id), [f, t]);
    assert.ok(typeof list[0].file_url === "string");
    assert.strictEqual("file_url" in list[1], false);
    assert.strictEqual("file_path" in list[0], false);
    assert.strictEqual(list[0].file_bytes, 3);
    assert.strictEqual(list[1].client_name, "Claude");
  });
});

Deno.test("agent-snapshot draft: the allowed transitions, and the objects go at the decision", async () => {
  await withHandler(async (call, _store, drafts) => {
    const file = { bytes: new Uint8Array([1]), name: "x.txt", mimeType: "text/plain" };
    const a = await seedDraft(drafts, USER_ID, { kind: "file", file });
    assert.strictEqual(drafts.objects.size, 1);
    assert.strictEqual((await call({ action: "draft", id: a, status: "seen" })).status, 200);
    assert.strictEqual(drafts.objects.size, 1, "seen keeps the file");
    const sub = await call({ action: "draft", id: a, status: "submitted", canvas_submission_id: "99", attempt: 1 });
    assert.strictEqual(sub.status, 200);
    assert.deepStrictEqual(await sub.json(), { id: a, status: "submitted" });
    assert.strictEqual(drafts.objects.size, 0, "submitted deletes the file");

    const b = await seedDraft(drafts, USER_ID, { kind: "file", file });
    assert.strictEqual((await call({ action: "draft", id: b, status: "declined" })).status, 200);
    assert.strictEqual(drafts.objects.size, 0);

    const c = await seedDraft(drafts, USER_ID, { kind: "file", file });
    assert.strictEqual((await call({ action: "draft", id: c, status: "failed", error_class: "http_422" })).status, 200);
    assert.strictEqual(drafts.objects.size, 0);
  });
});

Deno.test("agent-snapshot draft: nothing leaves a terminal state, seen only from proposed", async () => {
  await withHandler(async (call, _store, drafts) => {
    const a = await seedDraft(drafts, USER_ID);
    await call({ action: "draft", id: a, status: "seen" });
    const again = await call({ action: "draft", id: a, status: "seen" });
    assert.strictEqual(again.status, 409);
    assert.strictEqual((await again.json()).error, "conflict");
    await call({ action: "draft", id: a, status: "declined" });
    for (const status of ["seen", "declined", "failed", "submitted"]) {
      const res = await call({ action: "draft", id: a, status, canvas_submission_id: "1", error_class: "x" });
      assert.strictEqual(res.status, 409, status);
    }
    assert.strictEqual(drafts.rows.get(a)!.status, "declined");
  });
});

Deno.test("agent-snapshot draft: another student's draft and an unknown id are 404", async () => {
  await withHandler(async (call, _store, drafts) => {
    const other = await seedDraft(drafts, "someone-else");
    assert.strictEqual((await call({ action: "draft", id: other, status: "declined" })).status, 404);
    assert.strictEqual(drafts.rows.get(other)!.status, "proposed");
    assert.strictEqual((await call({ action: "draft", id: "smd_nope", status: "seen" })).status, 404);
  });
});

Deno.test("agent-snapshot draft: bad requests", async () => {
  await withHandler(async (call, _store, drafts) => {
    const a = await seedDraft(drafts, USER_ID);
    const bad = async (body: Record<string, unknown>) => assert.strictEqual((await call({ action: "draft", id: a, ...body })).status, 400, JSON.stringify(body));
    await bad({ status: "proposed" });
    await bad({ status: "nonsense" });
    await bad({ status: "submitted" });
    await bad({ status: "submitted", canvas_submission_id: "" });
    await bad({ status: "failed" });
    await bad({ status: "failed", error_class: "x".repeat(65) });
    await bad({ status: "seen", attempt: -1 });
    await bad({ status: "seen", attempt: 1.5 });
    assert.strictEqual((await call({ action: "draft", status: "seen" })).status, 400);
    assert.strictEqual(drafts.rows.get(a)!.status, "proposed");
  });
});

Deno.test("agent-snapshot delete: the opt-out also deletes the drafts and their files", async () => {
  await withHandler(async (call, _store, drafts) => {
    await seedDraft(drafts, USER_ID, { kind: "file", file: { bytes: new Uint8Array([1]), name: "x.txt" } });
    const keep = await seedDraft(drafts, "someone-else");
    const res = await call({ action: "delete" });
    assert.strictEqual(res.status, 200);
    assert.strictEqual(drafts.objects.size, 0);
    assert.deepStrictEqual([...drafts.rows.keys()], [keep]);
  });
});
