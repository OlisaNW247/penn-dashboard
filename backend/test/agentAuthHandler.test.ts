// The agent-auth handler end to end over MemoryAgentStore: discovery,
// the pairing flow, token issue and refresh, revoke, and the refusals.
import assert from "node:assert";
import { handleAgentAuth, type AgentAuthDeps } from "../supabase/functions/agent-auth/index.ts";
import { MemoryAgentStore } from "../supabase/functions/_shared/agentStoreMemory.ts";
import { HttpError } from "../supabase/functions/_shared/http.ts";
import { authorizationServerMetadata } from "../supabase/functions/_shared/agentMetadata.ts";
import { formatUserCode } from "../supabase/functions/_shared/agentAuth.ts";

const BASE = "https://x.supabase.co/functions/v1";
const ROOT = `${BASE}/agent-auth`;
const MCP = `${BASE}/mcp`;
const CLIENT = "https://claude.ai/oauth/mcp-oauth-client-metadata";
const REDIRECT = "https://claude.ai/api/mcp/auth_callback";
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const START = Date.parse("2026-11-08T12:00:00Z");

interface Harness {
  store: MemoryAgentStore;
  clock: { ms: number };
  call: (path: string, init?: RequestInit) => Promise<Response>;
}

function harness(): Harness {
  let s = 99;
  const random = (n: number) => {
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      out[i] = (s >> 16) & 0xff;
    }
    return out;
  };
  const store = new MemoryAgentStore();
  const clock = { ms: START };
  const deps: AgentAuthDeps = {
    store,
    publicBase: BASE,
    now: () => new Date(clock.ms),
    random,
    fetchClientMetadata: (url) => {
      if (url !== CLIENT) return Promise.reject(new Error("unknown client"));
      return Promise.resolve({
        client_id: CLIENT,
        client_name: "Claude",
        redirect_uris: [REDIRECT],
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
      });
    },
    requireUserId: (req) => {
      const user = req.headers.get("x-test-user");
      if (!user) return Promise.reject(new HttpError(401, "unauthorized"));
      return Promise.resolve(user);
    },
  };
  lastDeps = deps;
  return { store, clock, call: (path, init) => handleAgentAuth(new Request(`${ROOT}${path}`, init), deps) };
}

let lastDeps: AgentAuthDeps | null = null;
/** The deps of the most recent harness(), for a test that builds its own Request URL. */
function harnessDeps(): Promise<AgentAuthDeps> {
  return Promise.resolve(lastDeps!);
}

function authorizeQuery(extra: Record<string, string> = {}): string {
  return "/authorize?" + new URLSearchParams({
    response_type: "code",
    client_id: CLIENT,
    redirect_uri: REDIRECT,
    code_challenge: CHALLENGE,
    code_challenge_method: "S256",
    resource: MCP,
    scope: "read draft offline_access",
    state: "st-1",
    ...extra,
  }).toString();
}

function phone(h: Harness, body: unknown, user: string | null = "student-1"): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (user) headers["x-test-user"] = user;
  return h.call("/phone", { method: "POST", headers, body: JSON.stringify(body) });
}

function form(h: Harness, path: string, fields: Record<string, string>): Promise<Response> {
  return h.call(path, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString(),
  });
}

/** Runs authorize and returns the cookie header and the stored row. */
async function startFlow(h: Harness) {
  const res = await h.call(authorizeQuery());
  assert.strictEqual(res.status, 200);
  const cookie = res.headers.get("set-cookie")!.split(";")[0];
  const row = [...h.store.pending.values()][0];
  return { res, cookie, row, page: await res.text() };
}

/** The full pairing up to a minted authorization code. */
async function pairAndGetCode(h: Harness): Promise<{ code: string }> {
  const { cookie, row } = await startFlow(h);
  assert.strictEqual((await phone(h, { action: "lookup", c: row.id })).status, 200);
  const ok = await phone(h, { action: "approve", c: row.id, picked: row.matchNumber });
  assert.deepStrictEqual(await ok.json(), { approved: true, clientName: "Claude" });
  const go = await h.call(`/status?p=${row.id}&go=1`, { headers: { cookie } });
  assert.strictEqual(go.status, 302);
  const code = new URL(go.headers.get("location")!).searchParams.get("code")!;
  return { code };
}

function tokenFields(code: string, extra: Record<string, string> = {}): Record<string, string> {
  return {
    grant_type: "authorization_code",
    code,
    code_verifier: VERIFIER,
    redirect_uri: REDIRECT,
    client_id: CLIENT,
    resource: MCP,
    ...extra,
  };
}

