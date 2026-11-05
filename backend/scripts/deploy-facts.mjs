#!/usr/bin/env node
// The production runbook for the `extract-facts` work, as code. It PREPARES
// the deploy; nothing here runs until someone with a Supabase Management API
// token runs it (see docs/DEPLOY_FACTS_2026-11-04.md).
//
// Usage:
//   node backend/scripts/deploy-facts.mjs [--step <n>] [--dry-run]
//       [--trigger <canvasCourseId> [--trigger-code <code>] [--trigger-name <name>]]
//
// Steps (the owner's ordered checklist). With no --step they run in the order
// 4, 1, 2, 3 -- secrets are checked BEFORE anything is deployed -- and the
// run stops at the first failure:
//   4  secrets: OPENROUTER_API_KEY must exist; LHF_FACTS_MODEL,
//      LHF_FACTS_DISABLED and FACTS_COURSE_MONTHLY_LIMIT are reported
//      set / not set (never their values).
//   1  migration 20261104090000_course_facts.sql (after a scan that it is
//      idempotent), then deploy `sync`, then `extract-facts`.
//   2  one manifest call each way from a throwaway anonymous user enrolled in
//      nothing: with `factsSince: 0` (200, `facts: []`, a numeric
//      `factsCursor`) and the old shape without it (200, the usual keys).
//      The user is deleted afterwards through `delete-account`.
//   3  the most recent `course_fact_extractions`, each fact's quote checked
//      against its document's title + text. Exit 2 when nothing has been
//      extracted yet -- unless --trigger <courseId> is given, in which case a
//      throwaway anonymous user enrolls that course (one manifest call),
//      runs extract-facts for it, is deleted, and the checks run again.
//
// Exit codes: 0 all good, 1 a failure, 2 step 3 found no extraction yet.
// --dry-run prints every request (method, URL, body size, first line of any
// SQL) and sends NOTHING -- not even the anonymous signup.
//
// Token: SUPABASE_ACCESS_TOKEN, or the file in LHF_SUPABASE_TOKEN_FILE
// (default ~/lhf-bench/supabase.token); see deploy-function.mjs.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  deployFunction,
  describeTokenSource,
  managementHeaders,
  PROJECT_REF,
  resolveManagementToken,
} from "./deploy-function.mjs";

const __filename = fileURLToPath(import.meta.url);
const MIGRATION_PATH = path.resolve(
  path.dirname(__filename),
  "..",
  "supabase",
  "migrations",
  "20261104090000_course_facts.sql",
);
const API = "https://api.supabase.com";
const SUPABASE_URL = process.env.LHF_SUPABASE_URL ?? `https://${PROJECT_REF}.supabase.co`;
// Same publishable key ask-probe.mjs uses; it ships in the app, it is not a secret.
const PUBLISHABLE_KEY = process.env.LHF_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt";

export const REQUIRED_SECRET = "OPENROUTER_API_KEY";
export const OPTIONAL_SECRETS = ["LHF_FACTS_MODEL", "LHF_FACTS_DISABLED", "FACTS_COURSE_MONTHLY_LIMIT"];
export const DEFAULT_ORDER = [4, 1, 2, 3];

export class StepFailure extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

// --- pure parts ------------------------------------------------------------

/** Lines of `sql` that would fail on a second run, as `[lineNumber, text]`.
 *  Comments are stripped first. Checks every statement that is not naturally
 *  re-runnable: create table/index/function/policy/type/extension/trigger/
 *  view/schema/sequence without the guard, `add column` without `if not
 *  exists`, `drop` without `if exists`. Not a SQL parser: a scan for the
 *  mistakes this repo's migrations actually make. */
