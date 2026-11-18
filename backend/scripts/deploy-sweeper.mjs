#!/usr/bin/env node
// The production runbook for the Sweeper wake (backend/PROTOCOL.md -> "The
// Sweeper wake"; docs/SERVER_SWEEPER_DESIGN_2026-11-17.md), as code. It
// PREPARES the deploy: nothing here runs until someone with a Supabase
// Management API token runs it, and deploying is a production change that
// needs a person's go (Olisa's APNs key must be in the secrets first).
//
// Usage:
//   node backend/scripts/deploy-sweeper.mjs [--step <n>] [--dry-run]
//
// Steps; with no --step they run in the order 4, 1, 3 and stop at the first
// failure:
//   4  secrets: reads the NAMES of the project's function secrets (the API
//      also returns a digest of each value, which this script never prints)
//      and reports which of the eight the wake needs are set. It fails when
//      the tick secret or the team id is missing, or when neither APNs
//      environment has its key and key id; one environment alone is a
//      warning, because the first probe is sandbox-only.
//   1  the migration 20261118090000_sweeper_wake.sql (after scanIdempotency
//      passes), then deploys sweeper-wake (verify_jwt false, see
//      deploy-function.mjs PUBLIC_SLUGS) and delete-account (whose
//      deleteUserData now removes the wake rows; deploying only the new
//      function would leave production delete-account at the old code, the
//      trap recorded for the agent connection).
//   3  the two Vault secrets the cron job reads (names only, never values):
//      `sweeper_wake_tick_url` and `sweeper_wake_tick_secret`. Reports which
//      exist. They are created BY HAND, once:
//        select vault.create_secret('<https://<ref>.supabase.co/functions/v1/sweeper-wake/tick>', 'sweeper_wake_tick_url');
//        select vault.create_secret('<the same value as LHF_SWEEPER_TICK_SECRET>', 'sweeper_wake_tick_secret');
//      Until both exist the job runs and fails quietly (cron.job_run_details).
//
// --dry-run prints every request (method, URL, body size, first SQL line) and
// sends nothing; it needs no network. Exit codes: 0 ok, 1 failure.
//
// Token: SUPABASE_ACCESS_TOKEN, or the file in LHF_SUPABASE_TOKEN_FILE
// (default ~/lhf-bench/supabase.token); see deploy-function.mjs.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { deployFunction, describeTokenSource, PROJECT_REF } from "./deploy-function.mjs";
import { makeContext, scanIdempotency, StepFailure } from "./deploy-facts.mjs";

const __filename = fileURLToPath(import.meta.url);
const MIGRATIONS_DIR = path.resolve(path.dirname(__filename), "..", "supabase", "migrations");
export const SWEEPER_MIGRATION = "20261118090000_sweeper_wake.sql";
export const SWEEPER_MIGRATIONS = [SWEEPER_MIGRATION];
/** `delete-account` is here because `deleteUserData` (in `_shared/db.ts`) gained the wake table. */
export const SWEEPER_FUNCTIONS = ["sweeper-wake", "delete-account"];

export const REQUIRED_SECRETS = ["LHF_SWEEPER_TICK_SECRET", "LHF_APNS_TEAM_ID"];
export const ENVIRONMENT_SECRETS = {
  production: ["LHF_APNS_KEY_P8_PRODUCTION", "LHF_APNS_KEY_ID_PRODUCTION"],
  sandbox: ["LHF_APNS_KEY_P8_SANDBOX", "LHF_APNS_KEY_ID_SANDBOX"],
};
export const OPTIONAL_SECRETS = ["LHF_APNS_TOPIC", "LHF_SWEEPER_WAKE_DISABLED"];
/** All eight names, the contract the function reads. */
export const SECRET_NAMES = [...REQUIRED_SECRETS, ...ENVIRONMENT_SECRETS.production, ...ENVIRONMENT_SECRETS.sandbox, ...OPTIONAL_SECRETS];
export const VAULT_SECRETS = ["sweeper_wake_tick_url", "sweeper_wake_tick_secret"];
export const DEFAULT_ORDER = [4, 1, 3];

// --- pure parts ------------------------------------------------------------

/** Which wake secrets the project has, from the Management API's list. Names
 *  only: whatever else an entry carries (a value digest) is dropped here. */
export function sweeperSecretsReport(list) {
  const present = new Set((Array.isArray(list) ? list : []).map((s) => s?.name).filter((n) => typeof n === "string"));
  const has = (n) => present.has(n);
  const problems = [];
  const warnings = [];
  for (const n of REQUIRED_SECRETS) if (!has(n)) problems.push(`${n} is not set`);
  const complete = Object.entries(ENVIRONMENT_SECRETS).filter(([, names]) => names.every(has)).map(([env]) => env);
  if (complete.length === 0) problems.push(`neither APNs environment has both its key and key id (${Object.values(ENVIRONMENT_SECRETS).flat().join(", ")})`);
  else if (complete.length === 1) warnings.push(`only the ${complete[0]} APNs key is set; ${complete[0] === "production" ? "development" : "production"} installs will not be woken`);
  for (const [env, names] of Object.entries(ENVIRONMENT_SECRETS)) {
    const some = names.filter(has);
    if (some.length > 0 && some.length < names.length) problems.push(`the ${env} APNs key is half set (${some.join(", ")} without the other)`);
  }
  return { present: SECRET_NAMES.map((n) => [n, has(n)]), problems, warnings };
}