Deno.test("both discovery paths return the authorization server document", async () => {
  const h = harness();
  const a = await h.call("/.well-known/oauth-authorization-server");
  const b = await h.call("/.well-known/openid-configuration");
  assert.strictEqual(a.status, 200);
  assert.strictEqual(a.headers.get("cache-control"), "public, max-age=300");
  assert.strictEqual(a.headers.get("access-control-allow-origin"), "*");
  const doc = await a.json();
  assert.deepStrictEqual(doc, await b.json());
  assert.deepStrictEqual(doc, authorizationServerMetadata(BASE));
  assert.strictEqual(doc.issuer, ROOT);
  assert.strictEqual(doc.client_id_metadata_document_supported, true);
});

Deno.test("routing: options, unknown path, wrong method", async () => {
  const h = harness();
  assert.strictEqual((await h.call("/token", { method: "OPTIONS" })).status, 204);
  assert.strictEqual((await h.call("/nope")).status, 404);
  assert.strictEqual((await h.call("/token")).status, 405);
  assert.strictEqual((await handleAgentAuth(new Request("https://x.example/other"), {} as AgentAuthDeps)).status, 404);
});

Deno.test("happy path: authorize, phone approve, status, code, token", async () => {
  const h = harness();
  const { res, cookie, row, page } = await startFlow(h);

  const setCookie = res.headers.get("set-cookie")!;
  assert.match(setCookie, /HttpOnly/);
  assert.match(setCookie, /Secure/);
  assert.match(setCookie, /SameSite=Lax/);
  assert.match(setCookie, /Path=\/functions\/v1\/agent-auth/);
  assert.match(res.headers.get("content-security-policy")!, /connect-src 'self'/);
  assert.strictEqual(res.headers.get("cache-control"), "no-store");
  assert.ok(page.includes(formatUserCode(row.userCode)));
  assert.ok(page.includes(`>${row.matchNumber}<`));
  assert.ok(page.includes(`smooth://link?c=${row.id}`));
  assert.ok(!page.includes("approve (dev)"));
  assert.strictEqual(h.store.pending.size, 1);
  assert.strictEqual(row.status, "pending");

  const byId = await (await phone(h, { action: "lookup", c: row.id })).json();
  assert.strictEqual(byId.clientName, "Claude");
  assert.strictEqual(byId.clientHost, "claude.ai");
  assert.strictEqual(byId.choices.length, 3);
  assert.ok(byId.choices.includes(row.matchNumber));
  const byCode = await (await phone(h, { action: "lookup", code: formatUserCode(row.userCode).toLowerCase() })).json();
  assert.strictEqual(byCode.id, row.id);
  assert.strictEqual(byCode.choices.length, 3);

  assert.strictEqual((await h.call(`/status?p=${row.id}`)).status, 403);
  assert.strictEqual((await h.call(`/status?p=${row.id}`, { headers: { cookie: "sa_x=y" } })).status, 403);
  const wrong = cookie.replace(/=.*/, "=" + "A".repeat(43));
  assert.strictEqual((await h.call(`/status?p=${row.id}`, { headers: { cookie: wrong } })).status, 403);
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "pending" });
  assert.strictEqual((await h.call(`/status?p=${row.id}&go=1`, { headers: { cookie } })).status, 400);

  assert.strictEqual((await phone(h, { action: "lookup", c: row.id })).status, 200);
  const approve = await phone(h, { action: "approve", c: row.id, picked: row.matchNumber });
  assert.deepStrictEqual(await approve.json(), { approved: true, clientName: "Claude" });
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "approved" });

  const go = await h.call(`/status?p=${row.id}&go=1`, { headers: { cookie } });
  assert.strictEqual(go.status, 302);
  const location = new URL(go.headers.get("location")!);
  assert.strictEqual(location.origin + location.pathname, REDIRECT);
  const code = location.searchParams.get("code")!;
  assert.match(code, /^smt_c_/);
  assert.strictEqual(location.searchParams.get("state"), "st-1");
  assert.strictEqual(location.searchParams.get("iss"), ROOT);
  assert.strictEqual((await h.call(`/status?p=${row.id}&go=1`, { headers: { cookie } })).status, 409);

  const tok = await form(h, "/token", tokenFields(code));
  assert.strictEqual(tok.status, 200);
  assert.strictEqual(tok.headers.get("cache-control"), "no-store");
  const body = await tok.json();
  assert.match(body.access_token, /^smt_a_/);
  assert.match(body.refresh_token, /^smt_r_/);
  assert.strictEqual(body.token_type, "Bearer");
  assert.strictEqual(body.expires_in, 3600);
  assert.strictEqual(body.scope, "read draft offline_access");
  assert.strictEqual(h.store.connections.size, 1);
  assert.strictEqual(h.store.tokens.size, 2);
  const connection = [...h.store.connections.values()][0];
  assert.strictEqual(connection.userId, "student-1");
  assert.strictEqual(connection.clientName, "Claude");
  assert.strictEqual([...h.store.pending.values()][0].status, "consumed");
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "approved" });
});

