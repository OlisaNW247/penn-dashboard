#!/usr/bin/env node
// The production runbook for the agent connection (Claude and other agents
// reading the student's opted-in work list), as code. It PREPARES the deploy;
// nothing here runs until someone with a Supabase Management API token runs
// it, and the token is not enough on its own: deploying is a production
// change that needs Olisa's go (see backend/PROTOCOL.md -> "The agent
// connection" and backend/connector-front/README.md).
//
// Usage:
//   node backend/scripts/deploy-agent.mjs [--step <n>] [--dry-run]
//       [--public-base <url>] [--allow-supabase-host]
//
// What it ships: the functions `agent-auth`, `mcp` (both verify_jwt false:
// a browser and Claude's servers call them with no Supabase token, and mcp's
// bearer is our own opaque token) and `agent-snapshot` (verify_jwt true: the
// phone calls it with its normal session), and the migration
// 20261108090000_agent_connection.sql.
//
// ORDER OF OPERATIONS, and why it is the order: the connector front comes
// FIRST. `LHF_AGENT_PUBLIC_BASE` must point at the deployed front (for
// example https://smooth-agent.vercel.app/functions/v1) BEFORE the functions
// deploy, because the metadata they emit names the issuer and the MCP URL
// from that secret, and every connected client caches what it first reads.
// A function deployed against the wrong base teaches clients a wrong issuer
// that only reconnecting fixes. Claude Code reads discovery documents only
// at the root of the MCP URL's host, which an Edge Function on
// <ref>.supabase.co cannot serve, hence the front.
//
// Steps; with no --step they run in the order 4, 1, 2 and stop at the first
// failure:
//   4  secrets: LHF_AGENT_PUBLIC_BASE must be set (with --public-base <url>
//      this script validates and sets it, then re-reads to confirm). Without
//      it the step fails, unless --allow-supabase-host, which warns that
//      Claude cannot discover the server on <ref>.supabase.co and goes on.
//      Only that one (public) value is ever printed.
//   1  the agent migration (after scanIdempotency passes), then deploy
//      agent-auth, mcp, agent-snapshot, delete-account, in that order.
//   2  smoke checks against the live functions: both metadata documents
//      (issuer == <base>/agent-auth, resource == <base>/mcp), an
//      unauthenticated POST to <base>/mcp must answer 401 with the
//      resource_metadata challenge, and, behind a front, the root
//      .well-known paths must answer the same two documents.
//
// --dry-run prints every request (method, URL, body size, first SQL line) and
// sends nothing; it needs no network. Exit codes: 0 ok, 1 failure.
//
// Token: SUPABASE_ACCESS_TOKEN, or the file in LHF_SUPABASE_TOKEN_FILE
// (default ~/lhf-bench/supabase.token); see deploy-function.mjs.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { deployFunction, describeTokenSource, PROJECT_REF, verifyJwtFor } from "./deploy-function.mjs";
import { firstSqlLine, makeContext, scanIdempotency, StepFailure } from "./deploy-facts.mjs";

const __filename = fileURLToPath(import.meta.url);
const MIGRATIONS_DIR = path.resolve(path.dirname(__filename), "..", "supabase", "migrations");
export const AGENT_MIGRATION = "20261108090000_agent_connection.sql";
/** Every agent migration step 1 applies, in order; a new one goes at the END. */
export const AGENT_MIGRATIONS = [AGENT_MIGRATION, "20261109090000_agent_hardening.sql", "20261109100000_agent_drafts.sql", "20261110090000_agent_uploads.sql"];
/** Deploy order matters only for readability of the log, but it is pinned.
 *  `delete-account` is here because its agent half (`deleteUserData` and
 *  `removeUserDraftObjects` in `_shared/`) changes with the agent code:
 *  found 2026-11-11 (docs/V11_TEST_BACKEND_2026-11-11.md), production still
 *  ran delete-account v13 of 2026-10-22, older than the whole connection, so
 *  account deletion left every open draft's file in Storage. */
export const AGENT_FUNCTIONS = ["agent-auth", "mcp", "agent-snapshot", "delete-account"];
export const PUBLIC_BASE_SECRET = "LHF_AGENT_PUBLIC_BASE";
export const DEFAULT_ORDER = [4, 1, 2];

// --- pure parts ------------------------------------------------------------

/** Returns a list of problems with a candidate public base (empty = fine). */
export function validatePublicBase(value, { allowSupabaseHost = false } = {}) {
  const problems = [];
  let url;
  try {
    url = new URL(value);
  } catch {
    return ["not a URL"];
  }
  if (url.protocol !== "https:") problems.push("must be https");
  if (String(value).endsWith("/")) problems.push("must not end with a slash");
  if (!String(value).endsWith("/functions/v1")) problems.push("must end with /functions/v1");
  if (url.search || url.hash) problems.push("must have no query or fragment");
  if (/(^|\.)supabase\.co$/.test(url.hostname) && !allowSupabaseHost) {
    problems.push("host is *.supabase.co, where Claude cannot discover the server; use the connector front's host (or --allow-supabase-host)");
  }
  return problems;
}

