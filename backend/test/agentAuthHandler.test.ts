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
  return { store, clock, call: (path, init) => handleAgentAuth(new Request(`${ROOT}${path}`, init), deps) };
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
  const res = await phone(h, { action: "approve", c: row.id, picked: wrong });
  assert.deepStrictEqual(await res.json(), { approved: false, reason: "match" });
  assert.deepStrictEqual(await (await h.call(`/status?p=${row.id}`, { headers: { cookie } })).json(), { state: "denied" });
  assert.strictEqual((await phone(h, { action: "approve", c: row.id, picked: row.matchNumber })).status, 404);
});

Deno.test("deny from the phone", async () => {
  const h = harness();
  const { cookie, row } = await startFlow(h);
  assert.deepStrictEqual(await (await phone(h, { action: "deny", c: row.id })).json(), { denied: true });
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