export function scanIdempotency(sql) {
  const problems = [];
  const lines = sql.split("\n");
  // A `create policy` is re-runnable only if a `drop policy if exists` for
  // the same name and table appears anywhere earlier.
  const droppedPolicies = new Set();
  lines.forEach((raw, i) => {
    const line = raw.replace(/--.*$/, "").trim().toLowerCase();
    if (!line) return;
    const n = i + 1;
    const dropPolicy = line.match(/^drop policy if exists\s+(\S+)\s+on\s+(\S+)/);
    if (dropPolicy) droppedPolicies.add(`${dropPolicy[1]} ${dropPolicy[2].replace(/;$/, "")}`);

    if (/^create (unlogged |temporary |temp )?table\b/.test(line) && !/^create (unlogged |temporary |temp )?table if not exists\b/.test(line)) {
      problems.push([n, raw.trim()]);
    } else if (/^create (unique )?index\b/.test(line) && !/^create (unique )?index (concurrently )?if not exists\b/.test(line)) {
      problems.push([n, raw.trim()]);
    } else if (/^create function\b/.test(line)) {
      problems.push([n, raw.trim()]);
    } else if (/^create (type|trigger|view|schema|sequence|extension)\b/.test(line) && !/\bif not exists\b/.test(line)) {
      problems.push([n, raw.trim()]);
    } else if (/^create policy\b/.test(line)) {
      // Policy names are on this line; the table is on a later one, so match by name only.
      const name = line.match(/^create policy\s+(\S+)/)?.[1];
      const hasDrop = [...droppedPolicies].some((d) => d.startsWith(`${name} `));
      if (!hasDrop) problems.push([n, raw.trim()]);
    } else if (/\badd column\b/.test(line) && !/\badd column if not exists\b/.test(line)) {
      problems.push([n, raw.trim()]);
    } else if (/^drop (table|index|function|policy|trigger|view|type)\b/.test(line) && !/^drop \w+ if exists\b/.test(line)) {
      problems.push([n, raw.trim()]);
    }
  });
  return problems;
}

/** The first non-blank, non-comment-only... line of the SQL that carries
 *  content. Comment lines count as the first line of a migration, which is
 *  what a human wants to see, so this is the literal first non-empty line. */
export function firstSqlLine(sql) {
  return sql.split("\n").find((l) => l.trim().length > 0)?.trim() ?? "";
}

/** The same normalisation `parseFacts` uses for its quote guard
 *  (`_shared/facts.ts` normalizeForQuote): NFKC, curly quotes and dashes straightened, NBSP, whitespace, lowercase. */
