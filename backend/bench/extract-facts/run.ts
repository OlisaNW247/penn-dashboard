// Phase 0 bench runner: labelled course documents x candidate models, through
// OpenRouter, scored by score.ts. See README.md for the four commands.
//
// Why this calls OpenRouter directly instead of reusing _shared/openrouter.ts:
// the production client sends `json_object` only, and the point of the bench is
// to measure the strict json_schema request the shipped function will make
// (research doc, Part 5 and Addendum item 15). The request body is therefore
// built here, once, and --dry-run writes exactly that body to disk so it can be
// read before a cent is spent.
//
// Nothing here is a deploy and no key is stored: the key comes from
// OPENROUTER_API_KEY in the environment and is never written to results.

import {
  buildFactsMessages,
  FACTS_JSON_SCHEMA,
  type FactsDocument,
  parseFacts,
  type ParsedFacts,
} from "../../supabase/functions/_shared/facts.ts";
import { type ExpectedFact, renderReport, type ResultLine, scoreDoc, summarize } from "./score.ts";

const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const TIMEOUT_MS = 60_000;

interface CorpusDoc extends FactsDocument {
  source: "synthetic" | "phone";
  expected: null | { facts: ExpectedFact[] };
}

interface Args {
  corpus: string;
  tag: string;
  models: string[];
  limit: number | null;
  concurrency: number;
  dryRun: boolean;
  requireParameters: boolean;
  temperature: number;
  maxTokens: number;
}

function parseArgs(argv: string[]): Args {
  const a: Args = {
    corpus: "",
    tag: "",
    models: [],
    limit: null,
    concurrency: 4,
    dryRun: false,
    requireParameters: false,
    temperature: 0,
    maxTokens: 1500,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => {
      const x = argv[++i];
      if (x === undefined) throw new Error(`${k} needs a value`);
      return x;
    };
    switch (k) {
      case "--corpus": a.corpus = v(); break;
      case "--tag": a.tag = v(); break;
      case "--model": a.models.push(v()); break;
      case "--limit": a.limit = Number(v()); break;
      case "--concurrency": a.concurrency = Math.max(1, Number(v())); break;
      case "--temperature": a.temperature = Number(v()); break;
      case "--max-tokens": a.maxTokens = Number(v()); break;
      case "--dry-run": a.dryRun = true; break;
      case "--require-parameters": a.requireParameters = true; break;
      default: throw new Error(`unknown argument ${k}`);
    }
  }
  if (!a.corpus || !a.tag || a.models.length === 0) {
    throw new Error("usage: run.ts --corpus <dir> --tag <name> --model <id> [--model <id> ...] [--limit N] [--concurrency 4] [--dry-run] [--temperature 0] [--max-tokens 1500]");
  }
  return a;
}

async function* walk(dir: string): AsyncGenerator<string> {
  const entries: Deno.DirEntry[] = [];
  for await (const e of Deno.readDir(dir)) entries.push(e);
  entries.sort((x, y) => x.name.localeCompare(y.name));
  for (const e of entries) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory) yield* walk(p);
    else if (e.isFile && e.name.endsWith(".json")) yield p;
  }
}

async function loadCorpus(dir: string): Promise<{ docs: CorpusDoc[]; unlabelled: number }> {
  const docs: CorpusDoc[] = [];
  let unlabelled = 0;
  for await (const p of walk(dir)) {
    const d = JSON.parse(await Deno.readTextFile(p)) as CorpusDoc;
    if (!d.expected) unlabelled++;
    else docs.push(d);
  }
  return { docs, unlabelled };
}

/** The document exactly as the production function will see it: the bench-only
 * `source` and `expected` fields are stripped so a label can never leak into
 * the prompt. */
function toFactsDocument(d: CorpusDoc): FactsDocument {
  // deno-lint-ignore no-unused-vars
  const { source, expected, ...doc } = d;
  return doc as FactsDocument;
}