Deno.test("a wrong match number denies the request", async () => {
  const h = harness();
  const { cookie, row } = await startFlow(h);
  const wrong = row.matchChoices.find((n) => n !== row.matchNumber)!;
  assert.strictEqual((await phone(h, { action: "lookup", c: row.id })).status, 200);
  const res = await phone(h, { action: "approve", c: row.id, picked: wrong });
  assert.deepStrictEqual(await res.json(), { approved: false, reason: "match" });
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "denied" });
  assert.strictEqual((await phone(h, { action: "approve", c: row.id, picked: row.matchNumber })).status, 404);
});

Deno.test("deny from the phone", async () => {
  const h = harness();
  const { cookie, row } = await startFlow(h);
  assert.strictEqual((await phone(h, { action: "lookup", c: row.id })).status, 200);
  assert.deepStrictEqual(await (await phone(h, { action: "deny", c: row.id })).json(), { denied: true });
  // Decided now; the student's own claim stays, so this is "nothing to deny".
  assert.deepStrictEqual(await (await phone(h, { action: "deny", c: row.id })).json(), { denied: false });
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "denied" });
});

Deno.test("a wrong PKCE verifier burns the code", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  const bad = await form(h, "/token", tokenFields(code, { code_verifier: "x".repeat(43) }));
  assert.strictEqual(bad.status, 400);
  assert.strictEqual((await bad.json()).error, "invalid_grant");
  const retry = await form(h, "/token", tokenFields(code));
  assert.strictEqual(retry.status, 400);
  assert.strictEqual((await retry.json()).error, "invalid_grant");
  assert.strictEqual(h.store.tokens.size, 0);
});

Deno.test("token refusals are all invalid_grant", async () => {
  const cases: Record<string, string>[] = [
      { redirect_uri: "https://claude.ai/api/mcp/auth_callback/" },
      { client_id: "https://other.example/client" },
      { resource: "https://x.supabase.co/functions/v1/other" },
  ];
  for (const extra of cases) {
    const h = harness();
    const { code } = await pairAndGetCode(h);
    const res = await form(h, "/token", tokenFields(code, extra));
    assert.strictEqual(res.status, 400, JSON.stringify(extra));
    assert.strictEqual((await res.json()).error, "invalid_grant", JSON.stringify(extra));
  }
  const h = harness();
  const { code } = await pairAndGetCode(h);
  h.clock.ms += 61_000;
  assert.strictEqual((await (await form(h, "/token", tokenFields(code))).json()).error, "invalid_grant");
  assert.strictEqual((await (await form(h, "/token", tokenFields("smt_c_nope"))).json()).error, "invalid_grant");
});

Deno.test("token: json body, unknown grant type", async () => {
  const h = harness();
  const json = await h.call("/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ grant_type: "authorization_code" }),
  });
  assert.strictEqual((await json.json()).error, "invalid_request");
  const res = await form(h, "/token", { grant_type: "password" });
  assert.strictEqual((await res.json()).error, "unsupported_grant_type");
});

Deno.test("authorize with an unregistered redirect_uri shows a page and never redirects", async () => {
  const h = harness();
  const res = await h.call(authorizeQuery({ redirect_uri: "https://evil.example/cb" }));
  assert.strictEqual(res.status, 400);
  assert.strictEqual(res.headers.get("location"), null);
  assert.match(res.headers.get("content-type")!, /text\/html/);
  assert.strictEqual(h.store.pending.size, 0);

  const unknown = await h.call(authorizeQuery({ client_id: "https://unknown.example/c.json" }));
  assert.strictEqual(unknown.status, 400);
  assert.strictEqual(unknown.headers.get("location"), null);
});

Deno.test("authorize with another resource redirects with invalid_target and the state", async () => {
  const h = harness();
  const res = await h.call(authorizeQuery({ resource: "https://evil.example/mcp" }));
  assert.strictEqual(res.status, 302);
  const location = new URL(res.headers.get("location")!);
  assert.strictEqual(location.origin + location.pathname, REDIRECT);
  assert.strictEqual(location.searchParams.get("error"), "invalid_target");
  assert.strictEqual(location.searchParams.get("state"), "st-1");
  assert.strictEqual(location.searchParams.get("iss"), ROOT);
  assert.strictEqual(h.store.pending.size, 0);
});

