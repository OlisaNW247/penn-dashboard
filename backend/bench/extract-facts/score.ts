// Scoring for the extract-facts bench (Phase 0 of
// docs/DAY_PLANNER_RESEARCH_2026-11-03.md, Parts 2.1 and 7).
//
// This file is pure on purpose: run.ts imports it to score live results, and
// the CLI at the bottom re-scores a saved results file, so a changed matching
// rule or a re-labelled corpus can be re-judged without paying for the model
// calls again. Nothing here touches the network.
//
// The shape of the judgement follows what the product cares about. A false
// task or a wrong cancellation hides or invents real work, while a missed
// fact is today's behaviour. So the two SHIP GATES count false positives only
// (new_task FP + invented quotes == 0, cancel FP == 0), and precision is
// reported beside recall rather than folded into an F1 that would let a
// model buy recall with inventions.

import type { Fact, FactType, FactsDocument, ParsedFacts } from "../../supabase/functions/_shared/facts.ts";

export const FACT_TYPES: FactType[] = [
  "new_task",
  "cancel",
  "reschedule",
  "scope_change",
  "note",
  "needs_review",
];

export type DueTolerance = "exact" | "day" | "any";

export interface ExpectedFact {
  type: FactType;
  target?: string | null;
  title_any?: string[];
  due_at?: string | null;
  due_tolerance?: DueTolerance;
  kind?: "submission" | "preparation" | "event";
  note?: string;
}

export interface Counts {
  tp: number;
  fp: number;
  fn: number;
  dateWrong: number;
}

export type PairKind = "tp" | "date_wrong" | "fp" | "fn";
export interface Pair {
  kind: PairKind;
  expected?: ExpectedFact;
  predicted?: Fact;
}

export interface DocScore {
  byType: Record<FactType, Counts>;
  invented: number; // parseFacts rejected for quote_not_in_text
  badTarget: number; // parseFacts rejected for unknown_target
  parseFailed: boolean;
  pairs: Pair[];
}

// --- price table -----------------------------------------------------------
// USD per million tokens [input, output]. These are PLACEHOLDERS from the
// research doc's Part 5 (the two front-runners at $0.10 / $0.50) plus rough
// guesses for the rest: RE-CHECK EVERY ROW ON OPENROUTER before quoting a
// cost, prices move and the ids below are unverified. A model missing from
// this table reports cost "n/a" instead of a made-up number. Reasoning tokens
// are billed as output, and run.ts folds them into completion in the estimate.
export const PRICES_PER_MTOK: Record<string, [number, number]> = {
  "anthropic/claude-haiku-5.5": [0.10, 0.50],
  "openai/gpt-6-luna": [0.10, 0.50],
  "deepseek/deepseek-v4.1-flash": [0.04, 0.50],
  "openai/gpt-6.1-terra": [1.0, 5.0],
  "z-ai/glm-5.3-flash": [0.03, 0.08],
  "openai/gpt-4.1-mini": [0.40, 1.60],
};

// --- dates -----------------------------------------------------------------

/** Calendar day of an instant in a zone. A bare date ("2026-11-05") is
 * already a calendar day and must not be pushed through UTC midnight, which
 * would land on the previous evening in New York. */
export function dayKey(iso: string, timeZone: string): string | null {
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d);
}

function minuteKey(iso: string): number | null {
  const t = new Date(iso).getTime();
  return Number.isNaN(t) ? null : Math.floor(t / 60000);
}

/** Does the predicted due date satisfy the label?
 * - `due_at` absent from the label: nothing was labelled, so nothing to check.
 * - `due_at: null`: the label says "no date"; a predicted date is wrong.
 * - tolerance "any": skip. "exact": same minute. "day" (default): same
 *   calendar day in the document's zone. */
export function dateOK(exp: ExpectedFact, predDue: string | null, timeZone: string): boolean {
  const tol = exp.due_tolerance ?? "day";
  if (tol === "any") return true;
  if (exp.due_at === undefined) return true;
  if (exp.due_at === null) return predDue === null;
  if (predDue === null) return false;
  if (tol === "exact") {
    const a = minuteKey(exp.due_at);
    const b = minuteKey(predDue);
    return a !== null && a === b;
  }
  const a = dayKey(exp.due_at, timeZone);
  const b = dayKey(predDue, timeZone);
  return a !== null && a === b;
}

