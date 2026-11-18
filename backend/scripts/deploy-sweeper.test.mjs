// Pure-part and stubbed-fetch tests for deploy-sweeper.mjs. Nothing touches the network.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_ORDER,
  parseArgs,
  run,
  SECRET_NAMES,
  stepMigrateAndDeploy,
  SWEEPER_FUNCTIONS,
  SWEEPER_MIGRATIONS,
  sweeperSecretsReport,
  VAULT_SECRETS,
} from "./deploy-sweeper.mjs";
import { makeContext, scanIdempotency } from "./deploy-facts.mjs";
import { verifyJwtFor } from "./deploy-function.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

function recorder(handler) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method ?? "GET", body: init.body });
    const r = handler(String(url), init);
    return new Response(JSON.stringify(r.body ?? null), { status: r.status ?? 200 });
  };
  return { calls, fetchImpl };
}
function ctxFor(opts = {}) {
  const lines = [];
  const ctx = makeContext({ ...opts, log: (l) => lines.push(l), env: { SUPABASE_ACCESS_TOKEN: "tok-secret-123" } });
  return { ctx, lines };
}
const named = (...names) => names.map((name) => ({ name, value: `digest-of-${name}` }));

test("the migration exists, is idempotent and is the one step 1 applies", () => {
  assert.deepEqual(SWEEPER_MIGRATIONS, ["20261118090000_sweeper_wake.sql"]);
  const sql = fs.readFileSync(path.join(here, "..", "supabase", "migrations", SWEEPER_MIGRATIONS[0]), "utf8");
  assert.deepEqual(scanIdempotency(sql), []);
});

test("the eight secret names are the contract", () => {
  assert.deepEqual([...SECRET_NAMES].sort(), [
    "LHF_APNS_KEY_ID_PRODUCTION",
    "LHF_APNS_KEY_ID_SANDBOX",
    "LHF_APNS_KEY_P8_PRODUCTION",
    "LHF_APNS_KEY_P8_SANDBOX",
    "LHF_APNS_TEAM_ID",
    "LHF_APNS_TOPIC",
    "LHF_SWEEPER_TICK_SECRET",
    "LHF_SWEEPER_WAKE_DISABLED",
  ]);
  const source = fs.readFileSync(path.join(here, "..", "supabase", "functions", "_shared", "apns.ts"), "utf8");
  for (const n of SECRET_NAMES.filter((n) => n.startsWith("LHF_APNS_") && !n.includes("PRODUCTION") && !n.includes("SANDBOX"))) assert.ok(source.includes(n), n);
});

test("secrets report: complete, one environment, missing, half-set; values never appear", () => {
  const all = ["LHF_SWEEPER_TICK_SECRET", "LHF_APNS_TEAM_ID", "LHF_APNS_KEY_P8_PRODUCTION", "LHF_APNS_KEY_ID_PRODUCTION", "LHF_APNS_KEY_P8_SANDBOX", "LHF_APNS_KEY_ID_SANDBOX"];
  let r = sweeperSecretsReport(named(...all));
  assert.deepEqual(r.problems, []);
  assert.deepEqual(r.warnings, []);
  r = sweeperSecretsReport(named(...all.filter((n) => !n.includes("PRODUCTION"))));
  assert.deepEqual(r.problems, []);
  assert.equal(r.warnings.length, 1);
  assert.match(r.warnings[0], /sandbox/);
  r = sweeperSecretsReport(named("LHF_APNS_TEAM_ID"));
  assert.equal(r.problems.length, 2);
  assert.match(r.problems.join("\n"), /LHF_SWEEPER_TICK_SECRET is not set/);
  r = sweeperSecretsReport(named(...all.filter((n) => n !== "LHF_APNS_KEY_ID_PRODUCTION")));
  assert.match(r.problems.join("\n"), /production APNs key is half set/);
  assert.ok(!JSON.stringify(sweeperSecretsReport(named(...all))).includes("digest-of"));
  assert.deepEqual(sweeperSecretsReport(undefined).present.filter(([, s]) => s), []);
});

test("deploy order, verify_jwt, and the default step order", async () => {
  assert.deepEqual(SWEEPER_FUNCTIONS, ["sweeper-wake", "delete-account"]);
  assert.deepEqual(SWEEPER_FUNCTIONS.map((s) => verifyJwtFor(s)), [false, true]);
  assert.deepEqual(DEFAULT_ORDER, [4, 1, 3]);
  assert.deepEqual(parseArgs([]).steps, [4, 1, 3]);
  assert.throws(() => parseArgs(["--step", "2"]));
  assert.throws(() => parseArgs(["--public-base", "x"]));
  const { ctx } = ctxFor({ dryRun: true });
  const seen = [];
  await stepMigrateAndDeploy(ctx, { deploy: async (slug) => seen.push(slug) });
  assert.deepEqual(seen, SWEEPER_FUNCTIONS);
});

test("the dry run sends nothing and never prints the token", async () => {
  const { calls, fetchImpl } = recorder(() => ({}));
  const { ctx, lines } = ctxFor({ dryRun: true, fetchImpl });
  assert.equal(await run(DEFAULT_ORDER, ctx), 0);
  assert.equal(calls.length, 0);
  const text = lines.join("\n");
  assert.match(text, /\[dry-run\] GET https:\/\/api\.supabase\.com\/v1\/projects\/\S+\/secrets/);
  assert.match(text, /\[dry-run\] POST .*database\/query .*sql first line/);
  assert.match(text, /Deploying slug "sweeper-wake"/);
  assert.ok(text.indexOf('slug "sweeper-wake"') < text.indexOf('slug "delete-account"'));
  assert.ok(!text.includes("tok-secret-123"));
});

test("step 4 fails clearly when the tick secret is missing", async () => {
  const r = recorder(() => ({ body: named("LHF_APNS_TEAM_ID") }));
  const { ctx, lines } = ctxFor({ fetchImpl: r.fetchImpl });
  assert.equal(await run([4], ctx), 1);
  assert.match(lines.join("\n"), /LHF_SWEEPER_TICK_SECRET is not set/);
  assert.ok(!lines.join("\n").includes("digest-of"));
});

test("step 3 reads only vault names and fails naming the missing ones", async () => {
  let r = recorder(() => ({ body: [{ name: VAULT_SECRETS[0] }] }));
  let c = ctxFor({ fetchImpl: r.fetchImpl });
  assert.equal(await run([3], c.ctx), 1);
  const sent = JSON.parse(r.calls[0].body).query;
  assert.match(sent, /select name from vault\.secrets/);
  assert.ok(!/decrypted_secret/.test(sent));
  assert.match(c.lines.join("\n"), /sweeper_wake_tick_secret/);
  r = recorder(() => ({ body: VAULT_SECRETS.map((name) => ({ name })) }));
  c = ctxFor({ fetchImpl: r.fetchImpl });
  assert.equal(await run([3], c.ctx), 0);
});