Deno.test("refresh rotates, and reusing the old refresh token revokes the connection", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  const first = await (await form(h, "/token", tokenFields(code))).json();

  const res = await form(h, "/token", { grant_type: "refresh_token", refresh_token: first.refresh_token, resource: MCP });
  assert.strictEqual(res.status, 200);
  const second = await res.json();
  assert.notStrictEqual(second.refresh_token, first.refresh_token);
  assert.notStrictEqual(second.access_token, first.access_token);
  assert.strictEqual(second.expires_in, 3600);
  assert.strictEqual(second.scope, "read draft offline_access");
  const rotated = [...h.store.tokens.values()].filter((t) => t.rotatedFrom !== null);
  assert.strictEqual(rotated.length, 1);

  const reuse = await form(h, "/token", { grant_type: "refresh_token", refresh_token: first.refresh_token });
  assert.strictEqual(reuse.status, 400);
  assert.strictEqual((await reuse.json()).error, "invalid_grant");
  const connection = [...h.store.connections.values()][0];
  assert.notStrictEqual(connection.revokedAt, null);
  assert.strictEqual(h.store.tokens.size, 0);

  const after = await form(h, "/token", { grant_type: "refresh_token", refresh_token: second.refresh_token });
  assert.strictEqual((await after.json()).error, "invalid_grant");
});

Deno.test("refresh: scope must be a subset, resource must match", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  const first = await (await form(h, "/token", tokenFields(code))).json();
  const wide = await form(h, "/token", { grant_type: "refresh_token", refresh_token: first.refresh_token, scope: "read write" });
  assert.strictEqual((await wide.json()).error, "invalid_scope");
  const other = await form(h, "/token", { grant_type: "refresh_token", refresh_token: first.refresh_token, resource: "https://evil.example/mcp" });
  assert.strictEqual((await other.json()).error, "invalid_target");
  const narrow = await form(h, "/token", { grant_type: "refresh_token", refresh_token: first.refresh_token, scope: "read" });
  assert.strictEqual((await narrow.json()).scope, "read");
});

Deno.test("an expired refresh token is invalid_grant", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  const first = await (await form(h, "/token", tokenFields(code))).json();
  h.clock.ms += 61 * 24 * 60 * 60_000;
  const res = await form(h, "/token", { grant_type: "refresh_token", refresh_token: first.refresh_token });
  assert.strictEqual((await res.json()).error, "invalid_grant");
});

Deno.test("revoke: access token deletes its row; refresh revokes the connection; junk is still 200", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  const tokens = await (await form(h, "/token", tokenFields(code))).json();

  const res = await form(h, "/revoke", { token: tokens.access_token, token_type_hint: "access_token" });
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), {});
  assert.strictEqual(h.store.tokens.size, 1);

  assert.strictEqual((await form(h, "/revoke", { token: "junk" })).status, 200);
  assert.strictEqual((await form(h, "/revoke", {})).status, 200);
  assert.strictEqual((await form(h, "/revoke", { token: tokens.access_token })).status, 200);

  assert.strictEqual((await form(h, "/revoke", { token: tokens.refresh_token })).status, 200);
  assert.strictEqual(h.store.tokens.size, 0);
  assert.notStrictEqual([...h.store.connections.values()][0].revokedAt, null);
});

Deno.test("phone list, revoke and revokeAll", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  await form(h, "/token", tokenFields(code));

  const list = await (await phone(h, { action: "list" })).json();
  assert.strictEqual(list.connections.length, 1);
  const c = list.connections[0];
  assert.strictEqual(c.clientName, "Claude");
  assert.strictEqual(c.clientHost, "claude.ai");
  assert.deepStrictEqual(c.scopes, ["read", "draft", "offline_access"]);
  assert.strictEqual(c.lastUsedAt, null);
  assert.deepStrictEqual((await (await phone(h, { action: "list" }, "student-2")).json()).connections, []);

  assert.deepStrictEqual(await (await phone(h, { action: "revoke", id: c.id }, "student-2")).json(), { revoked: false });
  assert.deepStrictEqual(await (await phone(h, { action: "revoke", id: c.id })).json(), { revoked: true });
  assert.deepStrictEqual((await (await phone(h, { action: "list" })).json()).connections, []);
  assert.strictEqual(h.store.tokens.size, 0);
});

Deno.test("phone revokeAll counts live connections", async () => {
  const h = harness();
  const { code } = await pairAndGetCode(h);
  await form(h, "/token", tokenFields(code));
  assert.deepStrictEqual(await (await phone(h, { action: "revokeAll" })).json(), { revoked: 1 });
  assert.deepStrictEqual(await (await phone(h, { action: "revokeAll" })).json(), { revoked: 0 });
});

Deno.test("an expired pending reads expired and cannot be approved or looked up", async () => {
  const h = harness();
  const { cookie, row } = await startFlow(h);
  h.clock.ms += 6 * 60_000;
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "expired" });
  assert.strictEqual((await phone(h, { action: "approve", c: row.id, picked: row.matchNumber })).status, 404);
  assert.strictEqual((await phone(h, { action: "lookup", c: row.id })).status, 404);
  assert.strictEqual((await phone(h, { action: "lookup", code: row.userCode })).status, 404);
  assert.strictEqual((await phone(h, { action: "lookup", code: "nonsense" })).status, 404);
});