// --- matching --------------------------------------------------------------

const norm = (t: string | null | undefined) => (t ?? null);

/** Identity only (type plus target or title); the date is judged separately so
 * a right fact with a wrong date is reported as date_wrong and not as an FP
 * and an FN pair, which would double-penalise one mistake. */
export function identityMatches(exp: ExpectedFact, pred: Fact): boolean {
  if (exp.type !== pred.type) return false;
  switch (exp.type) {
    case "new_task": {
      if (!exp.title_any || exp.title_any.length === 0) return true;
      const title = (pred.title ?? "").toLowerCase();
      return exp.title_any.some((s) => title.includes(s.toLowerCase()));
    }
    case "needs_review":
      // A target is compared only when the label names one.
      return exp.target === undefined || exp.target === null ||
        norm(exp.target) === norm(pred.target);
    default:
      return norm(exp.target) === norm(pred.target);
  }
}

/** Whole calendar days between a label's date and a prediction's, in the
 * document's zone. A label with no usable date counts every dated prediction
 * as equally near (0), so only dated-versus-dateless is decided. */
function dayDistance(expDue: string | null | undefined, predDue: string, timeZone: string): number {
  if (!expDue) return 0;
  const a = dayKey(expDue, timeZone);
  const b = dayKey(predDue, timeZone);
  if (a === null || b === null) return 0;
  return Math.abs(Date.parse(a + "T00:00:00Z") - Date.parse(b + "T00:00:00Z")) / 86400000;
}

function emptyCounts(): Record<FactType, Counts> {
  const o = {} as Record<FactType, Counts>;
  for (const t of FACT_TYPES) o[t] = { tp: 0, fp: 0, fn: 0, dateWrong: 0 };
  return o;
}

export function scoreDoc(
  expected: ExpectedFact[],
  parsed: ParsedFacts,
  doc: Pick<FactsDocument, "timezone">,
): DocScore {
  const byType = emptyCounts();
  const pairs: Pair[] = [];
  const usedPred = new Set<number>();
  const doneExp = new Set<number>();

  // Pass 1 pairs identity AND date, so a fact with the right date is never
  // robbed by an earlier identity-only twin. Pass 2 pairs what is left on
  // identity alone and calls it date_wrong. Each side is used at most once.
  for (const pass of [1, 2] as const) {
    expected.forEach((exp, ei) => {
      if (doneExp.has(ei)) return;
      let pick = -1;
      let pickDist = Infinity;
      for (let pi = 0; pi < parsed.facts.length; pi++) {
        if (usedPred.has(pi)) continue;
        const pred = parsed.facts[pi];
        if (!identityMatches(exp, pred)) continue;
        const ok = dateOK(exp, pred.due_at, doc.timezone);
        if (pass === 1 && !ok) continue;
        if (pass === 1) {
          pick = pi;
          break;
        }
        // Pass 2, several predictions share this label's identity: the first
        // used to win, and a dateless wrong prediction listed ahead of the
        // right one took the label, pushing the right one into FP (phone doc
        // announcement:1949400:11298483, round 1). Prefer a prediction that
        // has a due_at, and among those the one whose calendar day is nearest
        // the label's; ties keep the earlier prediction.
        const dist = pred.due_at === null ? Infinity : dayDistance(exp.due_at, pred.due_at, doc.timezone);
        const rank = pred.due_at === null ? 1e12 : dist;
        if (pick === -1 || rank < pickDist) {
          pick = pi;
          pickDist = rank;
        }
      }
      if (pick === -1) return;
      const pred = parsed.facts[pick];
      const ok = dateOK(exp, pred.due_at, doc.timezone);
      usedPred.add(pick);
      doneExp.add(ei);
      if (ok) {
        byType[exp.type].tp++;
        pairs.push({ kind: "tp", expected: exp, predicted: pred });
      } else {
        byType[exp.type].dateWrong++;
        pairs.push({ kind: "date_wrong", expected: exp, predicted: pred });
      }
    });
  }
  expected.forEach((exp, ei) => {
    if (doneExp.has(ei)) return;
    byType[exp.type].fn++;
    pairs.push({ kind: "fn", expected: exp });
  });
  parsed.facts.forEach((pred, pi) => {
    if (usedPred.has(pi)) return;
    byType[pred.type].fp++;
    pairs.push({ kind: "fp", predicted: pred });
  });

  let invented = 0;
  let badTarget = 0;
  for (const r of parsed.rejected) {
    if (r.reason === "quote_not_in_text") invented++;
    else if (r.reason === "unknown_target") badTarget++;
  }
  return { byType, invented, badTarget, parseFailed: parsed.parseFailed, pairs };
}

