// Pure-part and stubbed-fetch tests for deploy-agent.mjs. Nothing touches the network.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  AGENT_FUNCTIONS,
  AGENT_MIGRATION,
  checkAuthMetadata,
  checkChallenge,
  checkResourceMetadata,
  originOf,
  parseArgs,
  run,
  stepMigrateAndDeploy,
  stepSecrets,
  validatePublicBase,
} from "./deploy-agent.mjs";
import { makeContext } from "./deploy-facts.mjs";
import { verifyJwtFor } from "./deploy-function.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const BASE = "https://smooth-agent.deno.dev/functions/v1";

function recorder(handler) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method ?? "GET", body: init.body });
    const r = handler(String(url), init);
    return new Response(typeof r.body === "string" ? r.body : JSON.stringify(r.body ?? null), { status: r.status ?? 200, headers: r.headers });
  };
  return { calls, fetchImpl };
}
function ctxFor(opts = {}, extra = {}) {
  const lines = [];
  const ctx = makeContext({ ...opts, log: (l) => lines.push(l), env: { SUPABASE_ACCESS_TOKEN: "tok-secret-123" } });
  Object.assign(ctx, { publicBase: undefined, allowSupabaseHost: false }, extra);
  return { ctx, lines };
}

test("the agent migration exists and is idempotent", async () => {
  const { scanIdempotency } = await import("./deploy-facts.mjs");
  const sql = fs.readFileSync(path.join(here, "..", "supabase", "migrations", AGENT_MIGRATION), "utf8");
  assert.deepEqual(scanIdempotency(sql), []);
});

test("validatePublicBase", () => {
  assert.deepEqual(validatePublicBase(BASE), []);
  assert.ok(validatePublicBase("http://smooth-agent.deno.dev/functions/v1").some((p) => /https/.test(p)));
  assert.ok(validatePublicBase(`${BASE}/`).some((p) => /slash/.test(p)));
  assert.ok(validatePublicBase("https://smooth-agent.deno.dev").some((p) => /functions\/v1/.test(p)));
  assert.ok(validatePublicBase("nonsense").length > 0);
  const sb = "https://ynetfjixexksxqrrkwsg.supabase.co/functions/v1";
  assert.ok(validatePublicBase(sb).some((p) => /supabase\.co/.test(p)));
  assert.deepEqual(validatePublicBase(sb, { allowSupabaseHost: true }), []);
});

test("metadata checks", () => {
  assert.deepEqual(checkAuthMetadata({ issuer: `${BASE}/agent-auth` }, BASE), []);
  assert.equal(checkAuthMetadata({ issuer: "https://x/functions/v1/agent-auth" }, BASE).length, 1);
  assert.deepEqual(checkResourceMetadata({ resource: `${BASE}/mcp`, authorization_servers: [`${BASE}/agent-auth`] }, BASE), []);
  assert.equal(checkResourceMetadata({ resource: `${BASE}/mcp/`, authorization_servers: [`${BASE}/agent-auth`] }, BASE).length, 1);
  assert.equal(checkResourceMetadata({ resource: `${BASE}/mcp`, authorization_servers: ["other"] }, BASE).length, 1);
  assert.equal(originOf(BASE), "https://smooth-agent.deno.dev");
});

test("challenge check", () => {
  const good = new Headers({ "WWW-Authenticate": `Bearer resource_metadata="${BASE}/mcp/oauth-protected-resource", scope="read draft"` });
  assert.deepEqual(checkChallenge(401, good, "{}", BASE), []);
  assert.equal(checkChallenge(200, good, "{}", BASE).length, 1);
  assert.equal(checkChallenge(401, new Headers(), "{}", BASE).length, 1);
  const wrong = new Headers({ "WWW-Authenticate": 'Bearer resource_metadata="https://elsewhere/x"' });
  assert.equal(checkChallenge(401, wrong, "{}", BASE).length, 1);
  const gw = checkChallenge(401, new Headers(), '{"message":"Missing authorization header / No API key found"}', BASE);
  assert.match(gw[0], /UPSTREAM_APIKEY/);
});

test("deploy order and verify_jwt", async () => {
  assert.deepEqual(AGENT_FUNCTIONS, ["agent-auth", "mcp", "agent-snapshot"]);
  assert.deepEqual(AGENT_FUNCTIONS.map((s) => verifyJwtFor(s)), [false, false, true]);
  const { ctx } = ctxFor({ dryRun: true });
  const seen = [];
  await stepMigrateAndDeploy(ctx, { deploy: async (slug) => seen.push(slug) });
  assert.deepEqual(seen, AGENT_FUNCTIONS);
});

