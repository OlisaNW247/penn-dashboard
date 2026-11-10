// The real store's transitions, listing and cleanup against a stubbed
// PostgREST and Storage; the phone handler's rules are in
// agentSnapshotHandler.test.ts against the memory store.
import { strict as assert } from "node:assert";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import { PostgrestDraftStore, removeUserDraftObjects, sanitizeFileName, newDraftId } from "../supabase/functions/_shared/agentDrafts.ts";

interface Call { method: string; path: string; q: URLSearchParams; body: string }

async function withStore<T>(
  respond: (c: Call) => Response | null,
  run: (store: PostgrestDraftStore, calls: Call[], client: SupabaseClient) => Promise<T>,
): Promise<T> {
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
    return await run(new PostgrestDraftStore(client), calls, client);
  } finally {
    globalThis.fetch = original;
  }
}
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json" } });
const NOW = new Date("2026-11-10T12:00:00Z");

Deno.test("ids and object names", () => {
  assert.match(newDraftId(), /^smd_[A-Za-z0-9_-]{22}$/);
  assert.strictEqual(sanitizeFileName("../../etc/passwd"), "_.._etc_passwd"); // no separator survives, so no path escape
  assert.strictEqual(sanitizeFileName("My Essay (final).pdf"), "My_Essay_final_.pdf");
  assert.strictEqual(sanitizeFileName("..."), "file");
  assert.ok(sanitizeFileName("a".repeat(300) + ".pdf").length <= 120);
  assert.ok(sanitizeFileName("a".repeat(300) + ".pdf").endsWith(".pdf"));
});

Deno.test("transition: conditional on the current state, in one statement", async () => {
  await withStore((c) => (c.method === "PATCH" ? json([{ id: "smd_a", file_path: null }]) : null), async (store, calls) => {
    assert.strictEqual(await store.transition("u1", "smd_a", "seen", {}, NOW), "ok");
    const patch = calls.find((c) => c.method === "PATCH")!;
    assert.strictEqual(patch.q.get("status"), "in.(proposed)");
    assert.strictEqual(patch.q.get("user_id"), "eq.u1");
    assert.strictEqual(JSON.parse(patch.body).seen_at, NOW.toISOString());
  });
  await withStore((c) => (c.method === "PATCH" ? json([{ id: "smd_a", file_path: null }]) : null), async (store, calls) => {
    await store.transition("u1", "smd_a", "submitted", { canvasSubmissionId: "9", attempt: 2 }, NOW);
    const patch = calls.find((c) => c.method === "PATCH")!;
    assert.strictEqual(patch.q.get("status"), "in.(proposed,seen)");
    assert.deepStrictEqual(JSON.parse(patch.body), { status: "submitted", updated_at: NOW.toISOString(), decided_at: NOW.toISOString(), canvas_submission_id: "9", attempt: 2 });
  });
});

Deno.test("transition: no row updated is 409 when the draft exists, 404 when it does not", async () => {
  await withStore((c) => (c.method === "GET" ? json([{ id: "smd_a", status: "declined" }]) : null), async (store) => {
    assert.strictEqual(await store.transition("u1", "smd_a", "seen", {}, NOW), "conflict");
  });
  await withStore(() => null, async (store) => {
    assert.strictEqual(await store.transition("u1", "smd_a", "seen", {}, NOW), "not_found");
  });
});

Deno.test("transition: a decision deletes the object, and a failed delete does not fail the decision", async () => {
  await withStore(
    (c) => (c.method === "PATCH" && c.q.get("status") ? json([{ id: "smd_a", file_path: "u1/smd_a/x.pdf" }]) : c.method === "DELETE" ? json({ message: "no" }, 500) : null),
    async (store, calls) => {
      assert.strictEqual(await store.transition("u1", "smd_a", "declined", {}, NOW), "ok");
      const del = calls.find((c) => c.method === "DELETE" && c.path.startsWith("/storage/"))!;
      assert.match(del.body, /u1\/smd_a\/x\.pdf/);
      const clears = calls.filter((c) => c.method === "PATCH" && c.body.includes('"file_path":null'));
      assert.strictEqual(clears.length, 1);
    },
  );
});

Deno.test("listOpen: proposed and seen, newest first, signs only file drafts for 120 seconds", async () => {
  const rows = [
    { id: "smd_f", assignment_id: "a", kind: "file", body: null, url: null, file_path: "u1/smd_f/x.pdf", file_name: "x.pdf", mime_type: "application/pdf", file_bytes: 3, note: null, client_name: "Claude", status: "proposed", created_at: "2026-11-10T12:00:00Z" },
    { id: "smd_t", assignment_id: "a", kind: "text", body: "b", url: null, file_path: null, file_name: null, mime_type: null, file_bytes: null, note: null, client_name: "Claude", status: "seen", created_at: "2026-11-10T11:00:00Z" },
  ];
  await withStore(
    (c) => (c.path.startsWith("/storage/v1/object/sign/") ? json({ signedURL: "/object/sign/agent-drafts/u1/smd_f/x.pdf?token=t" }) : c.path === "/rest/v1/agent_drafts" ? json(rows) : null),
    async (store, calls) => {
      const list = await store.listOpen("u1", 50);
      assert.deepStrictEqual(list.map((d) => d.id), ["smd_f", "smd_t"]);
      assert.ok(list[0].file_url?.includes("token=t"));
      assert.strictEqual("file_url" in list[1], false);
      assert.ok(list.every((d) => !("file_path" in d)));
      const q = calls.find((c) => c.path === "/rest/v1/agent_drafts")!.q;
      assert.strictEqual(q.get("status"), "in.(proposed,seen)");
      assert.strictEqual(q.get("order"), "created_at.desc");
      assert.strictEqual(q.get("limit"), "50");
      const sign = calls.find((c) => c.path.startsWith("/storage/v1/object/sign/"))!;
      assert.strictEqual(JSON.parse(sign.body).expiresIn, 120);
    },
  );
});

Deno.test("deleteAll: rows and their objects; removeUserDraftObjects lists then removes, never throws", async () => {
  await withStore(
    (c) => (c.method === "DELETE" && c.path === "/rest/v1/agent_drafts" ? json([{ id: "a", file_path: "u1/a/x" }, { id: "b", file_path: null }]) : null),
    async (store, calls) => {
      assert.strictEqual(await store.deleteAll("u1"), 2);
      assert.match(calls.find((c) => c.path.startsWith("/storage/"))!.body, /u1\/a\/x/);
    },
  );
  await withStore(
    (c) => {
      if (c.path === "/storage/v1/object/list/agent-drafts") {
        const prefix = JSON.parse(c.body).prefix as string;
        return json(prefix === "u1" ? [{ name: "smd_a" }] : [{ name: "x.pdf" }]);
      }
      return null;
    },
    async (_s, calls, client) => {
      await removeUserDraftObjects(client, "u1");
      const del = calls.find((c) => c.method === "DELETE")!;
      assert.match(del.body, /u1\/smd_a\/x\.pdf/);
    },
  );
  await withStore(() => json({ message: "down" }, 500), async (_s, _c, client) => {
    await removeUserDraftObjects(client, "u1");
  });
});