export function normalizeForQuote(s) {
  return String(s)
    .normalize("NFKC")
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/\u00A0/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

/** Quote-in-document check. `facts`: [{ seq, extraction_id, document_id, content_hash, quote }];
 *  `documents`: [{ id, title, text, content_hash }]. Returns one row per fact with
 *  `status`: "ok" | "missing" (quote not in the document) | "no_document" |
 *  "stale" (the document was edited since; the quote can legitimately be gone,
 *  so it is reported but is not a failure). */
export function checkQuotes(facts, documents) {
  const byId = new Map(documents.map((d) => [d.id, d]));
  return facts.map((f) => {
    const doc = byId.get(f.document_id);
    if (!doc) return { ...f, status: "no_document" };
    const found = normalizeForQuote(`${doc.title}\n${doc.text}`).includes(normalizeForQuote(f.quote));
    if (found) return { ...f, status: "ok" };
    if (doc.content_hash && f.content_hash && doc.content_hash !== f.content_hash) return { ...f, status: "stale" };
    return { ...f, status: "missing" };
  });
}

/** Names present in `GET /secrets` -> a report with no values. */
export function secretsReport(list) {
  const names = new Set((Array.isArray(list) ? list : []).map((s) => s?.name));
  return {
    openRouterKey: names.has(REQUIRED_SECRET),
    optional: Object.fromEntries(OPTIONAL_SECRETS.map((n) => [n, names.has(n)])),
  };
}

/** SQL string literal for an id taken from our own database. */
export function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

// --- plumbing --------------------------------------------------------------

function table(rows, columns) {
  const cells = rows.map((r) => columns.map((c) => String(r[c] ?? "")));
  const widths = columns.map((c, i) => Math.max(c.length, ...cells.map((row) => row[i].length)));
  const fmt = (row) => row.map((v, i) => v.padEnd(widths[i])).join("  ");
  return [fmt(columns), fmt(widths.map((w) => "-".repeat(w))), ...cells.map(fmt)].join("\n");
}

/** Context passed to every step. `request` is the single place a Management
 *  API call is made; in dry-run it prints the plan and returns `undefined`. */
export function makeContext({ dryRun = false, fetchImpl = fetch, log = console.log, env = process.env, trigger } = {}) {
  const { token, source } = resolveManagementToken(env);
  const ctx = {
    dryRun,
    fetchImpl,
    log,
    env,
    trigger,
    token,
    tokenSource: source,
    async management(method, apiPath, body) {
      const url = `${API}${apiPath}`;
      const payload = body === undefined ? undefined : JSON.stringify(body);
      if (dryRun) {
        const sqlNote = body && typeof body.query === "string" ? `, sql first line: ${firstSqlLine(body.query)}` : "";
        log(`[dry-run] ${method} ${url} (body ${payload ? Buffer.byteLength(payload) : 0} bytes${sqlNote})`);
        return undefined;
      }
      const res = await fetchImpl(url, {
        method,
        headers: managementHeaders(token, payload ? { "Content-Type": "application/json" } : {}),
        body: payload,
      });
      const text = await res.text();
      if (!res.ok) throw new StepFailure(`${method} ${apiPath} -> HTTP ${res.status} ${text.slice(0, 400)}`);
      try {
        return JSON.parse(text);
      } catch {
        return text;
      }
    },
    sql(query) {
      return ctx.management("POST", `/v1/projects/${PROJECT_REF}/database/query`, { query });
    },
  };
  return ctx;
}

// --- steps -----------------------------------------------------------------

export async function stepSecrets(ctx) {
  ctx.log("== step 4: secrets ==");
  const list = await ctx.management("GET", `/v1/projects/${PROJECT_REF}/secrets`);
  if (ctx.dryRun) return;
  const report = secretsReport(list);
  ctx.log(`${REQUIRED_SECRET}: ${report.openRouterKey ? "present" : "MISSING"}`);
  for (const [name, set] of Object.entries(report.optional)) ctx.log(`${name}: ${set ? "set" : "not set (default applies)"}`);
  if (!report.openRouterKey) {
    throw new StepFailure(`${REQUIRED_SECRET} is not set on the project; extract-facts could never call the model`);
  }
}

export async function stepMigrateAndDeploy(ctx, { deploy = deployFunction, sqlPath = MIGRATION_PATH } = {}) {
  ctx.log("== step 1: migration, then sync, then extract-facts ==");
  const sql = fs.readFileSync(sqlPath, "utf8");
  const problems = scanIdempotency(sql);
  if (problems.length > 0) {
    throw new StepFailure(
      `migration is not idempotent:\n${problems.map(([n, l]) => `  line ${n}: ${l}`).join("\n")}`,
    );
  }
  ctx.log(`migration scan: idempotent (${sql.split("\n").length} lines)`);
  await ctx.sql(sql);
  if (!ctx.dryRun) ctx.log("migration applied");
  for (const slug of ["sync", "extract-facts"]) {
    try {
      await deploy(slug, { dryRun: ctx.dryRun, fetchImpl: ctx.fetchImpl, log: ctx.log, env: ctx.env });
    } catch (err) {
      throw new StepFailure(err instanceof Error ? err.message : String(err));
    }
  }
}

async function functionCall(ctx, name, accessToken, body) {
  const res = await ctx.fetchImpl(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  return { status: res.status, json, text };
}

/** Creates the throwaway anonymous user step 2 and --trigger both use. */
async function signupThrowaway(ctx) {
  const signup = await ctx.fetchImpl(`${SUPABASE_URL}/auth/v1/signup`, {
    method: "POST",
    headers: { apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
    body: "{}",
  });
  if (!signup.ok) throw new StepFailure(`anonymous signup failed: HTTP ${signup.status} ${await signup.text()}`);
  const session = await signup.json();
  const accessToken = session.access_token;
  const userId = session.user?.id;
  if (!accessToken) throw new StepFailure("anonymous signup returned no access_token");
  ctx.log(`throwaway user ${userId}`);
  return { accessToken, userId };
}

/** Deletes it through `delete-account`; never throws, tells the owner what to do by hand on failure. */
async function deleteThrowaway(ctx, accessToken, userId) {
  try {
    const del = await functionCall(ctx, "delete-account", accessToken, {});
    if (del.status === 200) ctx.log(`cleanup: throwaway user ${userId} deleted`);
    else ctx.log(`cleanup FAILED (HTTP ${del.status}): delete anonymous user ${userId} by hand in the Supabase dashboard (Authentication > Users)`);
  } catch (err) {
    ctx.log(`cleanup FAILED (${err instanceof Error ? err.message : err}): delete anonymous user ${userId} by hand`);
  }
}

export async function stepManifest(ctx) {
  ctx.log("== step 2: manifest with and without factsSince ==");
  const plan = [
    `POST ${SUPABASE_URL}/auth/v1/signup (anonymous; apikey header)`,
    `POST ${SUPABASE_URL}/functions/v1/sync {action:manifest, courses:[], documents:[], factsSince:0}`,
    `POST ${SUPABASE_URL}/functions/v1/sync {action:manifest, courses:[], documents:[]}  (old shape)`,
    `POST ${SUPABASE_URL}/functions/v1/delete-account {}  (cleanup)`,
  ];
  if (ctx.dryRun) {
    for (const p of plan) ctx.log(`[dry-run] ${p}`);
    return;
  }
  const { accessToken, userId } = await signupThrowaway(ctx);

  let failure;
  try {
    const withSince = await functionCall(ctx, "sync", accessToken, { action: "manifest", courses: [], documents: [], factsSince: 0 });
    if (withSince.status !== 200) throw new StepFailure(`manifest with factsSince:0 -> HTTP ${withSince.status} ${withSince.text.slice(0, 300)}`);
    const j = withSince.json ?? {};
    if (!Array.isArray(j.facts) || j.facts.length !== 0) throw new StepFailure(`expected facts: [] for a user enrolled in nothing, got ${JSON.stringify(j.facts)?.slice(0, 200)}`);
    if (typeof j.factsCursor !== "number") throw new StepFailure(`factsCursor missing or not a number: ${JSON.stringify(j.factsCursor)}`);
    ctx.log(`ok: factsSince:0 -> 200, facts: [], factsCursor ${j.factsCursor}`);

    const old = await functionCall(ctx, "sync", accessToken, { action: "manifest", courses: [], documents: [] });
    if (old.status !== 200) throw new StepFailure(`old-style manifest -> HTTP ${old.status} ${old.text.slice(0, 300)}`);
    const missing = ["coursesFresh", "serverManifest", "download", "catalog", "profiles"].filter((k) => !(k in (old.json ?? {})));
    if (missing.length > 0) throw new StepFailure(`old-style manifest lacks keys: ${missing.join(", ")}`);
    ctx.log("ok: old-style request -> 200 with the usual keys");
  } catch (err) {
    failure = err;
  }

  // Cleanup runs whether or not the checks passed.
  await deleteThrowaway(ctx, accessToken, userId);
  if (failure) throw failure;
}

export const HOW_TO_TRIGGER = [
  "No extraction exists yet. To trigger one:",
  "  1. Sign in as an enrolled user (a phone that has synced a Canvas course; enrollment is created by a sync manifest call).",
  "  2. POST ${SUPABASE_URL}/functions/v1/extract-facts with that user's bearer token and body {\"courseId\":\"<numeric Canvas course id>\"}",
  "     (omit courseId to run every enrolled course; at most 10 documents per run, newest first).",
  "  3. Re-run: node backend/scripts/deploy-facts.mjs --step 3",
  "Or let the script do 1 and 2 with a throwaway user: node backend/scripts/deploy-facts.mjs --step 3 --trigger <courseId> [--trigger-code <code>] [--trigger-name <name>]",
].join("\n");

/** Enrolls a throwaway user in `trigger.courseId`, runs extract-facts for it,
 *  and deletes the user in a `finally`. */
export async function triggerExtraction(ctx) {
  const { courseId, code, name } = ctx.trigger;
  ctx.log(`--trigger: extracting course ${courseId} as a throwaway user`);
  const { accessToken, userId } = await signupThrowaway(ctx);
  try {
    const manifest = await functionCall(ctx, "sync", accessToken, {
      action: "manifest",
      courses: [{ courseID: courseId, code, name }],
      documents: [],
      factsSince: 0,
    });
    if (manifest.status !== 200) throw new StepFailure(`enrolling manifest -> HTTP ${manifest.status} ${manifest.text.slice(0, 300)}`);
    ctx.log(`ok: course ${courseId} enrolled (manifest 200)`);
    const ex = await functionCall(ctx, "extract-facts", accessToken, { courseId });
    if (ex.status < 200 || ex.status >= 300) throw new StepFailure(`extract-facts -> HTTP ${ex.status} ${ex.text.slice(0, 300)}`);
    const j = ex.json ?? {};
    ctx.log(["attempted", "done", "failed", "skippedBudget", "facts", "remaining"].map((k) => `${k}: ${JSON.stringify(j[k])}`).join(", "));
  } finally {
    await deleteThrowaway(ctx, accessToken, userId);
  }
}

export async function stepExtractions(ctx) {
  ctx.log("== step 3: recent extractions and their quotes ==");
  const extractionsSql =
    "select id, document_id, content_hash, course_id, status, model, cost_usd, fact_count, rejected_count, reject_reasons, latency_ms, updated_at " +
    "from public.course_fact_extractions order by updated_at desc limit 10";
  let extractions = await ctx.sql(extractionsSql);
  if (ctx.dryRun) {
    if (ctx.trigger) {
      ctx.log(`[dry-run] if no extraction exists, --trigger would, for course ${ctx.trigger.courseId} (code ${JSON.stringify(ctx.trigger.code)}, name ${JSON.stringify(ctx.trigger.name)}):`);
      for (const p of [
        `POST ${SUPABASE_URL}/auth/v1/signup (anonymous; apikey header)`,
        `POST ${SUPABASE_URL}/functions/v1/sync {action:manifest, courses:[{courseID, code, name}], documents:[], factsSince:0}`,
        `POST ${SUPABASE_URL}/functions/v1/extract-facts {courseId:"${ctx.trigger.courseId}"}`,
        `POST ${SUPABASE_URL}/functions/v1/delete-account {}  (cleanup, even on failure)`,
      ]) ctx.log(`[dry-run]   ${p}`);
      ctx.log("[dry-run] then re-run the extraction query below");
    }
    ctx.log("[dry-run] then: select course_facts rows for those extraction ids, and course_documents (id, title, text, content_hash) by document_id");
    return;
  }
  const empty = () => !Array.isArray(extractions) || extractions.length === 0;
  if (empty() && ctx.trigger) {
    await triggerExtraction(ctx);
    extractions = await ctx.sql(extractionsSql);
  }
  if (empty()) {
    ctx.log(HOW_TO_TRIGGER.replace("${SUPABASE_URL}", SUPABASE_URL));
    throw new StepFailure("no extraction yet", 2);
  }
  ctx.log(table(
    extractions.map((e) => ({ ...e, reject_reasons: JSON.stringify(e.reject_reasons) })),
    ["id", "status", "model", "cost_usd", "fact_count", "rejected_count", "reject_reasons", "latency_ms"],
  ));

  const ids = extractions.map((e) => Number(e.id)).filter(Number.isInteger);
  const facts = ids.length === 0 ? [] : await ctx.sql(
    `select seq, extraction_id, document_id, content_hash, fact_type, quote from public.course_facts where extraction_id in (${ids.join(",")}) order by seq`,
  );
  if (!Array.isArray(facts) || facts.length === 0) {
    ctx.log("no accepted facts in these extractions (a document that yields nothing is a valid result)");
    return;
  }
  const docIds = [...new Set(facts.map((f) => f.document_id))];
  const docs = await ctx.sql(
    `select id, title, text, content_hash from public.course_documents where id in (${docIds.map(sqlLiteral).join(",")})`,
  );
  const checked = checkQuotes(facts, Array.isArray(docs) ? docs : []);
  ctx.log(table(
    checked.map((c) => ({ ...c, quote: c.quote.length > 60 ? `${c.quote.slice(0, 57)}...` : c.quote })),
    ["seq", "extraction_id", "fact_type", "status", "quote"],
  ));
  const bad = checked.filter((c) => c.status === "missing" || c.status === "no_document");
  const stale = checked.filter((c) => c.status === "stale");
  if (stale.length > 0) ctx.log(`note: ${stale.length} fact(s) belong to a document edited since extraction (not counted as failures)`);
  if (bad.length > 0) {
    throw new StepFailure(`${bad.length} fact(s) whose quote is not in the document (seq ${bad.map((b) => b.seq).join(", ")})`);
  }
  ctx.log(`all ${checked.length} quote(s) found in their documents`);
}

export const STEPS = { 1: stepMigrateAndDeploy, 2: stepManifest, 3: stepExtractions, 4: stepSecrets };

/** Runs the steps in order and stops at the first failure. Returns the exit code. */
export async function run(stepNumbers, ctx) {
  ctx.log(describeTokenSource(ctx.tokenSource));
  if (ctx.dryRun) ctx.log("[dry-run] nothing below is sent");
  for (const n of stepNumbers) {
    try {
      await STEPS[n](ctx);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const code = err instanceof StepFailure ? err.exitCode : 1;
      ctx.log(`STOPPED at step ${n}: ${message}`);
      return code;
    }
  }
  ctx.log(ctx.dryRun ? "[dry-run] done" : "all requested steps passed");
  return 0;
}

export function parseArgs(argv) {
  let step;
  let dryRun = false;
  let triggerId;
  let triggerCode;
  let triggerName;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dry-run") dryRun = true;
    else if (argv[i] === "--step") step = Number(argv[++i]);
    else if (argv[i] === "--trigger") triggerId = argv[++i];
    else if (argv[i] === "--trigger-code") triggerCode = argv[++i];
    else if (argv[i] === "--trigger-name") triggerName = argv[++i];
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (step !== undefined && !Object.hasOwn(STEPS, step)) throw new Error("--step must be 1, 2, 3 or 4");
  if ((triggerCode || triggerName) && triggerId === undefined) throw new Error("--trigger-code and --trigger-name need --trigger <courseId>");
  const parsed = { steps: step === undefined ? DEFAULT_ORDER : [step], dryRun };
  if (triggerId !== undefined) {
    if (!/^\d+$/.test(triggerId)) throw new Error("--trigger needs a numeric Canvas course id");
    parsed.trigger = { courseId: triggerId, code: triggerCode || `COURSE ${triggerId}`, name: triggerName || `Course ${triggerId}` };
  }
  return parsed;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    console.error("Usage: node backend/scripts/deploy-facts.mjs [--step <1-4>] [--dry-run] [--trigger <courseId> [--trigger-code <code>] [--trigger-name <name>]]");
    process.exit(1);
  }
  const ctx = makeContext({ dryRun: parsed.dryRun, trigger: parsed.trigger });
  process.exit(await run(parsed.steps, ctx));
}
