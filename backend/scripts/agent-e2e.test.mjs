import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { cookieFrom, makePKCE, mask, parseArgs, parseAuthorizePage, parseChallenge, parseMcpBody, run } from "./agent-e2e.mjs";

// Shaped like authorizePage()'s output (backend/supabase/functions/_shared/agentAuth.ts).
const PAGE = `<body><main>
<h1>Smooth e2e (registered client) wants to read your classes and work</h1>
<div class="label">code</div><div class="code">BCDF-GHJK</div>
<div class="label">Smooth will ask you to pick this number</div><div class="num">42</div>
<a class="btn" role="button" href="smooth://link?c=abc_DEF-123">Open Smooth</a>
</main></body>`;

test("PKCE challenge is the S256 of the verifier", () => {
  const { verifier, challenge } = makePKCE(Buffer.alloc(32, 7));
  assert.equal(verifier.length, 43);
  assert.equal(challenge, crypto.createHash("sha256").update(verifier).digest("base64url"));
});

test("parseChallenge reads resource_metadata and scope", () => {
  const c = parseChallenge('Bearer error="invalid_token", resource_metadata="https://x/y", scope="read draft"');
  assert.equal(c.resource_metadata, "https://x/y");
  assert.equal(c.scope, "read draft");
  assert.equal(c.error, "invalid_token");
  assert.deepEqual(parseChallenge(null), {});
});

test("parseMcpBody reads JSON and SSE", () => {
  assert.equal(parseMcpBody('{"jsonrpc":"2.0","id":1,"result":{"a":1}}').result.a, 1);
  const sse = 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"a":2}}\n\n';
  assert.equal(parseMcpBody(sse).result.a, 2);
  assert.throws(() => parseMcpBody("event: ping\n\n"));
});

test("parseAuthorizePage extracts id, code and number", () => {
  assert.deepEqual(parseAuthorizePage(PAGE), { pendingId: "abc_DEF-123", userCode: "BCDF-GHJK", matchNumber: 42 });
  assert.throws(() => parseAuthorizePage("<html></html>"));
});

test("cookieFrom finds the nonce among several Set-Cookie values", () => {
  const list = ["x=1; Path=/", "sa_abc=NONCE; HttpOnly; Secure; Path=/functions/v1/agent-auth"];
  assert.equal(cookieFrom(list, "sa_abc"), "NONCE");
  assert.equal(cookieFrom(list, "sa_zzz"), null);
  assert.equal(cookieFrom("sa_abc=N2; Path=/", "sa_abc"), "N2");
});

test("mask never shows more than a prefix; parseArgs", () => {
  assert.equal(mask("smt_a_" + "x".repeat(43)), "smt_a_… (49 chars)");
  assert.equal(parseArgs(["--base", "https://h/functions/v1/"]).base, "https://h/functions/v1");
  assert.equal(parseArgs(["--dry-run"]).dryRun, true);
  assert.throws(() => parseArgs(["--nope"]));
});

test("--dry-run sends nothing", async () => {
  const lines = [];
  const code = await run(["--dry-run"], { fetchImpl: () => { throw new Error("network"); }, log: (l) => lines.push(l) });
  assert.equal(code, 0);
  assert.ok(lines.length >= 10);
});
