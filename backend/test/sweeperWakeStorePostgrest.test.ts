// Pins what `PostgrestSweeperWakeStore` sends (table, verb, filter, body, the
// claim's rpc arguments) and that `deleteUserData` removes the wake rows
// first. The real client builds the requests; only `fetch` is replaced.
import { strict as assert } from "node:assert";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import { PostgrestSweeperWakeStore } from "../supabase/functions/_shared/sweeperWake.ts";
import { deleteUserData } from "../supabase/functions/_shared/db.ts";

interface Seen {
  method: string;
  path: string;
  query: string;
  body: unknown;
}

async function withStub<T>(
  answer: (seen: Seen) => unknown,
  run: (client: SupabaseClient, seen: Seen[]) => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  const seen: Seen[] = [];
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const request = input instanceof Request ? input : new Request(String(input), init);
    const url = new URL(request.url);
    const text = await request.clone().text();
    const entry: Seen = { method: request.method, path: url.pathname.replace("/rest/v1/", ""), query: decodeURIComponent(url.search.slice(1)), body: text ? JSON.parse(text) : null };
    seen.push(entry);
    return new Response(JSON.stringify(answer(entry)), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  try {
    const client = createClient("http://supabase.test", "service-key", { auth: { persistSession: false, autoRefreshToken: false } });
    return await run(client as unknown as SupabaseClient, seen);
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test("postgrest wake store: upsert, claim, delete, failure, prune", async () => {
  await withStub(
    (s) => {
      if (s.path === "rpc/claim_sweeper_wakes") return [{ device_token: "t1", environment: "development", user_id: "u1" }];
      if (s.method === "GET" && s.query.includes("select=failures")) return { failures: 2 };
      if (s.method === "GET" && s.query.includes("select=device_token,moments")) {
        return [{ device_token: "t1", moments: ["2026-11-20T04:00:00+00:00", "2026-11-20T05:00:00+00:00"] }, { device_token: "t2", moments: ["2026-11-20T05:00:00+00:00"] }];
      }
      if (s.method === "DELETE") return [{ device_token: "t1" }, { device_token: "t2" }];
      return null;
    },
    async (client, seen) => {
      const store = new PostgrestSweeperWakeStore(client);
      await store.upsert({ token: "t1", userId: "u1", environment: "production", moments: [new Date("2026-11-20T04:34:00Z")], planHash: "0123456789abcdef" });
      assert.strictEqual(seen[0].method + " " + seen[0].path, "POST sweeper_wakes");
      assert.match(seen[0].query, /on_conflict=device_token/);
      const body = seen[0].body as Record<string, unknown>;
      assert.deepStrictEqual(Object.keys(body).sort(), ["device_token", "environment", "failures", "moments", "plan_hash", "updated_at", "user_id"]);
      assert.deepStrictEqual(body.moments, ["2026-11-20T04:34:00.000Z"]);
      assert.strictEqual(body.failures, 0);

      const claimed = await store.claim(new Date("2026-11-20T04:34:00Z"), 2000);
      assert.deepStrictEqual(claimed, [{ token: "t1", environment: "development", userId: "u1" }]);
      assert.strictEqual(seen[1].path, "rpc/claim_sweeper_wakes");
      assert.deepStrictEqual(seen[1].body, { at_minute: "2026-11-20T04:34:00.000Z", max_rows: 2000 });

      assert.strictEqual(await store.deleteForUser("u1"), 2);
      assert.strictEqual(seen[2].method + " " + seen[2].path + " " + seen[2].query, "DELETE sweeper_wakes user_id=eq.u1&select=device_token");

      assert.strictEqual(await store.markFailure("t1"), 3);
      const patch = seen.find((s) => s.method === "PATCH")!;
      assert.deepStrictEqual(patch.body, { failures: 3 });
      assert.match(patch.query, /device_token=eq\.t1/);

      await store.deleteToken("t9");
      const del = seen[seen.length - 1];
      assert.strictEqual(del.method + " " + del.path + " " + del.query, "DELETE sweeper_wakes device_token=eq.t9");

      seen.length = 0;
      await store.pruneMoments(new Date("2026-11-20T04:30:00Z"), ["t1", "t2"]);
      const patches = seen.filter((s) => s.method === "PATCH");
      assert.strictEqual(patches.length, 1, "only the row with an old moment is rewritten");
      assert.deepStrictEqual(patches[0].body, { moments: ["2026-11-20T05:00:00+00:00"] });
    },
  );
});

Deno.test("deleteUserData removes the wake rows first", async () => {
  await withStub(
    () => [],
    async (client, seen) => {
      await deleteUserData(client, "u1");
      assert.strictEqual(seen[0].method + " " + seen[0].path + " " + seen[0].query, "DELETE sweeper_wakes user_id=eq.u1");
    },
  );
});