Deno.test("phone requires a user and a known action", async () => {
  const h = harness();
  assert.strictEqual((await phone(h, { action: "list" }, null)).status, 401);
  assert.strictEqual((await phone(h, { action: "frobnicate" })).status, 400);
  assert.strictEqual((await phone(h, { action: "approve", c: "x" })).status, 400);
  assert.strictEqual((await h.call("/phone")).status, 405);
});

function register(h: Harness, body: unknown): Promise<Response> {
  return h.call("/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}

Deno.test("metadata advertises the registration endpoint", async () => {
  const doc = await (await harness().call("/.well-known/oauth-authorization-server")).json();
  assert.strictEqual(doc.registration_endpoint, `${ROOT}/register`);
});

Deno.test("register: 201 with a smc_ id, stored", async () => {
  const h = harness();
  const res = await register(h, { redirect_uris: ["http://localhost:6274/oauth/callback"], client_name: "Inspector" });
  assert.strictEqual(res.status, 201);
  const body = await res.json();
  assert.match(body.client_id, /^smc_[A-Za-z0-9_-]{22}$/);
  assert.strictEqual(body.client_name, "Inspector");
  assert.deepStrictEqual(body.redirect_uris, ["http://localhost:6274/oauth/callback"]);
  assert.strictEqual(body.token_endpoint_auth_method, "none");
  assert.deepStrictEqual(body.grant_types, ["authorization_code", "refresh_token"]);
  assert.deepStrictEqual(body.response_types, ["code"]);
  assert.strictEqual(body.client_id_issued_at, Math.floor(START / 1000));
  assert.strictEqual(h.store.clients.size, 1);
});

Deno.test("register refusals: 400 invalid_client_metadata, bad JSON, wrong method", async () => {
  const h = harness();
  for (const body of [{}, { redirect_uris: ["http://evil.example/cb"] }, { redirect_uris: ["https://a.example/cb"], token_endpoint_auth_method: "client_secret_post" }]) {
    const res = await register(h, body);
    assert.strictEqual(res.status, 400);
    const j = await res.json();
    assert.strictEqual(j.error, "invalid_client_metadata");
    assert.ok(typeof j.error_description === "string");
  }
  const junk = await h.call("/register", { method: "POST", body: "{nope" });
  assert.strictEqual(junk.status, 400);
  assert.strictEqual((await h.call("/register")).status, 405);
  assert.strictEqual(h.store.clients.size, 0);
});

Deno.test("a registered client runs authorize, approve and token end to end", async () => {
  const h = harness();
  const cb = "http://localhost:6274/oauth/callback";
  const reg = await (await register(h, { redirect_uris: [cb], client_name: "Inspector" })).json();
  const query = authorizeQuery({ client_id: reg.client_id, redirect_uri: "http://localhost:51234/oauth/callback" });
  // Loopback port differs from the registered one: still matches.
  const res = await h.call(query);
  assert.strictEqual(res.status, 200);
  const cookie = res.headers.get("set-cookie")!.split(";")[0];
  const row = [...h.store.pending.values()][0];
  assert.strictEqual(row.clientName, "Inspector");
  assert.strictEqual(row.params.clientId, reg.client_id);
  assert.ok(!("clientKind" in row.params));
  assert.strictEqual((await (await phone(h, { action: "lookup", c: row.id })).json()).clientName, "Inspector");
  await phone(h, { action: "approve", c: row.id, picked: row.matchNumber });
  const go = await h.call(`/status?p=${row.id}&go=1`, { headers: { cookie } });
  const location = new URL(go.headers.get("location")!);
  assert.strictEqual(location.origin + location.pathname, "http://localhost:51234/oauth/callback");
  const code = location.searchParams.get("code")!;
  const tok = await form(h, "/token", tokenFields(code, { client_id: reg.client_id, redirect_uri: "http://localhost:51234/oauth/callback" }));
  assert.strictEqual(tok.status, 200);
  assert.match((await tok.json()).access_token, /^smt_a_/);
  assert.strictEqual([...h.store.connections.values()][0].clientName, "Inspector");
});

Deno.test("an unknown or mismatched registered client gets a page, never a redirect", async () => {
  const h = harness();
  const unknown = await h.call(authorizeQuery({ client_id: "smc_" + "Z".repeat(22), redirect_uri: "https://a.example/cb" }));
  assert.strictEqual(unknown.status, 400);
  assert.strictEqual(unknown.headers.get("location"), null);

  const reg = await (await register(h, { redirect_uris: ["https://a.example/cb"] })).json();
  const other = await h.call(authorizeQuery({ client_id: reg.client_id, redirect_uri: "https://evil.example/cb" }));
  assert.strictEqual(other.status, 400);
  assert.strictEqual(other.headers.get("location"), null);

  // The error redirect path does the same lookup.
  const badResource = await h.call(authorizeQuery({ client_id: "smc_" + "Z".repeat(22), redirect_uri: "https://a.example/cb", resource: "https://evil.example/mcp" }));
  assert.strictEqual(badResource.status, 400);
  assert.strictEqual(badResource.headers.get("location"), null);
  const verified = await h.call(authorizeQuery({ client_id: reg.client_id, redirect_uri: "https://a.example/cb", resource: "https://evil.example/mcp" }));
  assert.strictEqual(verified.status, 302);
  assert.strictEqual(new URL(verified.headers.get("location")!).searchParams.get("error"), "invalid_target");
  assert.strictEqual(h.store.pending.size, 0);
});

Deno.test("authorize page announces its content type and CSP for the connector front", async () => {
  const h = harness();
  const { res } = await startFlow(h);
  const csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'";
  assert.strictEqual(res.headers.get("content-type"), "text/html; charset=utf-8");
  assert.strictEqual(res.headers.get("x-smooth-content-type"), "text/html; charset=utf-8");
  assert.strictEqual(res.headers.get("x-smooth-csp"), csp);
  assert.strictEqual(res.headers.get("content-security-policy"), csp);
});

Deno.test("deny needs a lookup by the same student", async () => {
  const h = harness();
  const { cookie, row } = await startFlow(h);
  // Never looked up: 404, and the request stays pending.
  assert.strictEqual((await phone(h, { action: "deny", c: row.id })).status, 404);
  assert.strictEqual((await phone(h, { action: "deny", c: "nope" })).status, 404);
  // Another student looked it up (typed code); the first still cannot deny.
  assert.strictEqual((await phone(h, { action: "lookup", code: row.userCode }, "student-2")).status, 200);
  assert.strictEqual((await phone(h, { action: "deny", c: row.id }, "student-1")).status, 404);
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "pending" });
  assert.deepStrictEqual(await (await phone(h, { action: "deny", c: row.id }, "student-2")).json(), { denied: true });
});

