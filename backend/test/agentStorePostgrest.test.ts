// Pins what `PostgrestAgentStore` sends: the table, the verb, the filter
// string and the `Prefer` header of every atomic method, and that it answers
// true/row on exactly one returned row and false/null on none. The real
// client builds the requests; only `fetch` is replaced.
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import {
  clientFromDb,
  clientToDb,
  connectionFromDb,
  connectionToDb,
  pendingFromDb,
  pendingToDb,
  PostgrestAgentStore,
  snapshotFromDb,
  snapshotToDb,
  tokenFromDb,
  tokenToDb,
} from "../supabase/functions/_shared/agentStorePostgrest.ts";
import type {
  AgentClientRow,
  AgentConnectionRow,
  AgentSnapshotRow,
  AgentTokenRow,
  PendingAuthRow,
} from "../supabase/functions/_shared/agentStore.ts";

interface Seen {
  method: string;
  path: string;
  /** Decoded query string, e.g. "id=eq.p1&status=eq.pending&select=id". */
  query: string;
  prefer: string | null;
  body: unknown;
}

async function withStub<T>(
  answers: Array<{ status?: number; body: unknown }>,
  run: (store: PostgrestAgentStore, seen: Seen[]) => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  const seen: Seen[] = [];
  let i = 0;
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const request = input instanceof Request ? input : new Request(String(input), init);
    const url = new URL(request.url);
    const text = await request.clone().text();
    seen.push({
      method: request.method,
      path: url.pathname.replace("/rest/v1/", ""),
      query: decodeURIComponent(url.search.slice(1)),
      prefer: request.headers.get("prefer"),
      body: text ? JSON.parse(text) : null,
    });
    const answer = answers[Math.min(i++, answers.length - 1)];
    return new Response(JSON.stringify(answer.body), {
      status: answer.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
  try {
    const client = createClient("http://supabase.test", "service-key", {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    return await run(new PostgrestAgentStore(client), seen);
  } finally {
    globalThis.fetch = original;
  }
}

const pending: PendingAuthRow = {
  id: "p1p1p1p1p1p1p1p1p1p1p1",
  userCode: "BCDFGHJK",
  matchNumber: 42,
  matchChoices: [42, 17, 63],
  nonceHash: "nh",
  params: {
    clientId: "https://claude.ai/c",
    redirectUri: "https://claude.ai/cb",
    codeChallenge: "x".repeat(43),
    state: null,
    resource: "https://mcp.test/mcp",
    scopes: ["read", "offline_access"],
  },
  userId: "u1",
  authCodeHash: "ach",
  authCodeExpiresAt: "2026-11-08T10:01:00.000Z",
  clientName: "Claude",
  status: "approved",
  createdAt: "2026-11-08T10:00:00.000Z",
  expiresAt: "2026-11-08T10:10:00.000Z",
  claimedBy: null,
};
const connection: AgentConnectionRow = {
  id: "c1",
  userId: "u1",
  clientId: "https://claude.ai/c",
  clientName: "Claude",
  scopes: ["read"],
  createdAt: "2026-11-08T10:00:00.000Z",
  lastUsedAt: "2026-11-08T11:00:00.000Z",
  revokedAt: null,
};
const token: AgentTokenRow = {
  hash: "h1",
  kind: "refresh",
  connectionId: "c1",
  resource: "https://mcp.test/mcp",
  scopes: ["read"],
  expiresAt: "2026-12-08T10:00:00.000Z",
  rotatedFrom: "h0",
  usedAt: null,
  createdAt: "2026-11-08T10:00:00.000Z",
};
const client: AgentClientRow = {
  clientId: "smc_AbCdEfGhIjKlMnOpQrStUv",
  clientName: "Inspector",
  redirectUris: ["http://localhost:6274/oauth/callback"],
  createdAt: "2026-11-08T10:00:00.000Z",
};
const snapshot: AgentSnapshotRow = {
  userId: "u1",
  courses: [{ courseID: "1", code: "CIS 121", name: "DS", canvasCourseID: "9" }],
  workList: [{ id: "a", title: "HW" }],
  manual: [],
  writtenAt: "2026-11-08T10:00:00.000Z",
};

Deno.test("mapping is lossless for every row type", () => {
  assertEq(pendingFromDb(pendingToDb(pending)), pending);
  assertEq(pendingFromDb(pendingToDb({ ...pending, userId: null, authCodeHash: null, authCodeExpiresAt: null })), {
    ...pending,
    userId: null,
    authCodeHash: null,
    authCodeExpiresAt: null,
  });
  assertEq(connectionFromDb(connectionToDb(connection)), connection);
  assertEq(tokenFromDb(tokenToDb(token)), token);
  assertEq(snapshotFromDb(snapshotToDb(snapshot)), snapshot);
  // snake_case on the wire.
  const db = pendingToDb(pending);
  assertEq(db.user_code, "BCDFGHJK");
  assertEq(db.match_choices, [42, 17, 63]);
  assertEq(db.auth_code_expires_at, pending.authCodeExpiresAt);
});

function assertEq(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`expected ${e}\n     got ${a}`);
}

Deno.test("approvePending: one conditional PATCH, true only for one row", async () => {
  await withStub([{ body: [{ id: "p1" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.approvePending("p1", "u1"), true);
    assertEq(await store.approvePending("p1", "u1"), false);
    const s = seen[0];
    assertEq(s.method, "PATCH");
    assertEq(s.path, "agent_pending_auth");
    assertEq(s.query, "id=eq.p1&status=eq.pending&select=id");
    assertEq(s.prefer, "return=representation");
    assertEq(s.body, { status: "approved", user_id: "u1" });
    assertEq(seen.length, 2);
  });
});

Deno.test("issueAuthCode: needs approved and no code yet", async () => {
  await withStub([{ body: [{ id: "p1" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.issueAuthCode("p1", "hash", "2026-11-08T10:01:00.000Z"), true);
    assertEq(await store.issueAuthCode("p1", "hash", "2026-11-08T10:01:00.000Z"), false);
    const s = seen[0];
    assertEq(s.method, "PATCH");
    assertEq(s.path, "agent_pending_auth");
    assertEq(s.query, "id=eq.p1&status=eq.approved&auth_code_hash=is.null&select=id");
    assertEq(s.prefer, "return=representation");
    assertEq(s.body, { auth_code_hash: "hash", auth_code_expires_at: "2026-11-08T10:01:00.000Z" });
  });
});

Deno.test("denyPending: conditional PATCH on pending", async () => {
  await withStub([{ body: [{ id: "p1" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.denyPending("p1"), true);
    assertEq(await store.denyPending("p1"), false);
    assertEq(seen[0].method, "PATCH");
    assertEq(seen[0].query, "id=eq.p1&status=eq.pending&select=id");
    assertEq(seen[0].prefer, "return=representation");
    assertEq(seen[0].body, { status: "denied" });
  });
});

Deno.test("consumeAuthCode: PATCH approved -> consumed returning the row, null when none", async () => {
  await withStub([{ body: [pendingToDb({ ...pending, status: "consumed" })] }, { body: [] }], async (store, seen) => {
    assertEq(await store.consumeAuthCode("ach"), { ...pending, status: "consumed" });
    assertEq(await store.consumeAuthCode("ach"), null);
    assertEq(seen[0].method, "PATCH");
    assertEq(seen[0].path, "agent_pending_auth");
    assertEq(seen[0].query, "auth_code_hash=eq.ach&status=eq.approved&select=*");
    assertEq(seen[0].prefer, "return=representation");
    assertEq(seen[0].body, { status: "consumed" });
  });
});

Deno.test("selectPendingByUserCode filters status = pending; byId does not", async () => {
  await withStub([{ body: [] }, { body: [] }], async (store, seen) => {
    assertEq(await store.selectPendingByUserCode("BCDFGHJK"), null);
    assertEq(seen[0].method, "GET");
    assertEq(seen[0].query, "select=*&user_code=eq.BCDFGHJK&status=eq.pending");
    await store.selectPendingById("p1");
    assertEq(seen[1].query, "select=*&id=eq.p1");
  });
});

Deno.test("insertPending and insertTokens are one POST", async () => {
  await withStub([{ status: 201, body: null }], async (store, seen) => {
    await store.insertPending(pending);
    await store.insertTokens([token, { ...token, hash: "h2", kind: "access", rotatedFrom: null }]);
    assertEq(seen.length, 2);
    assertEq(seen[0].method, "POST");
    assertEq(seen[0].path, "agent_pending_auth");
    assertEq(seen[0].body, pendingToDb(pending));
    assertEq(seen[1].method, "POST");
    assertEq(seen[1].path, "agent_tokens");
    assertEq((seen[1].body as unknown[]).length, 2);
  });
});

Deno.test("markRefreshUsed: only an unredeemed refresh token", async () => {
  await withStub([{ body: [{ hash: "h1" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.markRefreshUsed("h1", "2026-11-08T12:00:00.000Z"), true);
    assertEq(await store.markRefreshUsed("h1", "2026-11-08T12:00:00.000Z"), false);
    assertEq(seen[0].method, "PATCH");
    assertEq(seen[0].path, "agent_tokens");
    assertEq(seen[0].query, "hash=eq.h1&kind=eq.refresh&used_at=is.null&select=hash");
    assertEq(seen[0].prefer, "return=representation");
    assertEq(seen[0].body, { used_at: "2026-11-08T12:00:00.000Z" });
  });
});

Deno.test("revokeConnection: conditional PATCH, then delete tokens only when it changed a row", async () => {
  await withStub([{ body: [{ id: "c1" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.revokeConnection("c1", "u1", "2026-11-08T12:00:00.000Z"), true);
    assertEq(seen.length, 2);
    assertEq(seen[0].method, "PATCH");
    assertEq(seen[0].path, "agent_connections");
    assertEq(seen[0].query, "id=eq.c1&user_id=eq.u1&revoked_at=is.null&select=id");
    assertEq(seen[0].prefer, "return=representation");
    assertEq(seen[0].body, { revoked_at: "2026-11-08T12:00:00.000Z" });
    assertEq(seen[1].method, "DELETE");
    assertEq(seen[1].path, "agent_tokens");
    assertEq(seen[1].query, "connection_id=eq.c1");
  });
  await withStub([{ body: [] }], async (store, seen) => {
    assertEq(await store.revokeConnection("c1", "u1", "2026-11-08T12:00:00.000Z"), false);
    assertEq(seen.length, 1);
  });
});

Deno.test("revokeAllConnections: updates live connections, deletes their tokens, returns the count", async () => {
  await withStub([{ body: [{ id: "c1" }, { id: "c2" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.revokeAllConnections("u1", "2026-11-08T12:00:00.000Z"), 2);
    assertEq(seen[0].method, "PATCH");
    assertEq(seen[0].path, "agent_connections");
    assertEq(seen[0].query, "user_id=eq.u1&revoked_at=is.null&select=id");
    assertEq(seen[0].prefer, "return=representation");
    assertEq(seen[1].method, "DELETE");
    assertEq(seen[1].path, "agent_tokens");
    assertEq(seen[1].query, "connection_id=in.(c1,c2)");
  });
  await withStub([{ body: [] }], async (store, seen) => {
    assertEq(await store.revokeAllConnections("u1", "2026-11-08T12:00:00.000Z"), 0);
    assertEq(seen.length, 1);
  });
});

Deno.test("deleteExpired*: lte on expires_at, count of returned rows", async () => {
  await withStub([{ body: [{ id: "a" }, { id: "b" }] }, { body: [{ hash: "x" }] }], async (store, seen) => {
    assertEq(await store.deleteExpiredPending("2026-11-08T12:00:00.000Z"), 2);
    assertEq(await store.deleteExpiredTokens("2026-11-08T12:00:00.000Z"), 1);
    assertEq(seen[0].method, "DELETE");
    assertEq(seen[0].path, "agent_pending_auth");
    assertEq(seen[0].query, "expires_at=lte.2026-11-08T12:00:00.000Z&select=id");
    assertEq(seen[0].prefer, "return=representation");
    assertEq(seen[1].method, "DELETE");
    assertEq(seen[1].path, "agent_tokens");
    assertEq(seen[1].query, "expires_at=lte.2026-11-08T12:00:00.000Z&select=hash");
  });
});

Deno.test("touchConnection, deleteToken, deleteTokensForConnection, snapshots", async () => {
  await withStub([{ body: [] }], async (store, seen) => {
    await store.touchConnection("c1", "2026-11-08T12:00:00.000Z");
    await store.deleteToken("h1");
    await store.deleteTokensForConnection("c1");
    await store.upsertSnapshot(snapshot);
    await store.deleteSnapshot("u1");
    assertEq(seen[0].method + " " + seen[0].path + " " + seen[0].query, "PATCH agent_connections id=eq.c1");
    assertEq(seen[1].method + " " + seen[1].path + " " + seen[1].query, "DELETE agent_tokens hash=eq.h1");
    assertEq(seen[2].method + " " + seen[2].path + " " + seen[2].query, "DELETE agent_tokens connection_id=eq.c1");
    assertEq(seen[3].method + " " + seen[3].path, "POST agent_snapshots");
    assertEq(seen[3].query, "on_conflict=user_id");
    assertEq(seen[3].prefer, "resolution=merge-duplicates");
    assertEq(seen[3].body, snapshotToDb(snapshot));
    assertEq(seen[4].method + " " + seen[4].path + " " + seen[4].query, "DELETE agent_snapshots user_id=eq.u1");
  });
});

Deno.test("selects map rows and return null when absent; listConnections orders by created_at", async () => {
  await withStub(
    [{ body: connectionToDb(connection) }, { body: [connectionToDb(connection)] }, { body: tokenToDb(token) }, { body: snapshotToDb(snapshot) }],
    async (store, seen) => {
      assertEq(await store.selectConnection("c1"), connection);
      assertEq(await store.listConnections("u1"), [connection]);
      assertEq(seen[1].query, "select=*&user_id=eq.u1&order=created_at.asc");
      assertEq(await store.selectToken("h1"), token);
      assertEq(await store.selectSnapshot("u1"), snapshot);
    },
  );
});

Deno.test("a PostgREST error is thrown as the error object", async () => {
  await withStub([{ status: 409, body: { code: "23505", message: "duplicate key" } }], async (store) => {
    let thrown: { code?: string } | undefined;
    try {
      await store.insertPending(pending);
    } catch (e) {
      thrown = e as { code?: string };
    }
    assertEq(thrown?.code, "23505");
  });
});

Deno.test("clients: insert is one POST, select filters by client_id and maps the row", async () => {
  assertEq(clientFromDb(clientToDb(client)), client);
  await withStub([{ status: 201, body: null }, { body: clientToDb(client) }, { body: null }], async (store, seen) => {
    await store.insertClient(client);
    assertEq(seen[0].method, "POST");
    assertEq(seen[0].path, "agent_clients");
    assertEq(seen[0].body, clientToDb(client));
    assertEq(await store.selectClient(client.clientId), client);
    assertEq(seen[1].path, "agent_clients");
    assertEq(seen[1].query, `select=*&client_id=eq.${client.clientId}`);
    assertEq(await store.selectClient("smc_none"), null);
  });
});

Deno.test("claimPending: conditional PATCH on pending; rateCheck and sweep call the RPCs", async () => {
  await withStub([{ body: [{ id: "p1" }] }, { body: [] }], async (store, seen) => {
    assertEq(await store.claimPending("p1", "u1"), true);
    assertEq(await store.claimPending("p1", "u1"), false);
    assertEq(seen[0].method, "PATCH");
    assertEq(seen[0].path, "agent_pending_auth");
    assertEq(seen[0].query.includes("status=eq.pending"), true);
    assertEq(seen[0].body, { claimed_by: "u1" });
  });
  await withStub([{ body: true }, { body: false }], async (store, seen) => {
    assertEq(await store.rateCheck("k", 5, 3600), true);
    assertEq(await store.rateCheck("k", 5, 3600), false);
    assertEq(seen[0].path, "rpc/agent_rate_check");
    assertEq(seen[0].body, { p_key: "k", p_limit: 5, p_window_seconds: 3600 });
  });
  await withStub([{ body: 7 }], async (store, seen) => {
    assertEq(await store.sweep(), 7);
    assertEq(seen[0].path, "rpc/agent_sweep_expired");
  });
  await withStub([{ status: 400, body: { message: "no such function" } }], async (store) => {
    let threw = false;
    try {
      await store.rateCheck("k", 5, 3600);
    } catch {
      threw = true;
    }
    assertEq(threw, true);
  });
});