test("default order, and the dry run sends nothing", async () => {
  assert.deepEqual(parseArgs([]).steps, [4, 1, 2]);
  assert.throws(() => parseArgs(["--step", "3"]));
  const { calls, fetchImpl } = recorder(() => ({}));
  const { ctx, lines } = ctxFor({ dryRun: true, fetchImpl });
  assert.equal(await run([4, 1, 2], ctx), 0);
  assert.equal(calls.length, 0);
  const text = lines.join("\n");
  assert.match(text, /\[dry-run\] GET https:\/\/api\.supabase\.com\/v1\/projects\/\S+\/secrets/);
  assert.match(text, /\[dry-run\] POST https:\/\/api\.supabase\.com\/v1\/projects\/\S+\/database\/query .*sql first line/);
  for (const s of AGENT_FUNCTIONS) assert.match(text, new RegExp(`Deploying slug "${s}"`));
  assert.ok(text.indexOf('slug "agent-auth"') < text.indexOf('slug "mcp"') && text.indexOf('slug "mcp"') < text.indexOf('slug "agent-snapshot"'));
  assert.ok(!text.includes("tok-secret-123"));
});

test("step 4 fails clearly when the secret is missing, passes with the flag", async () => {
  let r = recorder(() => ({ body: [{ name: "OPENROUTER_API_KEY", value: "sk-hidden" }] }));
  let { ctx, lines } = ctxFor({ fetchImpl: r.fetchImpl });
  assert.equal(await run([4], ctx), 1);
  assert.match(lines.join("\n"), /LHF_AGENT_PUBLIC_BASE is not set.*--public-base/);
  assert.ok(!lines.join("\n").includes("sk-hidden"));
  ({ ctx, lines } = ctxFor({ fetchImpl: r.fetchImpl }, { allowSupabaseHost: true }));
  assert.equal(await run([4], ctx), 0);
  assert.match(lines.join("\n"), /warning/);
});

test("step 4 with --public-base validates, posts the secret, re-reads", async () => {
  const bad = ctxFor({ fetchImpl: recorder(() => ({})).fetchImpl }, { publicBase: "http://x/functions/v1" });
  assert.equal(await run([4], bad.ctx), 1);
  let stored = [];
  const r = recorder((url, init) => {
    if (init.method === "POST") { stored = JSON.parse(init.body); return { body: {} }; }
    return { body: [{ name: "LHF_AGENT_PUBLIC_BASE", value: stored[0]?.value }] };
  });
  const { ctx } = ctxFor({ fetchImpl: r.fetchImpl }, { publicBase: BASE });
  assert.equal(await run([4], ctx), 0);
  assert.deepEqual(stored, [{ name: "LHF_AGENT_PUBLIC_BASE", value: BASE }]);
  assert.deepEqual(r.calls.map((c) => c.method), ["POST", "GET"]);
  assert.equal(ctx.secretBase, BASE);
});

test("step 2 against a healthy front passes, and reports a gateway apikey failure", async () => {
  const auth = { issuer: `${BASE}/agent-auth` };
  const res = { resource: `${BASE}/mcp`, authorization_servers: [`${BASE}/agent-auth`] };
  const healthy = recorder((url, init) => {
    if (init.method === "POST") return { status: 401, body: {}, headers: { "WWW-Authenticate": `Bearer resource_metadata="${BASE}/mcp/oauth-protected-resource"` } };
    return { body: url.includes("authorization-server") ? auth : res };
  });
  let c = ctxFor({ fetchImpl: healthy.fetchImpl }, { publicBase: BASE });
  assert.equal(await run([2], c.ctx), 0);
  assert.equal(healthy.calls.length, 5);
  const gw = recorder((url, init) => init.method === "POST" ? { status: 401, body: { message: "No API key found in request" } } : { body: url.includes("authorization-server") ? auth : res });
  c = ctxFor({ fetchImpl: gw.fetchImpl }, { publicBase: BASE });
  assert.equal(await run([2], c.ctx), 1);
  assert.match(c.lines.join("\n"), /set UPSTREAM_APIKEY on the connector front/);
});
