// Pure-part and stubbed-fetch tests for deploy-facts.mjs and the token logic
// in deploy-function.mjs. Run: `node --test backend/scripts/` (deno task test:scripts).
// Nothing here touches the network: every fetch is a stub that records calls.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  checkQuotes,
  firstSqlLine,
  makeContext,
  parseArgs,
  run,
  scanIdempotency,
  secretsReport,
} from "./deploy-facts.mjs";
import { resolveManagementToken } from "./deploy-function.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const migration = fs.readFileSync(path.join(here, "..", "supabase", "migrations", "20261104090000_course_facts.sql"), "utf8");

function recorder(handler) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method ?? "GET", body: init.body, headers: init.headers });
    const r = handler(String(url), init, calls.length);
    return new Response(typeof r.body === "string" ? r.body : JSON.stringify(r.body ?? null), { status: r.status ?? 200 });
  };
  return { calls, fetchImpl };
}
const quietCtx = (opts) => {
  const lines = [];
  const ctx = makeContext({ ...opts, log: (l) => lines.push(l), env: { SUPABASE_ACCESS_TOKEN: "tok-secret-123" } });
  return { ctx, lines };
};

test("the shipped migration is idempotent", () => {
  assert.deepEqual(scanIdempotency(migration), []);
});

test("scanIdempotency flags every unguarded statement and ignores comments", () => {
  const bad = [
    "-- create table public.in_a_comment (x int);",
    "create table public.a (x int);",
    "create index a_idx on public.a (x);",
    "create unique index a_u on public.a (x);",
    "create function public.f() returns int language sql as $$ select 1 $$;",
    "alter table public.a add column y int;",
    "create policy p on public.a for select using (true);",
    "drop table public.a;",
  ].join("\n");
  assert.equal(scanIdempotency(bad).length, 7);
  const good = [
    "create table if not exists public.a (x int);",
    "create index if not exists a_idx on public.a (x);",
    "create or replace function public.f() returns int language sql as $$ select 1 $$;",
    "alter table public.a add column if not exists y int;",
    "drop policy if exists p on public.a;",
    "create policy p on public.a for select using (true);",
    "drop table if exists public.a;",
  ].join("\n");
  assert.deepEqual(scanIdempotency(good), []);
});

test("firstSqlLine is the first non-empty line", () => {
  assert.equal(firstSqlLine("\n\n  select 1;\nselect 2;"), "select 1;");
});

test("checkQuotes: found (whitespace and case folded), missing, stale, no document, title counts", () => {
  const docs = [
    { id: "d1", title: "Quiz 2 moved", text: "The quiz is   now on\nFriday.", content_hash: "h1" },
    { id: "d2", title: "t", text: "nothing relevant", content_hash: "NEW" },
  ];
  const f = (document_id, quote, content_hash = "h1") => ({ seq: 1, document_id, quote, content_hash });
  const out = checkQuotes(
    [f("d1", "quiz is now on friday"), f("d1", "Quiz 2 MOVED"), f("d1", "invented sentence"), f("d2", "gone", "OLD"), f("d2", "gone", "NEW"), f("zz", "x")],
    docs,
  );
  assert.deepEqual(out.map((o) => o.status), ["ok", "ok", "missing", "stale", "missing", "no_document"]);
});

test("secretsReport lists presence only", () => {
  const r = secretsReport([{ name: "OPENROUTER_API_KEY", value: "abc" }, { name: "LHF_FACTS_MODEL", value: "zzz" }]);
  assert.equal(r.openRouterKey, true);
  assert.deepEqual(r.optional, { LHF_FACTS_MODEL: true, LHF_FACTS_DISABLED: false, FACTS_COURSE_MONTHLY_LIMIT: false });
  assert.equal(secretsReport(null).openRouterKey, false);
});

test("parseArgs: default order puts secrets first; --step picks one; junk throws", () => {
  assert.deepEqual(parseArgs([]).steps, [4, 1, 2, 3]);
  assert.deepEqual(parseArgs(["--step", "3", "--dry-run"]), { steps: [3], dryRun: true });
  assert.throws(() => parseArgs(["--step", "9"]));
  assert.throws(() => parseArgs(["--wat"]));
});

test("resolveManagementToken: env wins, then file (trimmed), else none; token never in the source label", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lhf-token-"));
  const file = path.join(dir, "t");
  fs.writeFileSync(file, "  from-file\n", { mode: 0o600 });
  assert.deepEqual(resolveManagementToken({ SUPABASE_ACCESS_TOKEN: " from-env ", LHF_SUPABASE_TOKEN_FILE: file }), { token: "from-env", source: "env" });
  assert.deepEqual(resolveManagementToken({ LHF_SUPABASE_TOKEN_FILE: file }), { token: "from-file", source: "file" });
  assert.deepEqual(resolveManagementToken({ LHF_SUPABASE_TOKEN_FILE: path.join(dir, "missing") }), { token: undefined, source: "none" });
  fs.rmSync(dir, { recursive: true });
});