function requestBody(model: string, doc: FactsDocument, args: Args) {
  const { system, user } = buildFactsMessages(doc);
  return {
    model,
    messages: [{ role: "system", content: system }, { role: "user", content: user }],
    temperature: args.temperature,
    max_tokens: args.maxTokens,
    response_format: {
      type: "json_schema",
      json_schema: { name: "facts", strict: true, schema: FACTS_JSON_SCHEMA },
    },
    // The research said to send provider.require_parameters so OpenRouter
    // never routes to an endpoint that ignores the schema. Measured on
    // 2026-11-03: with it set, every Haiku 5.5 request 404s ("No endpoints
    // found that can handle the requested parameters"), with json_schema
    // and with plain json_object alike, while strict json_schema without
    // it is honoured (routed to Azure). So it is opt-in; the parser's own
    // checks catch a best-effort endpoint anyway, as a parse failure or a
    // bad shape, and the gates fail the run on either.
    ...(args.requireParameters ? { provider: { require_parameters: true } } : {}),
  };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function callOnce(body: unknown, key: string) {
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "Authorization": `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  const text = await res.text();
  return { status: res.status, text };
}

async function runOne(model: string, d: CorpusDoc, args: Args, key: string): Promise<ResultLine> {
  const doc = toFactsDocument(d);
  const body = requestBody(model, doc, args);
  const started = performance.now();
  let status: number | null = null;
  let text = "";
  let error: string | undefined;
  // One retry on 429 / 5xx / network failure. Latency is the wall time of the
  // whole exchange including the backoff, since that is what a student waits.
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const r = await callOnce(body, key);
      status = r.status;
      text = r.text;
      error = undefined;
      if (status !== 429 && status < 500) break;
      error = `http ${status}`;
    } catch (e) {
      status = null;
      error = e instanceof Error ? e.message : String(e);
    }
    if (attempt === 0) await sleep(2000);
  }
  const latencyMs = Math.round(performance.now() - started);

  let content: string | null = null;
  let usage = { prompt: null as number | null, completion: null as number | null, reasoning: null as number | null };
  try {
    const j = JSON.parse(text);
    content = j?.choices?.[0]?.message?.content ?? null;
    usage = {
      prompt: j?.usage?.prompt_tokens ?? null,
      completion: j?.usage?.completion_tokens ?? null,
      reasoning: j?.usage?.completion_tokens_details?.reasoning_tokens ?? null,
    };
    if (!content && j?.error) error = error ?? short(j.error);
  } catch {
    if (status !== null && !error) error = `unparseable response body: ${text.slice(0, 120)}`;
  }
  // An empty or failed answer still goes through parseFacts so it is counted
  // as a parse failure rather than silently dropped from the denominator.
  const parsed: ParsedFacts = parseFacts(content ?? "", doc);
  const line: ResultLine = {
    tag: args.tag,
    model,
    docId: d.id,
    course: d.course,
    source: d.source,
    timezone: d.timezone,
    status,
    latencyMs,
    usage,
    raw: content,
    error,
    parsed,
    expected: d.expected!.facts,
  };
  line.score = scoreDoc(line.expected, parsed, d);
  return line;
}

const short = (v: unknown) => {
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s.length > 200 ? s.slice(0, 200) + "..." : s;
};

async function pool<T, R>(items: T[], n: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i]);
    }
  }));
  return out;
}

if (import.meta.main) {
  const args = parseArgs(Deno.args);
  const { docs: all, unlabelled } = await loadCorpus(args.corpus);
  const docs = args.limit !== null ? all.slice(0, args.limit) : all;
  console.log(`corpus: ${docs.length} labelled documents (${unlabelled} unlabelled skipped), ${args.models.length} model(s)`);
  // results/ is relative to this script, not the caller's cwd, so the
  // .gitignore beside the script always covers it.
  const resultsDir = new URL("./results/", import.meta.url).pathname;
  await Deno.mkdir(resultsDir, { recursive: true });
  const pairs = args.models.flatMap((m) => docs.map((d) => ({ m, d })));

  if (args.dryRun) {
    const path = `${resultsDir}${args.tag}.requests.jsonl`;
    const rows = pairs.map(({ m, d }) =>
      JSON.stringify({ model: m, docId: d.id, body: requestBody(m, toFactsDocument(d), args) })
    );
    await Deno.writeTextFile(path, rows.join("\n") + (rows.length ? "\n" : ""));
    console.log(`dry run: wrote ${rows.length} request bodies to ${path} (no network call made)`);
    Deno.exit(0);
  }

  const key = Deno.env.get("OPENROUTER_API_KEY");
  if (!key) {
    console.error("OPENROUTER_API_KEY is not set");
    Deno.exit(2);
  }
  let done = 0;
  const lines = await pool(pairs, args.concurrency, async ({ m, d }) => {
    const l = await runOne(m, d, args, key);
    console.log(`[${++done}/${pairs.length}] ${m} ${d.id} ${l.status ?? "ERR"} ${l.latencyMs}ms`);
    return l;
  });
  const jsonl = `${resultsDir}${args.tag}.jsonl`;
  await Deno.writeTextFile(jsonl, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  await Deno.writeTextFile(`${resultsDir}${args.tag}.md`, renderReport(args.tag, lines));
  for (const s of summarize(lines)) console.log(`${s.model}: ${s.pass ? "PASS" : "FAIL"}`);
  console.log(`wrote ${jsonl} and ${resultsDir}${args.tag}.md`);
}