// --- aggregation -----------------------------------------------------------

export interface ResultLine {
  tag: string;
  model: string;
  docId: string;
  course: string;
  source: string;
  timezone: string;
  status: number | null;
  latencyMs: number | null;
  usage: { prompt: number | null; completion: number | null; reasoning: number | null };
  raw: string | null;
  error?: string;
  parsed: ParsedFacts | null;
  expected: ExpectedFact[];
  score?: DocScore;
}

export interface Ratio {
  p: number | null;
  r: number | null;
}

export interface ModelSummary {
  model: string;
  docs: number;
  byType: Record<FactType, Counts & Ratio>;
  overall: Counts & Ratio;
  invented: number;
  badTarget: number;
  parseFailures: number;
  httpFailures: number;
  gateInventedTasks: boolean; // FP(new_task)+invented == 0
  gateCancel: boolean; // FP(cancel) == 0
  pass: boolean;
  latency: { mean: number; median: number; p95: number } | null;
  meanPromptTokens: number | null;
  meanCompletionTokens: number | null;
  costUSD: number | null;
}

const ratio = (num: number, den: number): number | null => den === 0 ? null : num / den;

function withRatio(c: Counts): Counts & Ratio {
  // Precision's denominator is everything predicted that was judged
  // (TP+FP+date_wrong); recall's is everything labelled (TP+FN+date_wrong).
  // A wrong date therefore hurts both and is also listed on its own.
  return { ...c, p: ratio(c.tp, c.tp + c.fp + c.dateWrong), r: ratio(c.tp, c.tp + c.fn + c.dateWrong) };
}