export const issuerFor = (base) => `${base}/agent-auth`;
export const resourceFor = (base) => `${base}/mcp`;
export const challengeMetadataURL = (base) => `${base}/mcp/oauth-protected-resource`;
export const authMetadataURL = (base) => `${base}/agent-auth/.well-known/oauth-authorization-server`;
export const resourceMetadataURL = challengeMetadataURL;

/** `https://host/functions/v1` -> `https://host` */
export function originOf(base) {
  return base.slice(0, -"/functions/v1".length);
}
export const isSupabaseHost = (base) => /(^|\.)supabase\.co$/.test(new URL(base).hostname);

export function checkAuthMetadata(doc, base) {
  const want = issuerFor(base);
  if (!doc || typeof doc !== "object") return [`authorization-server metadata is not a JSON object`];
  return doc.issuer === want ? [] : [`issuer is ${JSON.stringify(doc.issuer)}, expected ${want}`];
}

export function checkResourceMetadata(doc, base) {
  if (!doc || typeof doc !== "object") return [`protected-resource metadata is not a JSON object`];
  const problems = [];
  if (doc.resource !== resourceFor(base)) problems.push(`resource is ${JSON.stringify(doc.resource)}, expected ${resourceFor(base)}`);
  if (!Array.isArray(doc.authorization_servers) || doc.authorization_servers[0] !== issuerFor(base)) {
    problems.push(`authorization_servers[0] is ${JSON.stringify(doc.authorization_servers?.[0])}, expected ${issuerFor(base)}`);
  }
  return problems;
}

/** The unauthenticated POST to /mcp: 401 plus our challenge. */
export function checkChallenge(status, headers, bodyText, base) {
  const get = (n) => (typeof headers?.get === "function" ? headers.get(n) : headers?.[n]) ?? null;
  const challenge = get("www-authenticate");
  const want = `resource_metadata="${challengeMetadataURL(base)}"`;
  if (status === 401 && !challenge && /apikey|api key|jwt/i.test(bodyText ?? "")) {
    return ["the Supabase gateway wants an apikey header; set UPSTREAM_APIKEY on the connector front"];
  }
  if (status !== 401) return [`POST /mcp without Authorization answered HTTP ${status}, expected 401`];
  if (!challenge) return ["401 without a WWW-Authenticate header"];
  return challenge.includes(want) ? [] : [`WWW-Authenticate is ${challenge}, expected it to contain ${want}`];
}

/** Base for the smoke checks: --public-base wins, else the secret's value when
 *  the API returned a URL (it may return a digest instead). */
export function pickBase({ flag, secretValue }) {
  if (flag) return flag;
  return typeof secretValue === "string" && secretValue.startsWith("https://") ? secretValue : undefined;
}

// --- steps -----------------------------------------------------------------

export async function stepSecrets(ctx) {
  ctx.log("== step 4: secrets ==");
  const secretsPath = `/v1/projects/${PROJECT_REF}/secrets`;
  if (ctx.publicBase) {
    const problems = validatePublicBase(ctx.publicBase, { allowSupabaseHost: ctx.allowSupabaseHost });
    if (problems.length > 0) throw new StepFailure(`--public-base ${ctx.publicBase} is not usable: ${problems.join("; ")}`);
    await ctx.management("POST", secretsPath, [{ name: PUBLIC_BASE_SECRET, value: ctx.publicBase }]);
    if (!ctx.dryRun) ctx.log(`${PUBLIC_BASE_SECRET} set to ${ctx.publicBase}`);
  }
  const list = await ctx.management("GET", secretsPath);
  if (ctx.dryRun) return;
  const entry = (Array.isArray(list) ? list : []).find((s) => s?.name === PUBLIC_BASE_SECRET);
  if (!entry) {
    if (ctx.allowSupabaseHost) {
      ctx.log(`warning: ${PUBLIC_BASE_SECRET} is not set; the functions will name <ref>.supabase.co and Claude cannot discover the server there (the connector front is required)`);
      return;
    }
    throw new StepFailure(`${PUBLIC_BASE_SECRET} is not set on the project; pass --public-base <front url>/functions/v1 (the deployed connector front), or --allow-supabase-host to go on without it`);
  }
  ctx.log(`${PUBLIC_BASE_SECRET}: present`);
  if (typeof entry.value === "string" && entry.value.startsWith("https://")) {
    ctx.secretBase = entry.value;
    ctx.log(`${PUBLIC_BASE_SECRET} = ${entry.value}`);
    const problems = validatePublicBase(entry.value, { allowSupabaseHost: ctx.allowSupabaseHost });
    if (problems.length > 0 && !ctx.allowSupabaseHost) throw new StepFailure(`the stored ${PUBLIC_BASE_SECRET} is not usable: ${problems.join("; ")}`);
  }
}

