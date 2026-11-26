import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import {
  cookieFrom, draftIdFrom, makePKCE, mask, parseArgs, parseAuthorizePage, parseChallenge, parseMcpBody, run, RUN_ORDER, STEPS,
  TEST_ASSIGNMENT_ID, testFileBytes, testSnapshot, sha256Hex, splitChunks, uploadInfoFrom,
} from "./agent-e2e.mjs";

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

test("draftIdFrom reads propose_submission's text, and nothing else", () => {
  assert.equal(draftIdFrom("draft smd_abcDEF_-0123456789abcd proposed"), "smd_abcDEF_-0123456789abcd");
  assert.equal(draftIdFrom("draft smd_x1 proposed (20480 bytes decoded in 3 ms)"), "smd_x1");
  assert.equal(draftIdFrom("too many open drafts"), null);
  assert.equal(draftIdFrom(undefined), null);
});

test("the test file is deterministic and 20 KB; the snapshot names the test assignment", () => {
  const a = testFileBytes(), b = testFileBytes();
  assert.equal(a.length, 20480);
  assert.ok(a.equals(b));
  assert.ok(Buffer.from(a.toString("base64"), "base64").equals(a));
  const snap = testSnapshot(new Date("2026-11-10T00:00:00Z"));
  assert.equal(snap.workList[0].id, TEST_ASSIGNMENT_ID);
  assert.equal(snap.workList[0].dueAt, "2026-11-11T00:00:00.000Z");
  // Nothing the snapshot validator forbids.
  assert.ok(!JSON.stringify(snap).match(/"(score|grade|points|firstName|email)"/i));
});

test("splitChunks: 16 KB pieces with their own sha256, the last short, and they reassemble", () => {
  const file = testFileBytes(40_000);
  const parts = splitChunks(file);
  assert.deepEqual(parts.map((p) => p.index), [0, 1, 2]);
  assert.deepEqual(parts.map((p) => Buffer.from(p.base64, "base64").length), [16384, 16384, 7232]);
  for (const p of parts) assert.equal(p.sha256, sha256Hex(Buffer.from(p.base64, "base64")));
  assert.ok(Buffer.concat(parts.map((p) => Buffer.from(p.base64, "base64"))).equals(file));
  assert.equal(splitChunks(Buffer.alloc(16384)).length, 1);
  assert.equal(splitChunks(Buffer.alloc(0)).length, 0);
  assert.equal(sha256Hex(Buffer.from("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("uploadInfoFrom reads begin_file_upload's first line only", () => {
  const info = uploadInfoFrom('{"upload_id":"smu_x","chunk_bytes":16384,"chunks":7}\nfastest: PUT the raw bytes');
  assert.equal(info.upload_id, "smu_x");
  assert.equal(info.chunks, 7);
  assert.equal(uploadInfoFrom("no such assignment"), null);
  assert.equal(uploadInfoFrom('{"x":1}'), null);
  assert.equal(uploadInfoFrom(undefined), null);
});

test("RUN_ORDER runs every step once, drafts before the revoke and cleanup last", () => {
  assert.deepEqual([...RUN_ORDER].sort((x, y) => x - y), STEPS.map((_, i) => i));
  assert.ok(RUN_ORDER.indexOf(11) < RUN_ORDER.indexOf(8));
  assert.ok(RUN_ORDER.indexOf(10) < RUN_ORDER.indexOf(7));
  assert.ok(RUN_ORDER.indexOf(11) < RUN_ORDER.indexOf(13) && RUN_ORDER.indexOf(13) < RUN_ORDER.indexOf(8));
  assert.equal(RUN_ORDER.at(-1), 9);
});