export function percentile(sorted: number[], q: number): number {
  if (sorted.length === 0) return NaN;
  const rank = Math.ceil(q * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

export function summarize(lines: ResultLine[]): ModelSummary[] {
  const models = [...new Set(lines.map((l) => l.model))];
  return models.map((model) => {
    const mine = lines.filter((l) => l.model === model);
    const byType = emptyCounts();
    let invented = 0, badTarget = 0, parseFailures = 0, httpFailures = 0;
    for (const l of mine) {
      if (l.status === null || l.status >= 400) httpFailures++;
      // A call that never returned content scores as "everything missed":
      // its expected facts count as FN, so an outage cannot look like a pass.
      const s = l.score ?? scoreDoc(l.expected, l.parsed ?? { facts: [], rejected: [], parseFailed: true }, l);
      if (s.parseFailed) parseFailures++;
      invented += s.invented;
      badTarget += s.badTarget;
      for (const t of FACT_TYPES) {
        byType[t].tp += s.byType[t].tp;
        byType[t].fp += s.byType[t].fp;
        byType[t].fn += s.byType[t].fn;
        byType[t].dateWrong += s.byType[t].dateWrong;
      }
    }
    const total: Counts = { tp: 0, fp: 0, fn: 0, dateWrong: 0 };
    for (const t of FACT_TYPES) {
      total.tp += byType[t].tp;
      total.fp += byType[t].fp;
      total.fn += byType[t].fn;
      total.dateWrong += byType[t].dateWrong;
    }
    const lat = mine.map((l) => l.latencyMs).filter((x): x is number => x !== null).sort((a, b) => a - b);
    const mean = (xs: number[]) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
    const pt = mine.map((l) => l.usage.prompt).filter((x): x is number => x !== null);
    const ct = mine.map((l) => l.usage.completion).filter((x): x is number => x !== null);
    const price = PRICES_PER_MTOK[model];
    const costUSD = price && pt.length
      ? (pt.reduce((a, b) => a + b, 0) * price[0] + ct.reduce((a, b) => a + b, 0) * price[1]) / 1e6
      : null;
    const gateInventedTasks = byType.new_task.fp + invented === 0;
    const gateCancel = byType.cancel.fp === 0;
    return {
      model,
      docs: mine.length,
      byType: Object.fromEntries(FACT_TYPES.map((t) => [t, withRatio(byType[t])])) as ModelSummary["byType"],
      overall: withRatio(total),
      invented,
      badTarget,
      parseFailures,
      httpFailures,
      gateInventedTasks,
      gateCancel,
      // A run with failed calls or unparseable answers cannot pass: the gates
      // only count false positives, so an outage that answers nothing would
      // otherwise read as a clean sheet (seen on the first smoke test, two
      // 404s and a PASS).
      pass: gateInventedTasks && gateCancel && httpFailures === 0 && parseFailures === 0,
      latency: lat.length
        ? { mean: mean(lat)!, median: percentile(lat, 0.5), p95: percentile(lat, 0.95) }
        : null,
      meanPromptTokens: mean(pt),
      meanCompletionTokens: mean(ct),
      costUSD,
    };
  });
}

// --- report ----------------------------------------------------------------

const pct = (x: number | null) => x === null ? "-" : `${(x * 100).toFixed(0)}%`;
const ms = (x: number | undefined) => x === undefined || Number.isNaN(x) ? "-" : `${Math.round(x)}`;
const short = (v: unknown, n = 160) => {
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s.length > n ? s.slice(0, n) + "..." : s;
};

export function renderReport(tag: string, lines: ResultLine[]): string {
  const sums = summarize(lines);
  const out: string[] = [];
  out.push(`# extract-facts bench: ${tag}`, "");
  out.push(`${lines.length} model x document runs, ${new Set(lines.map((l) => l.docId)).size} documents.`, "");
  out.push("Ship gates (Part 7): FP(new_task) + invented == 0, and FP(cancel) == 0; any HTTP or parse failure fails the run.", "");
  out.push("| model | gates | invented | bad target | parse fail | http fail | P/R overall | latency ms mean/med/p95 | tokens in/out | est. cost |");
  out.push("|---|---|---|---|---|---|---|---|---|---|");
  for (const s of sums) {
    out.push(
      `| ${s.model} | ${s.pass ? "PASS" : "FAIL"} | ${s.invented} | ${s.badTarget} | ${s.parseFailures} | ${s.httpFailures} | ${pct(s.overall.p)}/${pct(s.overall.r)} | ${ms(s.latency?.mean)}/${ms(s.latency?.median)}/${ms(s.latency?.p95)} | ${s.meanPromptTokens === null ? "-" : Math.round(s.meanPromptTokens)}/${s.meanCompletionTokens === null ? "-" : Math.round(s.meanCompletionTokens)} | ${s.costUSD === null ? "n/a" : "$" + s.costUSD.toFixed(4)} |`,
    );
  }
  out.push("", "Cost uses the constant PRICES_PER_MTOK in score.ts: re-check it on OpenRouter.", "");
  for (const s of sums) {
    out.push(`## ${s.model}: ${s.pass ? "PASS" : "FAIL"}`, "");
    out.push(`- gate FP(new_task)+invented == 0: ${s.gateInventedTasks ? "pass" : "FAIL"} (FP ${s.byType.new_task.fp}, invented ${s.invented})`);
    out.push(`- gate FP(cancel) == 0: ${s.gateCancel ? "pass" : "FAIL"} (FP ${s.byType.cancel.fp})`, "");
    out.push("| type | TP | FP | FN | date_wrong | precision | recall |", "|---|---|---|---|---|---|---|");
    for (const t of FACT_TYPES) {
      const c = s.byType[t];
      out.push(`| ${t} | ${c.tp} | ${c.fp} | ${c.fn} | ${c.dateWrong} | ${pct(c.p)} | ${pct(c.r)} |`);
    }
    const o = s.overall;
    out.push(`| overall | ${o.tp} | ${o.fp} | ${o.fn} | ${o.dateWrong} | ${pct(o.p)} | ${pct(o.r)} |`, "");
  }
  out.push("## Misses", "", "Every FP, FN and date_wrong, plus each document-level problem, so a human can re-label or fix the prompt.", "");
  for (const l of lines) {
    const s = l.score ?? scoreDoc(l.expected, l.parsed ?? { facts: [], rejected: [], parseFailed: true }, l);
    const bad = s.pairs.filter((p) => p.kind !== "tp");
    const rejected = (l.parsed?.rejected ?? []).filter((r) => r.reason === "quote_not_in_text" || r.reason === "unknown_target");
    if (!bad.length && !rejected.length && !s.parseFailed && !l.error) continue;
    out.push(`### ${l.model} / ${l.docId}`, "");
    if (l.error) out.push(`- call error: ${l.error}`);
    if (s.parseFailed) out.push("- parse failed");
    for (const r of rejected) out.push(`- rejected (${r.reason}): ${short(r.fact)}`);
    for (const p of bad) {
      const type = p.expected?.type ?? p.predicted?.type;
      out.push(`- ${p.kind.toUpperCase()} ${type}`);
      if (p.expected) out.push(`  - expected: ${short(p.expected)}`);
      if (p.predicted) out.push(`  - predicted: ${short(p.predicted)}`, `  - quote: ${short(p.predicted.quote)}`);
    }
    out.push("");
  }
  return out.join("\n") + "\n";
}

// --- CLI: re-score a saved results file ------------------------------------

async function* walk(dir: string): AsyncGenerator<string> {
  for await (const e of Deno.readDir(dir)) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory) yield* walk(p);
    else if (e.isFile && e.name.endsWith(".json")) yield p;
  }
}