// --- steps -----------------------------------------------------------------

export async function stepSecrets(ctx) {
  ctx.log("== step 4: secrets ==");
  const list = await ctx.management("GET", `/v1/projects/${PROJECT_REF}/secrets`);
  if (ctx.dryRun) return;
  const report = sweeperSecretsReport(list);
  for (const [name, set] of report.present) ctx.log(`${name}: ${set ? "set" : OPTIONAL_SECRETS.includes(name) ? "not set (default applies)" : "MISSING"}`);
  for (const w of report.warnings) ctx.log(`warning: ${w}`);
  if (report.problems.length > 0) throw new StepFailure(report.problems.join("\n"));
}

export async function stepMigrateAndDeploy(
  ctx,
  { deploy = deployFunction, sqlPaths = SWEEPER_MIGRATIONS.map((f) => path.join(MIGRATIONS_DIR, f)) } = {},
) {
  ctx.log("== step 1: migration, then sweeper-wake, delete-account ==");
  const loaded = sqlPaths.map((p) => ({ name: path.basename(p), sql: fs.readFileSync(p, "utf8") }));
  for (const { name, sql } of loaded) {
    const problems = scanIdempotency(sql);
    if (problems.length > 0) {
      throw new StepFailure(`migration ${name} is not idempotent:\n${problems.map(([n, l]) => `  line ${n}: ${l}`).join("\n")}`);
    }
    ctx.log(`migration scan: ${name} idempotent (${sql.split("\n").length} lines)`);
  }
  for (const { name, sql } of loaded) {
    await ctx.sql(sql);
    if (!ctx.dryRun) ctx.log(`migration applied: ${name}`);
  }
  for (const slug of SWEEPER_FUNCTIONS) {
    try {
      await deploy(slug, { dryRun: ctx.dryRun, fetchImpl: ctx.fetchImpl, log: ctx.log, env: ctx.env });
    } catch (err) {
      throw new StepFailure(err instanceof Error ? err.message : String(err));
    }
  }
}

/** Reads only the secrets' names from Vault, never `decrypted_secret`. */
export async function stepVault(ctx) {
  ctx.log("== step 3: vault secrets for the cron job ==");
  const names = VAULT_SECRETS.map((n) => `'${n}'`).join(", ");
  const rows = await ctx.sql(`select name from vault.secrets where name in (${names})`);
  if (ctx.dryRun) return;
  const have = new Set((Array.isArray(rows) ? rows : []).map((r) => r?.name));
  const missing = VAULT_SECRETS.filter((n) => !have.has(n));
  for (const n of VAULT_SECRETS) ctx.log(`vault ${n}: ${have.has(n) ? "present" : "MISSING"}`);
  if (missing.length > 0) {
    throw new StepFailure(
      `the tick job reads ${missing.join(", ")} from Vault and they do not exist; create them once with vault.create_secret(<value>, <name>): the url is <project url>/functions/v1/sweeper-wake/tick, the secret is the same value as the function secret LHF_SWEEPER_TICK_SECRET`,
    );
  }
}

export const STEPS = { 1: stepMigrateAndDeploy, 3: stepVault, 4: stepSecrets };

export async function run(stepNumbers, ctx) {
  ctx.log(describeTokenSource(ctx.tokenSource));
  if (ctx.dryRun) ctx.log("[dry-run] nothing below is sent");
  for (const n of stepNumbers) {
    try {
      await STEPS[n](ctx);
    } catch (err) {
      ctx.log(`STOPPED at step ${n}: ${err instanceof Error ? err.message : String(err)}`);
      return err instanceof StepFailure ? err.exitCode : 1;
    }
  }
  ctx.log(ctx.dryRun ? "[dry-run] done" : "all requested steps passed");
  return 0;
}

export function parseArgs(argv) {
  let step;
  let dryRun = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dry-run") dryRun = true;
    else if (argv[i] === "--step") step = Number(argv[++i]);
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (step !== undefined && !Object.hasOwn(STEPS, step)) throw new Error("--step must be 1, 3 or 4");
  return { steps: step === undefined ? DEFAULT_ORDER : [step], dryRun };
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    console.error("Usage: node backend/scripts/deploy-sweeper.mjs [--step <1|3|4>] [--dry-run]");
    process.exit(1);
  }
  const ctx = makeContext({ dryRun: parsed.dryRun });
  process.exit(await run(parsed.steps, ctx));
}
