// The production gate on deploy-function.mjs: `ask` needs --production,
// everything else (and --from ask / --also ask) does not. All dry runs: no
// network, no token.
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { deployFunction, verifyJwtFor } from "./deploy-function.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const quiet = { dryRun: true, log: () => {}, env: {} };

test("deploying `ask` is refused without production, and the message quotes the rule", async () => {
  await assert.rejects(
    deployFunction("ask", quiet),
    (err) => /refusing to deploy "ask"/.test(err.message) && /needs a person's go/.test(err.message),
  );
});

test("deploying `ask` with production goes through (dry run)", async () => {
  await deployFunction("ask", { ...quiet, production: true });
});

test("ask-canary, --from ask and --also ask are not gated", async () => {
  await deployFunction("ask-canary", { ...quiet, also: ["ask"] });
  await deployFunction("ask-canary", { ...quiet, from: "ask" });
});

test("the CLI refuses `ask` without --production, exits non-zero, and sends nothing", () => {
  const run = spawnSync(process.execPath, [path.join(here, "deploy-function.mjs"), "ask"], { encoding: "utf8", env: { PATH: process.env.PATH } });
  assert.notEqual(run.status, 0);
  assert.match(run.stderr, /refusing to deploy "ask"/);
});

test("the usage text names --production", () => {
  const run = spawnSync(process.execPath, [path.join(here, "deploy-function.mjs")], { encoding: "utf8", env: { PATH: process.env.PATH } });
  assert.match(run.stderr, /--production/);
});


// The agent connection's two functions are the only ones the gateway must
// not guard (their callers hold no Supabase JWT); every other slug keeps the
// `verify_jwt: true` this script always sent, and only an explicit flag
// changes that.
test("mcp and agent-auth deploy with verify_jwt false, everything else true unless --no-verify-jwt", async () => {
  assert.equal(verifyJwtFor("mcp"), false);
  assert.equal(verifyJwtFor("agent-auth"), false);
  assert.equal(verifyJwtFor("sync"), true);
  assert.equal(verifyJwtFor("sync", true), false);
  const plan = await deployFunction("mcp", quiet);
  assert.equal(plan.verifyJwt, false);
  const sync = await deployFunction("sync", quiet);
  assert.equal(sync.verifyJwt, true);
});