test("dry run sends nothing at all and plans every step", async () => {
  const { calls, fetchImpl } = recorder(() => assert.fail("a dry run must not fetch"));
  const { ctx, lines } = quietCtx({ dryRun: true, fetchImpl });
  assert.equal(await run([4, 1, 2, 3], ctx), 0);
  assert.equal(calls.length, 0);
  const text = lines.join("\n");
  assert.match(text, /\[dry-run\] GET .*\/secrets/);
  assert.match(text, /\[dry-run\] POST .*\/database\/query .*sql first line: -- Phase 2/);
  assert.match(text, /functions\/deploy\?slug=sync/);
  assert.match(text, /functions\/deploy\?slug=extract-facts/);
  assert.match(text, /auth\/v1\/signup/);
  assert.doesNotMatch(text, /tok-secret-123/);
});

test("step 4 failure stops the run before anything is deployed; values are never printed", async () => {
  const { calls, fetchImpl } = recorder((url) => ({ body: url.endsWith("/secrets") ? [{ name: "LHF_FACTS_MODEL", value: "SECRETVALUE" }] : {} }));
  const { ctx, lines } = quietCtx({ fetchImpl });
  assert.equal(await run([4, 1, 2, 3], ctx), 1);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].headers.Authorization, "Bearer tok-secret-123");
  const text = lines.join("\n");
  assert.match(text, /OPENROUTER_API_KEY: MISSING/);
  assert.match(text, /LHF_FACTS_MODEL: set/);
  assert.doesNotMatch(text, /SECRETVALUE|tok-secret-123/);
});

test("step 2: success deletes the throwaway user; a failed check still cleans up and exits 1", async () => {
  for (const factsOk of [true, false]) {
    const { calls, fetchImpl } = recorder((url, init) => {
      if (url.endsWith("/auth/v1/signup")) return { body: { access_token: "jwt", user: { id: "u-1" } } };
      if (url.endsWith("/functions/v1/delete-account")) return { body: { deleted: true } };
      const sent = JSON.parse(init.body);
      const base = { coursesFresh: [], serverManifest: [], download: [], catalog: [], profiles: [] };
      return { body: "factsSince" in sent ? { ...base, facts: factsOk ? [] : [{ seq: 1 }], factsCursor: 0 } : base };
    });
    const { ctx } = quietCtx({ fetchImpl });
    assert.equal(await run([2], ctx), factsOk ? 0 : 1);
    assert.ok(calls.at(-1).url.endsWith("/delete-account"));
    assert.equal(calls.at(-1).headers.Authorization, "Bearer jwt");
  }
});

test("step 3: no extraction exits 2; a missing quote exits 1; clean data exits 0", async () => {
  const scenario = (extractions, facts, docs) =>
    recorder((url, init) => {
      const q = JSON.parse(init.body).query;
      if (q.includes("from public.course_fact_extractions")) return { body: extractions };
      if (q.includes("from public.course_facts")) return { body: facts };
      return { body: docs };
    });
  const ext = [{ id: 1, status: "done", model: "m", cost_usd: "0.001", fact_count: 1, rejected_count: 0, reject_reasons: {}, latency_ms: 900 }];
  const fact = (quote) => [{ seq: 5, extraction_id: 1, document_id: "d1", content_hash: "h", fact_type: "cancel", quote }];
  const doc = [{ id: "d1", title: "T", text: "HW3 is cancelled", content_hash: "h" }];

  assert.equal(await run([3], quietCtx({ fetchImpl: scenario([], [], []).fetchImpl }).ctx), 2);
  assert.equal(await run([3], quietCtx({ fetchImpl: scenario(ext, fact("HW9 is cancelled"), doc).fetchImpl }).ctx), 1);
  assert.equal(await run([3], quietCtx({ fetchImpl: scenario(ext, fact("hw3 is  CANCELLED"), doc).fetchImpl }).ctx), 0);
});

test("step 1 applies the migration, then deploys sync, then extract-facts, via the Management API", async () => {
  const { calls, fetchImpl } = recorder(() => ({ body: { version: 7, status: "ACTIVE", id: "fn" } }));
  const { ctx } = quietCtx({ fetchImpl });
  assert.equal(await run([1], ctx), 0);
  assert.match(calls[0].url, /\/database\/query$/);
  assert.match(JSON.parse(calls[0].body).query, /claim_fact_extraction/);
  assert.match(calls[1].url, /slug=sync$/);
  assert.match(calls[2].url, /slug=extract-facts$/);
  assert.ok(calls.every((c) => c.headers.Authorization === "Bearer tok-secret-123"));
});