function withIP(h: Harness, ip: string) {
  return (path: string, init: RequestInit = {}) =>
    h.call(path, { ...init, headers: { ...(init.headers as Record<string, string>), "x-forwarded-for": `${ip}, 10.0.0.1` } });
}

Deno.test("/authorize is limited to 60 an hour per ip, then 429 slow_down", async () => {
  const h = harness();
  h.store.clock = () => new Date(h.clock.ms);
  const a = withIP(h, "203.0.113.5");
  for (let i = 0; i < 60; i++) assert.strictEqual((await a(authorizeQuery())).status, 200);
  const over = await a(authorizeQuery());
  assert.strictEqual(over.status, 429);
  assert.strictEqual(over.headers.get("retry-after"), "60");
  assert.deepStrictEqual(await over.json(), { error: "slow_down" });
  // Another address is unaffected; the first recovers after the hour.
  assert.strictEqual((await withIP(h, "203.0.113.6")(authorizeQuery())).status, 200);
  h.clock.ms += 3601 * 1000;
  assert.strictEqual((await a(authorizeQuery())).status, 200);
});

Deno.test("/register is 60 an hour per ip; cf-connecting-ip and unknown are buckets", async () => {
  const h = harness();
  const body = JSON.stringify({ client_name: "X", redirect_uris: ["https://x.test/cb"], token_endpoint_auth_method: "none" });
  const reg = (headers: Record<string, string>) =>
    h.call("/register", { method: "POST", headers: { "content-type": "application/json", ...headers }, body });
  for (let i = 0; i < 60; i++) assert.notStrictEqual((await reg({ "cf-connecting-ip": "198.51.100.1" })).status, 429);
  assert.strictEqual((await reg({ "cf-connecting-ip": "198.51.100.1" })).status, 429);
  assert.notStrictEqual((await reg({ "cf-connecting-ip": "198.51.100.2" })).status, 429);
  // No header at all shares one "unknown" bucket.
  for (let i = 0; i < 60; i++) await reg({});
  assert.strictEqual((await reg({})).status, 429);
});

