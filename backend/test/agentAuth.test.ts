// Unit tests for the pure authorization rules in
// supabase/functions/_shared/agentAuth.ts. No network, no database.
import assert from "node:assert";
import {
  authorizePage,
  errorPage,
  formatUserCode,
  generateId,
  generateUserCode,
  matchChoices,
  nonceCookieName,
  normalizeUserCode,
  parseCookies,
  redirectURIMatches,
  USER_CODE_ALPHABET,
  validateAuthorizeRequest,
  validateClientMetadata,
  validateRegistrationRequest,
  verifyPKCE,
} from "../supabase/functions/_shared/agentAuth.ts";

const MCP = "https://x.supabase.co/functions/v1/mcp";
const CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const CLIENT = "https://claude.ai/oauth/mcp-oauth-client-metadata";
const REDIRECT = "https://claude.ai/api/mcp/auth_callback";

function good(extra: Record<string, string | null> = {}): URLSearchParams {
  const p = new URLSearchParams({
    response_type: "code",
    client_id: CLIENT,
    redirect_uri: REDIRECT,
    code_challenge: CHALLENGE,
    code_challenge_method: "S256",
    resource: MCP,
    state: "abc",
  });
  for (const [k, v] of Object.entries(extra)) {
    if (v === null) p.delete(k);
    else p.set(k, v);
  }
  return p;
}

function counterRandom(seed = 1): (n: number) => Uint8Array {
  let s = seed;
  return (n) => {
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      out[i] = (s >> 16) & 0xff;
    }
    return out;
  };
}

Deno.test("authorize: a good request passes with defaults", () => {
  const r = validateAuthorizeRequest(good({ scope: null }), MCP);
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.deepStrictEqual(r.request.scopes, ["read", "draft", "offline_access"]);
  assert.strictEqual(r.request.resource, MCP);
  assert.strictEqual(r.request.state, "abc");
});

Deno.test("authorize: missing resource means the MCP URL; a trailing slash is dropped", () => {
  const a = validateAuthorizeRequest(good({ resource: null }), MCP);
  assert.ok(a.ok);
  assert.ok(validateAuthorizeRequest(good({ resource: MCP + "/" }), MCP).ok);
});

Deno.test("authorize: wrong resource is a redirectable invalid_target", () => {
  const r = validateAuthorizeRequest(good({ resource: "https://evil.example/mcp" }), MCP);
  assert.ok(!r.ok);
  if (r.ok) return;
  assert.strictEqual(r.error, "invalid_target");
  assert.strictEqual(r.redirectable, true);
});

Deno.test("authorize: scope is filtered to known values, empty falls back to default", () => {
  const a = validateAuthorizeRequest(good({ scope: "read write admin" }), MCP);
  assert.ok(a.ok);
  if (a.ok) assert.deepStrictEqual(a.request.scopes, ["read"]);
  // A scope naming only things we do not have is a client error, never a
  // grant of everything (the verifier's note of 2026-11-08).
  const b = validateAuthorizeRequest(good({ scope: "write" }), MCP);
  assert.ok(!b.ok);
  if (!b.ok) assert.strictEqual(b.error, "invalid_scope");
  const c = validateAuthorizeRequest(good({ scope: null }), MCP);
  assert.ok(c.ok);
  if (c.ok) assert.deepStrictEqual(c.request.scopes, ["read", "draft", "offline_access"]);
});

Deno.test("authorize: state longer than 512 is refused, absent state is null", () => {
  assert.ok(!validateAuthorizeRequest(good({ state: "x".repeat(513) }), MCP).ok);
  const r = validateAuthorizeRequest(good({ state: null }), MCP);
  assert.ok(r.ok);
  if (r.ok) assert.strictEqual(r.request.state, null);
});

