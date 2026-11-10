// The Postgrest upload store against stubbed PostgREST and Storage: what it
// sends (bytea as `\x` hex), what it reads back, the signed upload URL, the
// staged-object read, and the cleanup. The rules are in mcpHandler.test.ts
// (through the tools, against the memory store).
import { strict as assert } from "node:assert";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import {
  chunkLength,
  fromBytea,
  PostgrestUploadStore,
  stagingPath,
  toBytea,
  type UploadRow,
  UploadService,
} from "../supabase/functions/_shared/agentUploads.ts";
import { removeUserDraftObjects } from "../supabase/functions/_shared/agentDrafts.ts";

interface Call { method: string; path: string; q: URLSearchParams; body: string }

async function withStore<T>(respond: (c: Call) => Response | null, run: (store: PostgrestUploadStore, calls: Call[], client: SupabaseClient) => Promise<T>): Promise<T> {
  const original = globalThis.fetch;
  const calls: Call[] = [];
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const request = input instanceof Request ? input : new Request(String(input), init);
    const url = new URL(request.url);
    const body = request.method === "GET" || request.method === "HEAD" ? "" : await request.text();
    const call = { method: request.method, path: url.pathname, q: url.searchParams, body };
    calls.push(call);
    return respond(call) ?? new Response("[]", { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  try {
    const client = createClient("http://supabase.test", "service-key", { auth: { persistSession: false, autoRefreshToken: false } });
    return await run(new PostgrestUploadStore(client), calls, client);
  } finally {
    globalThis.fetch = original;
  }
}
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json" } });

const ROW: UploadRow = {
  id: "smu_a", userId: "u1", connectionId: "c1", assignmentId: "asg", fileName: "My Essay.pdf", mimeType: "application/pdf",
  totalBytes: 20_000, sha256: "a".repeat(64), chunkBytes: 16384, chunks: 2,
  createdAt: "2026-11-10T12:00:00.000Z", expiresAt: "2026-11-10T12:30:00.000Z",
};

Deno.test("bytea hex round-trips; chunk lengths and staging path", () => {
  const bytes = new Uint8Array([0, 1, 255, 16]);
  assert.strictEqual(toBytea(bytes), "\\x0001ff10");
  assert.deepStrictEqual(fromBytea("\\x0001ff10"), bytes);
  assert.throws(() => fromBytea("0001"));
  assert.strictEqual(chunkLength(ROW, 0), 16384);
  assert.strictEqual(chunkLength(ROW, 1), 3616);
  assert.strictEqual(stagingPath("u1", "smu_a", "My Essay.pdf"), "u1/uploads/smu_a/My_Essay.pdf");
});

Deno.test("putChunk upserts hex on (upload_id,index); chunks reads them back in order", async () => {
  await withStore(
    (c) => (c.method === "GET" && c.path === "/rest/v1/agent_upload_chunks" ? json([{ index: 0, data: "\\x0102" }, { index: 1, data: "\\x03" }]) : null),
    async (store, calls) => {
      await store.putChunk("smu_a", 1, new Uint8Array([1, 2]), "ff");
      const put = calls.find((c) => c.method === "POST")!;
      assert.strictEqual(put.q.get("on_conflict"), "upload_id,index");
      assert.deepStrictEqual(JSON.parse(put.body), { upload_id: "smu_a", index: 1, data: "\\x0102", sha256: "ff" });
      const got = await store.chunks("smu_a");
      assert.deepStrictEqual(got.map((g) => [g.index, [...g.bytes]]), [[0, [1, 2]], [1, [3]]]);
      assert.strictEqual(calls.find((c) => c.method === "GET")!.q.get("order"), "index.asc");
    },
  );
});

Deno.test("replaceForConnection deletes the connection's old uploads and objects, then inserts", async () => {
  await withStore(
    (c) => (c.method === "DELETE" && c.path === "/rest/v1/agent_uploads" ? json([{ id: "smu_old", user_id: "u1", file_name: "o.pdf" }]) : null),
    async (store, calls) => {
      await store.replaceForConnection(ROW);
      const del = calls.find((c) => c.method === "DELETE" && c.path === "/rest/v1/agent_uploads")!;
      assert.strictEqual(del.q.get("connection_id"), "eq.c1");
      assert.strictEqual(del.q.get("user_id"), "eq.u1");
      const rm = calls.find((c) => c.method === "DELETE" && c.path.startsWith("/storage/v1/object/agent-drafts"))!;
      assert.ok(rm.body.includes("u1/uploads/smu_old/o.pdf"));
      const ins = JSON.parse(calls.find((c) => c.method === "POST" && c.path === "/rest/v1/agent_uploads")!.body);
      assert.strictEqual(ins.id, "smu_a");
      assert.strictEqual(ins.expires_at, ROW.expiresAt);
      assert.strictEqual(ins.total_bytes, 20_000);
    },
  );
});

Deno.test("signedUploadUrl asks Storage for a signed upload URL into agent-drafts; a failure is null", async () => {
  await withStore(
    (c) => (c.path.includes("/object/upload/sign/") ? json({ url: "/object/upload/sign/agent-drafts/u1/uploads/smu_a/x.pdf?token=tok" }) : null),
    async (store, calls) => {
      const url = await store.signedUploadUrl("u1/uploads/smu_a/x.pdf");
      assert.ok(url!.includes("/object/upload/sign/agent-drafts/u1/uploads/smu_a/x.pdf?token="));
      assert.strictEqual(calls[0].method, "POST");
    },
  );
  await withStore(
    (c) => (c.path.includes("/object/upload/sign/") ? json({ message: "boom", error: "boom", statusCode: "500" }, 500) : null),
    async (store) => assert.strictEqual(await store.signedUploadUrl("u1/uploads/smu_a/x.pdf"), null),
  );
});

Deno.test("readStaged: null when the folder has no such object, bytes when it does", async () => {
  await withStore(
    (c) => (c.path === "/storage/v1/object/list/agent-drafts" ? json([]) : null),
    async (store, calls) => {
      assert.strictEqual(await store.readStaged("u1/uploads/smu_a/x.pdf"), null);
      assert.ok(!calls.some((c) => c.method === "GET"));
    },
  );
  await withStore(
    (c) =>
      c.path === "/storage/v1/object/list/agent-drafts"
        ? json([{ name: "x.pdf", id: "1" }])
        : c.path === "/storage/v1/object/agent-drafts/u1/uploads/smu_a/x.pdf"
        ? new Response(new Uint8Array([9, 8, 7]))
        : null,
    async (store) => assert.deepStrictEqual([...(await store.readStaged("u1/uploads/smu_a/x.pdf"))!], [9, 8, 7]),
  );
});

Deno.test("finish through the Postgrest store reads the staged object, hands bytes to the draft step, then removes the row and object", async () => {
  const bytes = new Uint8Array(20_000).map((_, i) => i % 251);
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map((b) => b.toString(16).padStart(2, "0")).join("");
  await withStore(
    (c) =>
      c.method === "GET" && c.path === "/rest/v1/agent_uploads"
        ? json([{ id: "smu_a", user_id: "u1", connection_id: "c1", assignment_id: "asg", file_name: "My Essay.pdf", mime_type: "application/pdf", total_bytes: 20_000, sha256: hash, chunk_bytes: 16384, chunks: 2, created_at: ROW.createdAt, expires_at: ROW.expiresAt }])
        : c.path === "/storage/v1/object/list/agent-drafts"
        ? json([{ name: "My_Essay.pdf", id: "1" }])
        : c.path === "/storage/v1/object/agent-drafts/u1/uploads/smu_a/My_Essay.pdf" && c.method === "GET"
        ? new Response(bytes)
        : null,
    async (store, calls) => {
      const service = new UploadService(store, () => new Date("2026-11-10T12:10:00Z"));
      let handed = 0;
      const made = await service.finish("u1", "smu_a", (row, b) => {
        handed = b.byteLength;
        assert.strictEqual(row.assignmentId, "asg");
        return Promise.resolve({ id: "d1", bytes: b.byteLength, decodeMs: 0 });
      });
      assert.strictEqual(handed, 20_000);
      assert.strictEqual(made.fromStaged, true);
      assert.ok(calls.some((c) => c.method === "DELETE" && c.path === "/rest/v1/agent_uploads"));
      assert.ok(calls.some((c) => c.method === "DELETE" && c.path.startsWith("/storage/v1/object/agent-drafts")));
    },
  );
});

Deno.test("deleteAll removes the rows and their staged objects", async () => {
  await withStore(
    (c) => (c.method === "DELETE" && c.path === "/rest/v1/agent_uploads" ? json([{ id: "smu_a", user_id: "u1", file_name: "a.pdf" }, { id: "smu_b", user_id: "u1", file_name: "b.pdf" }]) : null),
    async (store, calls) => {
      assert.strictEqual(await store.deleteAll("u1"), 2);
      const rm = calls.find((c) => c.method === "DELETE" && c.path.startsWith("/storage/"))!;
      assert.ok(rm.body.includes("u1/uploads/smu_a/a.pdf") && rm.body.includes("u1/uploads/smu_b/b.pdf"));
    },
  );
});

Deno.test("removeUserDraftObjects also reaches objects staged under uploads/<id>/", async () => {
  await withStore(
    (c) => {
      if (c.path !== "/storage/v1/object/list/agent-drafts") return c.path.startsWith("/storage/v1/object/agent-drafts") ? json([]) : null;
      const prefix = JSON.parse(c.body).prefix;
      if (prefix === "u1") return json([{ name: "uploads", id: null }]);
      if (prefix === "u1/uploads") return json([{ name: "smu_a", id: null }]);
      if (prefix === "u1/uploads/smu_a") return json([{ name: "x.pdf", id: "9" }]);
      return json([]);
    },
    async (_store, calls, client) => {
      await removeUserDraftObjects(client, "u1");
      const rm = calls.find((c) => c.method === "DELETE")!;
      assert.ok(rm.body.includes("u1/uploads/smu_a/x.pdf"), rm.body);
    },
  );
});