Deno.test("/token: a shared egress ip is not throttled by students; per code 5, per connection 30, ip ceiling 1200", async () => {
  const h = harness();
  // Fifty different codes from one ip (a hosted connector): all answered, none 429.
  for (let i = 0; i < 50; i++) {
    const r = await form(h, "/token", tokenFields("smt_c_" + String(i).padStart(43, "x")));
    assert.strictEqual(r.status, 400);
  }
  // Guessing one code: the sixth try is 429.
  const guess = "smt_c_" + "g".repeat(43);
  for (let i = 0; i < 5; i++) assert.strictEqual((await form(h, "/token", tokenFields(guess))).status, 400);
  const over = await form(h, "/token", tokenFields(guess));
  assert.strictEqual(over.status, 429);
  assert.strictEqual(over.headers.get("retry-after"), "60");
  assert.deepStrictEqual(await over.json(), { error: "slow_down" });

  // Refresh: unknown tokens never count; a real connection gets 30.
  for (let i = 0; i < 40; i++) {
    const r = await form(h, "/token", { grant_type: "refresh_token", refresh_token: "smt_r_" + String(i).padStart(43, "y") });
    assert.strictEqual(r.status, 400);
  }
  const { code } = await pairAndGetCode(h);
  let refresh = (await (await form(h, "/token", tokenFields(code))).json()).refresh_token as string;
  for (let i = 0; i < 30; i++) {
    const r = await form(h, "/token", { grant_type: "refresh_token", refresh_token: refresh });
    assert.strictEqual(r.status, 200);
    refresh = (await r.json()).refresh_token;
  }
  assert.strictEqual((await form(h, "/token", { grant_type: "refresh_token", refresh_token: refresh })).status, 429);

  // The ip ceiling is a backstop: 1200 an hour from one ip, then 429 for anything.
  const h2 = harness();
  for (let i = 0; i < 1200; i++) await form(h2, "/token", { grant_type: "password" });
  assert.strictEqual((await form(h2, "/token", { grant_type: "password" })).status, 429);
});

Deno.test("/phone lookup 20 an hour and approve 10 an hour per student", async () => {
  const h = harness();
  const { row } = await startFlow(h);
  for (let i = 0; i < 20; i++) assert.strictEqual((await phone(h, { action: "lookup", code: "BCDFGHJK" })).status, 404);
  const over = await phone(h, { action: "lookup", code: "BCDFGHJK" });
  assert.strictEqual(over.status, 429);
  assert.strictEqual(over.headers.get("retry-after"), "60");
  // Another student has their own allowance, and a real lookup works.
  assert.strictEqual((await phone(h, { action: "lookup", c: row.id }, "student-2")).status, 200);
  for (let i = 0; i < 10; i++) assert.strictEqual((await phone(h, { action: "approve", c: "nope", picked: 1 }, "student-3")).status, 404);
  assert.strictEqual((await phone(h, { action: "approve", c: "nope", picked: 1 }, "student-3")).status, 429);
  // list is not limited.
  assert.strictEqual((await phone(h, { action: "list" }, "student-3")).status, 200);
});

Deno.test("a failing rate check fails open", async () => {
  const h = harness();
  h.store.rateCheck = () => Promise.reject(new Error("relation does not exist"));
  assert.strictEqual((await h.call(authorizeQuery())).status, 200);
});

Deno.test("one /authorize in ~50 sweeps; a failing sweep is ignored", async () => {
  const h = harness();
  h.store.clock = () => new Date(h.clock.ms);
  await startFlow(h);
  h.clock.ms += 3 * 60 * 60 * 1000;
  // random() == 0 forces the sweep; the expired pending row is removed.
  // Only the sweep's one-byte draw is forced to 0; ids and codes stay random
  // (an all-zero source would spin their rejection sampling forever).
  const forced = (n: number) => (n === 1 ? new Uint8Array(1) : crypto.getRandomValues(new Uint8Array(n)));
  const deps = {
    store: h.store,
    publicBase: BASE,
    now: () => new Date(h.clock.ms),
    random: forced,
    fetchClientMetadata: () =>
      Promise.resolve({ client_id: CLIENT, client_name: "Claude", redirect_uris: [REDIRECT], token_endpoint_auth_method: "none" }),
    requireUserId: () => Promise.resolve("student-1"),
  };
  const before = h.store.pending.size;
  assert.strictEqual(before, 1);
  const res = await handleAgentAuth(new Request(`${ROOT}${authorizeQuery()}`), deps);
  assert.strictEqual(res.status, 200);
  const ids = [...h.store.pending.values()];
  assert.strictEqual(ids.length, 1);
  assert.ok(Date.parse(ids[0].expiresAt) > h.clock.ms, "only the new row is left");
  h.store.sweep = () => Promise.reject(new Error("down"));
  assert.strictEqual((await handleAgentAuth(new Request(`${ROOT}${authorizeQuery()}`), deps)).status, 200);
});

Deno.test("memory sweep: expired pending, old tokens, idle limits, unused old clients", async () => {
  const h = harness();
  const day = 86400000;
  let now = START;
  h.store.clock = () => new Date(now);
  const client = (id: string, at: number) => h.store.clients.set(id, { clientId: id, clientName: "c", redirectUris: [], createdAt: new Date(at).toISOString() });
  client("smc_old_unused", START - 31 * day);
  client("smc_old_connected", START - 31 * day);
  client("smc_new", START - 1 * day);
  await h.store.insertConnection({ id: "k", userId: "u", clientId: "smc_old_connected", clientName: "c", scopes: [], createdAt: "x", lastUsedAt: null, revokedAt: null });
  await h.store.rateCheck("k", 1, 60);
  now += 2 * day;
  assert.strictEqual(await h.store.sweep(), 2); // the idle rate row and the unused old client
  assert.deepStrictEqual([...h.store.clients.keys()].sort(), ["smc_new", "smc_old_connected"]);
});