Deno.test("authorize: response type, challenge and method errors are redirectable", () => {
  const cases: [Record<string, string | null>, string][] = [
    [{ response_type: "token" }, "unsupported_response_type"],
    [{ response_type: null }, "unsupported_response_type"],
    [{ code_challenge: null }, "invalid_request"],
    [{ code_challenge: "short" }, "invalid_request"],
    [{ code_challenge: "!".repeat(43) }, "invalid_request"],
    [{ code_challenge: "a".repeat(129) }, "invalid_request"],
    [{ code_challenge_method: "plain" }, "invalid_request"],
    [{ code_challenge_method: null }, "invalid_request"],
  ];
  for (const [extra, error] of cases) {
    const r = validateAuthorizeRequest(good(extra), MCP);
    assert.ok(!r.ok, JSON.stringify(extra));
    if (r.ok) continue;
    assert.strictEqual(r.error, error, JSON.stringify(extra));
    assert.strictEqual(r.redirectable, true, JSON.stringify(extra));
  }
});

Deno.test("authorize: an unusable client_id or redirect_uri is never redirectable", () => {
  const bad: Record<string, string | null>[] = [
    { client_id: null },
    { client_id: "http://claude.ai/x" },
    { client_id: "not a url" },
    { client_id: "https://claude.ai/x#frag" },
    { client_id: "https://user:pw@claude.ai/x" },
    { client_id: "https://127.0.0.1/x" },
    { client_id: "https://[::1]/x" },
    { client_id: "https://2130706433/x" },
    { client_id: "https://localhost/x" },
    { client_id: "https://intranet/x" },
    { redirect_uri: null },
    { redirect_uri: "not a url" },
    { redirect_uri: REDIRECT + "#frag" },
  ];
  for (const extra of bad) {
    const r = validateAuthorizeRequest(good(extra), MCP);
    assert.ok(!r.ok, JSON.stringify(extra));
    if (r.ok) continue;
    assert.strictEqual(r.redirectable, false, JSON.stringify(extra));
  }
});

Deno.test("redirectURIMatches: exact, loopback port-insensitive, nothing else", () => {
  assert.ok(redirectURIMatches(REDIRECT, REDIRECT));
  assert.ok(!redirectURIMatches(REDIRECT + "/", REDIRECT));
  assert.ok(redirectURIMatches("http://localhost:1234/callback", "http://localhost:5678/callback"));
  assert.ok(redirectURIMatches("http://127.0.0.1:1234/callback", "http://127.0.0.1/callback"));
  assert.ok(redirectURIMatches("http://[::1]:9/callback", "http://[::1]/callback"));
  assert.ok(!redirectURIMatches("http://localhost:1234/other", "http://localhost:5678/callback"));
  assert.ok(!redirectURIMatches("http://localhost:1234/callback?a=1", "http://localhost:5678/callback"));
  assert.ok(!redirectURIMatches("https://localhost:1234/callback", "https://localhost:5678/callback"));
  assert.ok(!redirectURIMatches("http://localhost:1234/callback", "http://127.0.0.1:1234/callback"));
  assert.ok(!redirectURIMatches("https://claude.ai:444/api/mcp/auth_callback", REDIRECT));
});