export function readResults(text: string): ResultLine[] {
  return text.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l) as ResultLine);
}

if (import.meta.main) {
  const i = Deno.args.indexOf("--results");
  const path = i >= 0 ? Deno.args[i + 1] : undefined;
  if (!path) {
    console.error("usage: score.ts --results results/<tag>.jsonl");
    Deno.exit(2);
  }
  const lines = readResults(await Deno.readTextFile(path));
  // --corpus <dir>: re-read each document's `expected` from the corpus by
  // document id before scoring. A results line snapshots the labels as they
  // were when the model ran, so a label corrected after the run would
  // otherwise never change the score, and a re-score would look like
  // confirmation (round 2, 2026-11-03: five corrections, identical totals).
  // Only labels are swapped; the model's answer and the index it saw stay.
  const c = Deno.args.indexOf("--corpus");
  if (c >= 0 && Deno.args[c + 1]) {
    const byId = new Map<string, ExpectedFact[]>();
    for await (const f of walk(Deno.args[c + 1])) {
      const doc = JSON.parse(await Deno.readTextFile(f));
      if (doc && typeof doc.id === "string" && Array.isArray(doc.expected?.facts)) byId.set(doc.id, doc.expected.facts);
    }
    let swapped = 0;
    for (const l of lines) {
      const e = byId.get(l.docId);
      if (e) { l.expected = e; swapped++; }
    }
    console.log(`labels reloaded from corpus for ${swapped}/${lines.length} lines`);
  }
  for (const l of lines) {
    l.score = scoreDoc(l.expected, l.parsed ?? { facts: [], rejected: [], parseFailed: true }, l);
  }
  const tag = lines[0]?.tag ?? "rescored";
  const mdPath = path.replace(/\.jsonl$/, "") + ".md";
  await Deno.writeTextFile(mdPath, renderReport(tag, lines));
  for (const s of summarize(lines)) console.log(`${s.model}: ${s.pass ? "PASS" : "FAIL"} (FP new_task ${s.byType.new_task.fp}, invented ${s.invented}, FP cancel ${s.byType.cancel.fp})`);
  console.log(`wrote ${mdPath}`);
}