Deno.test("approve needs a lookup by the same student, like deny", async () => {
  const h = harness();
  const { cookie, row } = await startFlow(h);
  const pick = { action: "approve", c: row.id, picked: row.matchNumber };
  // Never looked up, or looked up by someone else: 404, and nothing is decided
  // (a wrong pick from a stranger must not deny the real student's request).
  assert.strictEqual((await phone(h, pick)).status, 404);
  assert.strictEqual((await phone(h, { ...pick, picked: -1 }, "student-2")).status, 404);
  assert.strictEqual((await phone(h, { action: "lookup", code: row.userCode }, "student-2")).status, 200);
  assert.strictEqual((await phone(h, pick, "student-1")).status, 404);
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "pending" });
  assert.deepStrictEqual(await (await phone(h, pick, "student-2")).json(), { approved: true, clientName: "Claude" });
});

Deno.test("sweep keeps a pending row until two minutes past its expiry", async () => {
  const h = harness();
  h.store.clock = () => new Date(h.clock.ms);
  await startFlow(h);
  const row = [...h.store.pending.values()][0];
  h.clock.ms = Date.parse(row.expiresAt) + 30_000;
  assert.strictEqual(await h.store.sweep(), 0);
  h.clock.ms = Date.parse(row.expiresAt) + 3 * 60_000;
  assert.strictEqual(await h.store.sweep(), 1);
});

Deno.test("the root comes from the public base even when the runtime strips /functions/v1 from the path", async () => {
  // Supabase's edge runtime hands the function `/agent-auth/...`; the browser
  // is at `<front>/functions/v1/agent-auth/...`. Two approvals on a phone on
  // 2026-11-09 never became a code because the cookie path and the status
  // URL followed the stripped path.
  harness();
  const stripped = `https://ref.supabase.co/agent-auth${authorizeQuery()}`;
  const res = await handleAgentAuth(new Request(stripped), {
    ...(await harnessDeps()),
  });
  assert.strictEqual(res.status, 200);
  assert.match(res.headers.get("set-cookie")!, /Path=\/functions\/v1\/agent-auth/);
  const page = await res.text();
  assert.ok(page.includes("/functions/v1/agent-auth/status?p="));
  assert.ok(!page.includes('"/agent-auth/status'));
});

// Measured 2026-11-11 (docs/V11_TEST_BACKEND_2026-11-11.md): behind the
// connector front every request reaches Supabase from Vercel's egress, and
// the gateway rewrites x-forwarded-for to that address, so /authorize was one
// bucket for every student. The front now hands the address over with a
// shared secret; only that pair moves a request into its own bucket.
Deno.test("/authorize trusts x-smooth-client-ip only with the front's secret", async () => {
  const h = harness();
  lastDeps!.frontClientIPSecret = "front-secret-for-tests";
  const fromFront = (student: string, secret = "front-secret-for-tests") =>
    h.call(authorizeQuery(), {
      headers: { "x-forwarded-for": "76.76.21.1", "x-smooth-client-ip": student, "x-smooth-front-secret": secret },
    });
  // One student's 60, then 429; another student behind the same egress is untouched.
  for (let i = 0; i < 60; i++) assert.strictEqual((await fromFront("198.51.100.10")).status, 200);
  assert.strictEqual((await fromFront("198.51.100.10")).status, 429);
  assert.strictEqual((await fromFront("198.51.100.11")).status, 200);
  // A wrong secret falls back to x-forwarded-for: the egress bucket, untouched so far.
  for (let i = 0; i < 60; i++) assert.strictEqual((await fromFront(`203.0.113.${i}`, "guess")).status, 200);
  assert.strictEqual((await fromFront("203.0.113.200", "guess")).status, 429);
  // No secret configured: the header is ignored even with the right value.
  lastDeps!.frontClientIPSecret = undefined;
  assert.strictEqual((await fromFront("198.51.100.12")).status, 429);
});

Deno.test("a direct caller cannot pick its bucket with x-smooth-client-ip (no secret)", async () => {
  const h = harness();
  lastDeps!.frontClientIPSecret = "front-secret-for-tests";
  const direct = (spoof: string) => h.call(authorizeQuery(), { headers: { "x-forwarded-for": "192.0.2.7", "x-smooth-client-ip": spoof } });
  for (let i = 0; i < 60; i++) assert.strictEqual((await direct(`10.0.0.${i}`)).status, 200);
  assert.strictEqual((await direct("10.9.9.9")).status, 429);
});