Deno.test("client metadata: good document, name and host fallback", () => {
  const doc = { client_id: CLIENT, client_name: "  Claude  ", redirect_uris: [REDIRECT], token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"] };
  assert.deepStrictEqual(validateClientMetadata(doc, CLIENT, REDIRECT), { ok: true, clientName: "Claude" });
  const bare = { client_id: CLIENT, redirect_uris: [REDIRECT] };
  assert.deepStrictEqual(validateClientMetadata(bare, CLIENT, REDIRECT), { ok: true, clientName: "claude.ai" });
  const long = { ...bare, client_name: "n".repeat(200) };
  const r = validateClientMetadata(long, CLIENT, REDIRECT);
  assert.ok(r.ok && r.clientName.length === 80);
});

Deno.test("client metadata: refusals", () => {
  const base = { client_id: CLIENT, redirect_uris: [REDIRECT] };
  assert.ok(!validateClientMetadata(null, CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata([], CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata({ ...base, client_id: "https://other.example/x" }, CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata({ ...base, redirect_uris: ["https://other.example/cb"] }, CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata({ ...base, redirect_uris: [] }, CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata({ client_id: CLIENT }, CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata({ ...base, token_endpoint_auth_method: "client_secret_basic" }, CLIENT, REDIRECT).ok);
  assert.ok(!validateClientMetadata({ ...base, grant_types: ["refresh_token"] }, CLIENT, REDIRECT).ok);
  assert.ok(validateClientMetadata({ redirect_uris: ["http://localhost:1/callback"], client_id: CLIENT }, CLIENT, "http://localhost:99/callback").ok);
});

Deno.test("PKCE: RFC 7636 appendix B vector, wrong verifier, bad length", async () => {
  const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  assert.strictEqual(await verifyPKCE(verifier, CHALLENGE), true);
  assert.strictEqual(await verifyPKCE(verifier.slice(0, -1) + "A", CHALLENGE), false);
  assert.strictEqual(await verifyPKCE("short", CHALLENGE), false);
  assert.strictEqual(await verifyPKCE("a".repeat(129), CHALLENGE), false);
  assert.strictEqual(await verifyPKCE(verifier.slice(0, 42) + "!", CHALLENGE), false);
});

Deno.test("user codes: alphabet, length, formatting, normalizing", () => {
  const random = counterRandom(7);
  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const code = generateUserCode(random);
    assert.strictEqual(code.length, 8);
    for (const ch of code) assert.ok(USER_CODE_ALPHABET.includes(ch));
    seen.add(code);
  }
  assert.ok(seen.size > 190);
  assert.strictEqual(formatUserCode("BCDFGHJK"), "BCDF-GHJK");
  assert.strictEqual(normalizeUserCode("bcdf-ghjk"), "BCDFGHJK");
  assert.strictEqual(normalizeUserCode(" bcdf ghjk "), "BCDFGHJK");
  assert.strictEqual(normalizeUserCode("BCDF-GHJ"), null);
  assert.strictEqual(normalizeUserCode("BCDF-GHJA"), null);
  assert.strictEqual(normalizeUserCode("BCDF-GHJK1"), null);
});

Deno.test("user codes: every letter of the alphabet appears (no dead symbol)", () => {
  const random = counterRandom(3);
  const letters = new Set<string>();
  for (let i = 0; i < 100; i++) for (const ch of generateUserCode(random)) letters.add(ch);
  assert.strictEqual(letters.size, 20);
});

Deno.test("match choices: three distinct two-digit numbers including the answer", () => {
  const random = counterRandom(11);
  for (let i = 0; i < 100; i++) {
    const { answer, choices } = matchChoices(random);
    assert.strictEqual(choices.length, 3);
    assert.strictEqual(new Set(choices).size, 3);
    assert.ok(choices.includes(answer));
    for (const n of choices) assert.ok(n >= 10 && n <= 99);
  }
});

Deno.test("ids, cookies", () => {
  const id = generateId(counterRandom(5));
  assert.match(id, /^[A-Za-z0-9_-]{22}$/);
  assert.strictEqual(nonceCookieName(id), `sa_${id}`);
  const cookies = parseCookies("a=1; sa_x=abc=def;  b=2");
  assert.strictEqual(cookies.get("sa_x"), "abc=def");
  assert.strictEqual(cookies.get("b"), "2");
  assert.strictEqual(parseCookies(null).size, 0);
});

Deno.test("authorizePage: escapes, deep link, code, number, dev link only when given", () => {
  const view = {
    clientName: "<script>alert(1)</script>",
    clientHost: "claude.ai",
    scopes: ["read", "draft", "offline_access"],
    pendingId: "AbC_-123456789012345",
    userCode: "BCDFGHJK",
    matchNumber: 47,
    statusURL: "/functions/v1/agent-auth/status?p=AbC",
  };
  const page = authorizePage(view);
  assert.ok(!page.includes("<script>alert(1)"));
  assert.ok(page.includes("&lt;script&gt;alert(1)"));
  assert.ok(page.includes('href="smooth://link?c=AbC_-123456789012345"'));
  assert.ok(page.includes("BCDF-GHJK"));
  assert.ok(page.includes(">47<"));
  assert.ok(page.includes("propose drafts"));
  assert.ok(!page.includes("approve (dev)"));
  assert.ok(!authorizePage({ ...view, scopes: ["read"] }).includes("propose drafts"));
  assert.ok(authorizePage({ ...view, devApproveURL: "http://localhost:1/dev?p=x" }).includes("approve (dev)"));
  assert.strictEqual((page.match(/<script>/g) ?? []).length, 1 + 0);
});

Deno.test("errorPage escapes", () => {
  const page = errorPage("<b>", "a & b");
  assert.ok(page.includes("&lt;b&gt;") && page.includes("a &amp; b"));
});

Deno.test("authorize: a registered smc_ client id is accepted and tagged; a CIMD one is tagged cimd", () => {
  const id = "smc_" + "A".repeat(22);
  const r = validateAuthorizeRequest(good({ client_id: id, redirect_uri: "http://localhost:6274/cb" }), MCP);
  assert.ok(r.ok);
  if (r.ok) assert.strictEqual(r.request.clientKind, "registered");
  const c = validateAuthorizeRequest(good(), MCP);
  assert.ok(c.ok);
  if (c.ok) assert.strictEqual(c.request.clientKind, "cimd");
  for (const bad of ["smc_short", "smc_" + "A".repeat(23), "smx_" + "A".repeat(22)]) {
    const x = validateAuthorizeRequest(good({ client_id: bad }), MCP);
    assert.ok(!x.ok && !x.redirectable, bad);
  }
});

Deno.test("registration: good request, defaults, name cut", () => {
  const r = validateRegistrationRequest({
    redirect_uris: ["https://a.example/cb", "http://localhost:6274/oauth/callback", "http://127.0.0.1/cb", "http://[::1]:1/cb"],
    client_name: "  " + "n".repeat(100),
    token_endpoint_auth_method: "none",
    grant_types: ["authorization_code"],
    response_types: ["code"],
  });
  assert.ok(r.ok);
  if (r.ok) assert.strictEqual(r.clientName.length, 80);
  const bare = validateRegistrationRequest({ redirect_uris: ["https://a.example/cb"] });
  assert.ok(bare.ok);
  if (bare.ok) assert.strictEqual(bare.clientName, "MCP client");
});

Deno.test("registration: refusals", () => {
  const ok = { redirect_uris: ["https://a.example/cb"] };
  const bad: unknown[] = [
    null,
    [],
    "x",
    {},
    { redirect_uris: [] },
    { redirect_uris: "https://a.example/cb" },
    { redirect_uris: [1] },
    { redirect_uris: Array.from({ length: 11 }, (_, i) => `https://a.example/${i}`) },
    { redirect_uris: ["http://a.example/cb"] },
    { redirect_uris: ["https://a.example/cb#f"] },
    { redirect_uris: ["not a url"] },
    { redirect_uris: ["javascript:alert(1)"] },
    { ...ok, client_name: 5 },
    { ...ok, token_endpoint_auth_method: "client_secret_basic" },
    { ...ok, grant_types: ["implicit"] },
    { ...ok, grant_types: "authorization_code" },
    { ...ok, response_types: ["token"] },
  ];
  for (const body of bad) {
    const r = validateRegistrationRequest(body);
    assert.ok(!r.ok, JSON.stringify(body));
    if (!r.ok) assert.strictEqual(r.error, "invalid_client_metadata");
  }
});