export async function stepMigrateAndDeploy(
  ctx,
  { deploy = deployFunction, sqlPaths = AGENT_MIGRATIONS.map((f) => path.join(MIGRATIONS_DIR, f)) } = {},
) {
  ctx.log("== step 1: migrations, then agent-auth, mcp, agent-snapshot, delete-account ==");
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
  for (const slug of AGENT_FUNCTIONS) {
    try {
      await deploy(slug, { dryRun: ctx.dryRun, fetchImpl: ctx.fetchImpl, log: ctx.log, env: ctx.env });
    } catch (err) {
      throw new StepFailure(err instanceof Error ? err.message : String(err));
    }
  }
}

async function getJson(ctx, url) {
  const res = await ctx.fetchImpl(url, { method: "GET" });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  return { status: res.status, json, text };
}

export async function stepSmoke(ctx) {
  ctx.log("== step 2: smoke checks ==");
  const base = pickBase({ flag: ctx.publicBase, secretValue: ctx.secretBase });
  if (ctx.dryRun) {
    const b = base ?? `<${PUBLIC_BASE_SECRET}>`;
    ctx.log(`[dry-run] GET ${b}/agent-auth/.well-known/oauth-authorization-server`);
    ctx.log(`[dry-run] GET ${b}/mcp/oauth-protected-resource`);
    ctx.log(`[dry-run] POST ${b}/mcp (body 2 bytes, no Authorization; expect 401 + resource_metadata challenge)`);
    ctx.log(`[dry-run] if the base is not on supabase.co: GET <origin>/.well-known/oauth-protected-resource/functions/v1/mcp and <origin>/.well-known/oauth-authorization-server/functions/v1/agent-auth`);
    return;
  }
  if (!base) throw new StepFailure(`cannot tell the public base (the secret's value is not readable); pass --public-base <url>`);
  const problems = [];
  const note = (label, list) => {
    if (list.length === 0) ctx.log(`ok: ${label}`);
    for (const p of list) problems.push(`${label}: ${p}`);
  };

  const auth = await getJson(ctx, `${base}/agent-auth/.well-known/oauth-authorization-server`);
  note("authorization-server metadata", auth.status === 200 ? checkAuthMetadata(auth.json, base) : [`HTTP ${auth.status} ${auth.text.slice(0, 200)}`]);
  const res = await getJson(ctx, `${base}/mcp/oauth-protected-resource`);
  note("protected-resource metadata", res.status === 200 ? checkResourceMetadata(res.json, base) : [`HTTP ${res.status} ${res.text.slice(0, 200)}`]);

  const post = await ctx.fetchImpl(`${base}/mcp`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  note("unauthenticated POST /mcp", checkChallenge(post.status, post.headers, await post.text(), base));

  if (!isSupabaseHost(base)) {
    const origin = originOf(base);
    const root = await getJson(ctx, `${origin}/.well-known/oauth-protected-resource/functions/v1/mcp`);
    note("front root protected-resource metadata", root.status === 200 ? checkResourceMetadata(root.json, base) : [`HTTP ${root.status}`]);
    const rootAuth = await getJson(ctx, `${origin}/.well-known/oauth-authorization-server/functions/v1/agent-auth`);
    note("front root authorization-server metadata", rootAuth.status === 200 ? checkAuthMetadata(rootAuth.json, base) : [`HTTP ${rootAuth.status}`]);
  }
  if (problems.length > 0) throw new StepFailure(problems.join("\n"));
}

export const STEPS = { 1: stepMigrateAndDeploy, 2: stepSmoke, 4: stepSecrets };

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
  let publicBase;
  let allowSupabaseHost = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dry-run") dryRun = true;
    else if (argv[i] === "--allow-supabase-host") allowSupabaseHost = true;
    else if (argv[i] === "--step") step = Number(argv[++i]);
    else if (argv[i] === "--public-base") publicBase = argv[++i];
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (step !== undefined && !Object.hasOwn(STEPS, step)) throw new Error("--step must be 1, 2 or 4");
  if (argv.includes("--public-base") && !publicBase) throw new Error("--public-base needs a value");
  return { steps: step === undefined ? DEFAULT_ORDER : [step], dryRun, publicBase, allowSupabaseHost };
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    console.error("Usage: node backend/scripts/deploy-agent.mjs [--step <1|2|4>] [--dry-run] [--public-base <url>] [--allow-supabase-host]");
    process.exit(1);
  }
  const ctx = makeContext({ dryRun: parsed.dryRun });
  ctx.publicBase = parsed.publicBase;
  ctx.allowSupabaseHost = parsed.allowSupabaseHost;
  process.exit(await run(parsed.steps, ctx));
}
