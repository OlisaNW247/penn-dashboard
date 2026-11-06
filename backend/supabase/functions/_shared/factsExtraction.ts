// Server-side `extract-facts` (Phase 2 of docs/DAY_PLANNER_RESEARCH_2026-11-03.md):
// read each pooled course document ONCE per revision, ask a model what it
// changes about the course's work, check the answer in code, and store the
// accepted facts for every classmate to be served in the manifest. The
// prompt, the strict schema and the checks are `facts.ts` (Phase 0, measured
// in docs/EXTRACT_FACTS_BENCH_2026-11-03.md); this file is the machinery
// around them: which documents, against which item index, within which
// budget, with which retries, recorded how.
//
// Everything here is course-level. No function in this file takes, logs or
// stores a user id, so there is nothing to leak: the student whose upload
// triggered an extraction is not an input to it.
//
// Split in two on purpose, like `quota.ts`/`outcomes.ts`: the logic takes a
// `FactsStore` and a `fetch`, so a test drives it with an in-memory store and
// a fake OpenRouter and no Postgres; `supabaseFactsStore` is the only part
// that knows table names.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import {
  buildFactsMessages,
  FACTS_JSON_SCHEMA,
  parseFacts,
  type Fact,
  type FactsDocument,
  type IndexItem,
  type Meeting,
} from "./facts.ts";
import { chatCompletionJSONWithUsage, UpstreamError, type CompletionUsage } from "./openrouter.ts";
import {
  selectDocumentText,
  selectLiveDocumentMetaForFacts,
  selectCatalogEntriesForCourses,
  type FactsDocumentMetaRow,
} from "./db.ts";
import { academicSemester, type CatalogEntryWire } from "./catalog.ts";

/** The document kinds worth reading for facts. `assignment` is the index, not
 * a source (its own due date is the fact); `home` and `website` are standing
 * reference material the profile extractor reads; `file` is gated and large.
 * Widening this is a cost decision, so it lives here and not in the schema. */
export const FACT_ELIGIBLE_KINDS: readonly string[] = ["announcement", "ed", "page", "module", "syllabus"];

export const FACTS_DEFAULT_MODEL = "anthropic/claude-haiku-5.5";
export const MAX_FACT_ATTEMPTS = 3;
export const DEFAULT_COURSE_DAILY_LIMIT = 60;
export const DEFAULT_MONTHLY_GLOBAL_LIMIT = 5000;
export const DEFAULT_COURSE_MONTHLY_LIMIT = 400;
const MODEL_TIMEOUT_MS = 20_000;
/** Below this much of the run's budget left, a document is not started: the
 *  claim spends a budget unit and an attempt, and a model call squeezed into
 *  a second or two times out and counts toward giving the document up. */
export const MIN_REMAINING_MS = 8_000;
const MAX_TOKENS = 4000;
/** The item index is capped so one course with hundreds of work items cannot
 * balloon every prompt. Sorted by due date (undated last) before the cut. */
const MAX_INDEX_ITEMS = 200;
const RUNNING_STALE_MS = 5 * 60_000;
const EXTRACTION_ID_CHUNK = 100;

export type ClaimResult = "claimed" | "not_pending" | "skipped_budget";

/** A stored extraction row, as far as deciding "pending" needs it. */
export interface ExtractionState {
  documentID: string;
  contentHash: string;
  status: "pending" | "running" | "done" | "failed" | "skipped_budget";
  attempts: number;
  updatedAt: string;
}

export interface FactsLimits {
  courseDaily: number;
  /** Per course per calendar month: keeps one course's junk revisions from
   *  spending the global cap every other course shares. */
  courseMonthly: number;
  monthlyGlobal: number;
}

export interface FinishInput {
  documentID: string;
  contentHash: string;
  courseID: string;
  status: "done" | "failed";
  facts: Fact[];
  postedAt: string | null;
  rejectedCount: number;
  rejectReasons: Record<string, number>;
  model: string;
  usage: CompletionUsage;
  latencyMs: number;
  /** An error class ("upstream 502", "timeout", "parse_failed") or nothing.
   *  Never document text, never model output. */
  detail?: string;
}

/** Every database touch `extract-facts` makes. */
export interface FactsStore {
  claim(input: {
    documentID: string;
    courseID: string;
    contentHash: string;
    limits: FactsLimits;
  }): Promise<ClaimResult>;
  finish(input: FinishInput): Promise<void>;
  listLiveDocuments(courseIDs: string[], now: Date): Promise<FactsDocumentMetaRow[]>;
  listExtractions(documentIDs: string[]): Promise<ExtractionState[]>;
  /** The text and the hash it has NOW, so a run can tell an edit made
   *  between listing and reading from the revision it listed. */
  loadText(documentID: string): Promise<{ text: string; contentHash: string } | undefined>;
  loadMeetings(courseIDs: string[], now: Date): Promise<Map<string, Meeting[]>>;
}

export interface FactsContext {
  store: FactsStore;
  fetchImpl: typeof fetch;
  apiKey: string;
  model: string;
  now: () => Date;
  limits: FactsLimits;
  /** IANA zone the model resolves "Friday" and "before class" in. Penn only
   *  for now, as every server-side path is. */
  timezone: string;
  provider?: { order?: string[] };
  modelTimeoutMs?: number;
}

// ---------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------

/** The document's post date for the prompt: the stored `posted_at`, else an
 * announcement's `updated_at` (for an announcement that IS the post time),
 * else nothing. Not Ed's `updated_at` (last activity) and not a page's (last
 * edit): a wrong post date resolves "by Friday" to the wrong Friday, and
 * leaving it out only costs the model its anchor. */
export function postedAtFor(row: Pick<FactsDocumentMetaRow, "kind" | "posted_at" | "updated_at">): string | undefined {
  if (row.posted_at) return row.posted_at;
  if (row.kind === "announcement" && row.updated_at) return row.updated_at;
  return undefined;
}

/** The ITEM INDEX the model is shown, built from a course's live documents:
 * every `assignment` (its Canvas source id is the id the phone already keys
 * its work on) and every `module` document that carries a due date, as
 * `module:<source id>` so the two id spaces cannot collide. Dated items
 * first, nearest to `now` first (by |due - now|, either side), then undated
 * by title, capped at `MAX_INDEX_ITEMS`. Oldest-first used to fill the cap
 * with last year's work in a recycled or large course and hide the current
 * weeks, which are the ones a fact can name. */
export function buildItemIndex(
  rows: Array<Pick<FactsDocumentMetaRow, "kind" | "source_id" | "title" | "due_at">>,
  now: Date,
): IndexItem[] {
  const nowMs = now.getTime();
  const distance = (iso: string): number => {
    const ms = Date.parse(iso);
    return Number.isNaN(ms) || Number.isNaN(nowMs) ? Number.MAX_SAFE_INTEGER : Math.abs(ms - nowMs);
  };
  const items: IndexItem[] = [];
  for (const row of rows) {
    if (row.kind === "assignment") {
      items.push({
        sourceID: row.source_id,
        title: row.title,
        ...(row.due_at ? { dueAt: row.due_at } : {}),
        kind: "assignment",
      });
    } else if (row.kind === "module" && row.due_at) {
      items.push({ sourceID: `module:${row.source_id}`, title: row.title, dueAt: row.due_at, kind: "module_item" });
    }
  }
  items.sort((a, b) => {
    if (a.dueAt && b.dueAt) {
      return distance(a.dueAt) - distance(b.dueAt) || Date.parse(a.dueAt) - Date.parse(b.dueAt) ||
        a.sourceID.localeCompare(b.sourceID);
    }
    if (a.dueAt) return -1;
    if (b.dueAt) return 1;
    return a.title.localeCompare(b.title) || a.sourceID.localeCompare(b.sourceID);
  });
  return items.slice(0, MAX_INDEX_ITEMS);
}

const WEEKDAYS: Meeting["weekday"][] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function clock(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/** The catalog's meeting pattern for one course as the prompt's CLASS
 * MEETINGS block wants it. The catalog's weekday is 1 (Sunday) to 7
 * (Saturday); it has no room. Duplicates (cross-listed sections that meet at
 * the same time) collapse to one line. */
export function meetingsFromCatalog(entry: Pick<CatalogEntryWire, "meetings"> | undefined): Meeting[] {
  if (!entry) return [];
  const seen = new Set<string>();
  const out: Meeting[] = [];
  for (const m of entry.meetings) {
    const weekday = WEEKDAYS[m.weekday - 1];
    if (!weekday || !Number.isFinite(m.startMinutes) || !Number.isFinite(m.endMinutes)) continue;
    const meeting: Meeting = { weekday, start: clock(m.startMinutes), end: clock(m.endMinutes) };
    const key = `${meeting.weekday} ${meeting.start}-${meeting.end}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(meeting);
  }
  return out;
}

/** Whether a (document, revision) still needs extracting, given its stored
 * row. The database's `claim_fact_extraction` is the authority (it decides
 * atomically); this mirrors it so a run does not spend a slot on rows the
 * claim would refuse. */
export function needsExtraction(state: ExtractionState | undefined, now: Date): boolean {
  if (!state) return true;
  switch (state.status) {
    case "done":
      return false;
    case "failed":
      return state.attempts < MAX_FACT_ATTEMPTS;
    case "running": {
      if (state.attempts >= MAX_FACT_ATTEMPTS) return false;
      return now.getTime() - Date.parse(state.updatedAt) > RUNNING_STALE_MS;
    }
    default:
      return true; // pending, skipped_budget
  }
}

function countReasons(rejected: Array<{ reason: string }>): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const r of rejected) counts[r.reason] = (counts[r.reason] ?? 0) + 1;
  return counts;
}

// ---------------------------------------------------------------------
// One document
// ---------------------------------------------------------------------

export type DocumentResult =
  | { status: "done"; facts: number; rejected: number }
  | { status: "failed"; detail: string }
  | { status: "skipped_budget" }
  | { status: "not_pending" };

/** The row `extractFactsForDocument` reads: the metadata plus the text. */
export type FactsDocumentRow = FactsDocumentMetaRow & { text: string };

/**
 * Extracts facts from one document against `index` and `meetings`, within
 * budget, and stores the outcome.
 *
 * The order is the point. The claim comes FIRST and is atomic (it also spends
 * the budget), so two overlapping calls cannot both pay for the same
 * revision, and a document that is already done, given up on or in flight
 * costs nothing. Then one model call, bounded to 20 s, its timer cleared in
 * `finally` (the `quota.ts` lesson: a timer nothing clears fires later and
 * lies). A model error, an empty answer or an unparseable one becomes a
 * `failed` row, retried by a later run until `MAX_FACT_ATTEMPTS`. Never
 * throws for a model problem; a store problem propagates, and the runner
 * treats that as "stop this run".
 *
 * An answer that parses to zero facts, or whose every fact `parseFacts`
 * rejected, is `done` with a count of 0: the document was read and the
 * answer is "nothing", and re-asking an unchanged document would only pay
 * again for the same nothing.
 */
export async function extractFactsForDocument(
  ctx: FactsContext,
  row: FactsDocumentRow,
  index: IndexItem[],
  meetings: Meeting[],
): Promise<DocumentResult> {
  const claim = await ctx.store.claim({
    documentID: row.id,
    courseID: row.course_id,
    contentHash: row.content_hash,
    limits: ctx.limits,
  });
  if (claim !== "claimed") return { status: claim };

  const postedAt = postedAtFor(row);
  const doc: FactsDocument = {
    id: row.id,
    course: row.course_code,
    kind: row.kind as FactsDocument["kind"],
    title: row.title,
    ...(postedAt ? { postedAt } : {}),
    text: row.text,
    index,
    meetings,
    timezone: ctx.timezone,
    now: ctx.now().toISOString(),
  };
  const { system, user } = buildFactsMessages(doc);

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ctx.modelTimeoutMs ?? MODEL_TIMEOUT_MS);
  const base = {
    documentID: row.id,
    contentHash: row.content_hash,
    courseID: row.course_id,
    postedAt: postedAt ?? null,
    model: ctx.model,
  };

  try {
    let completion;
    try {
      completion = await chatCompletionJSONWithUsage({
        fetchImpl: ctx.fetchImpl,
        apiKey: ctx.apiKey,
        model: ctx.model,
        provider: ctx.provider,
        messages: [{ role: "system", content: system }, { role: "user", content: user }],
        maxTokens: MAX_TOKENS,
        temperature: 0,
        reasoning: { effort: "low" },
        jsonSchema: { name: "facts", schema: FACTS_JSON_SCHEMA },
        signal: controller.signal,
      });
    } catch (err) {
      const detail = controller.signal.aborted
        ? "timeout"
        : err instanceof UpstreamError
        ? `upstream ${err.status ?? "network"}`
        : "error";
      return await failed(ctx, base, detail, Date.now() - started);
    }

    const parsed = parseFacts(completion.content, doc);
    if (parsed.parseFailed) {
      return await failed(ctx, base, "parse_failed", Date.now() - started, completion.usage);
    }

    await ctx.store.finish({
      ...base,
      status: "done",
      facts: parsed.facts,
      rejectedCount: parsed.rejected.length,
      rejectReasons: countReasons(parsed.rejected),
      model: completion.model,
      usage: completion.usage,
      latencyMs: Date.now() - started,
    });
    return { status: "done", facts: parsed.facts.length, rejected: parsed.rejected.length };
  } finally {
    clearTimeout(timer);
  }
}

async function failed(
  ctx: FactsContext,
  base: Omit<FinishInput, "status" | "facts" | "rejectedCount" | "rejectReasons" | "usage" | "latencyMs" | "detail">,
  detail: string,
  latencyMs: number,
  usage: CompletionUsage = {},
): Promise<DocumentResult> {
  await ctx.store.finish({
    ...base,
    status: "failed",
    facts: [],
    rejectedCount: 0,
    rejectReasons: {},
    usage,
    latencyMs,
    detail,
  });
  return { status: "failed", detail };
}

// ---------------------------------------------------------------------
// Many documents
// ---------------------------------------------------------------------

export interface RunStats {
  /** Documents a model call was started for. */
  attempted: number;
  done: number;
  failed: number;
  skippedBudget: number;
  /** Facts accepted this run. */
  facts: number;
  /** Candidates still pending after this run (over the cap, or cut by time). */
  remaining: number;
}

export interface RunOptions {
  /** Most documents to extract in one run. */
  maxDocuments: number;
  /** Wall-clock budget for the whole run; no new document starts after it. */
  budgetMs: number;
  concurrency?: number;
}

const EMPTY_STATS = (): RunStats => ({ attempted: 0, done: 0, failed: 0, skippedBudget: 0, facts: 0, remaining: 0 });

/**
 * Extracts up to `maxDocuments` pending eligible documents across
 * `courseIDs`, newest first, a few at a time, inside `budgetMs`.
 *
 * Newest first because a first sync of a big course pools a term of posts,
 * and the one that matters today is the one posted this week; the per-course
 * daily budget then spreads the older backlog over the days after. A course
 * whose budget says no is dropped for the rest of the run (its other
 * documents would only be refused too). A store failure ends the run quietly:
 * this is a background enrichment, so it logs a class and a count and returns
 * what it has, never an error to whoever triggered it.
 */
export async function runPendingFactExtractionsWith(
  ctx: FactsContext,
  courseIDs: string[],
  options: RunOptions,
): Promise<RunStats> {
  const stats = EMPTY_STATS();
  if (courseIDs.length === 0) return stats;
  const deadline = Date.now() + options.budgetMs;

  try {
    const now = ctx.now();
    const live = await ctx.store.listLiveDocuments(courseIDs, now);
    const candidates = live.filter((row) => FACT_ELIGIBLE_KINDS.includes(row.kind));
    const states = await ctx.store.listExtractions(candidates.map((row) => row.id));
    const stateByKey = new Map(states.map((s) => [`${s.documentID}\u0000${s.contentHash}`, s]));

    const pending = candidates
      .filter((row) => needsExtraction(stateByKey.get(`${row.id}\u0000${row.content_hash}`), now))
      .sort((a, b) => recency(b) - recency(a) || a.id.localeCompare(b.id));
    const batch = pending.slice(0, options.maxDocuments);
    stats.remaining = pending.length - batch.length;
    if (batch.length === 0) return stats;

    const involved = [...new Set(batch.map((row) => row.course_id))];
    const indexByCourse = new Map<string, IndexItem[]>();
    for (const courseID of involved) {
      indexByCourse.set(courseID, buildItemIndex(live.filter((row) => row.course_id === courseID), now));
    }
    let meetingsByCourse = new Map<string, Meeting[]>();
    try {
      meetingsByCourse = await ctx.store.loadMeetings(involved, now);
    } catch (err) {
      // The meeting pattern only sharpens "before class"; without it the
      // model still reads the post. Never fail the batch over it.
      console.warn("extract-facts: meeting pattern unavailable:", err instanceof Error ? err.message : "error");
    }

    const budgetSpent = new Set<string>();
    let next = 0;
    let stop = false;
    const worker = async () => {
      while (!stop) {
        const i = next++;
        if (i >= batch.length) return;
        const row = batch[i];
        if (deadline - Date.now() < MIN_REMAINING_MS) {
          // Leave it pending: nothing claimed, no budget or attempt charged.
          stats.remaining += batch.length - i;
          stop = true;
          return;
        }
        if (budgetSpent.has(row.course_id)) {
          stats.remaining += 1;
          continue;
        }
        const loaded = await ctx.store.loadText(row.id);
        if (loaded === undefined || loaded.text.trim().length === 0) continue;
        // Edited since it was listed: the text in hand belongs to a newer
        // hash than the one that would be claimed, and storing it under the
        // old hash would attach new words to the old revision. Skip without
        // touching any row; the next run lists the new revision itself.
        if (loaded.contentHash !== row.content_hash) continue;
        const text = loaded.text;
        // loadText took time too: re-check before the claim charges anything.
        const left = deadline - Date.now();
        if (left < MIN_REMAINING_MS) {
          stats.remaining += batch.length - i;
          stop = true;
          return;
        }
        const result = await extractFactsForDocument(
          { ...ctx, modelTimeoutMs: Math.min(ctx.modelTimeoutMs ?? MODEL_TIMEOUT_MS, left) },
          { ...row, text },
          indexByCourse.get(row.course_id) ?? [],
          meetingsByCourse.get(row.course_id) ?? [],
        );
        switch (result.status) {
          case "done":
            stats.attempted += 1;
            stats.done += 1;
            stats.facts += result.facts;
            break;
          case "failed":
            stats.attempted += 1;
            stats.failed += 1;
            break;
          case "skipped_budget":
            stats.skippedBudget += 1;
            budgetSpent.add(row.course_id);
            break;
          case "not_pending":
            break;
        }
        // Counts and ids of rows only; never text, quotes or titles.
        console.log(
          `extract-facts: course ${row.course_id} doc ${row.id} -> ${result.status}` +
            (result.status === "failed" ? ` (${result.detail})` : ""),
        );
      }
    };
    // A store failure in one worker stops the others before they start
    // another document, then ends the run (caught below).
    const guarded = () => worker().catch((err) => {
      stop = true;
      throw err;
    });
    const workers = Math.max(1, Math.min(options.concurrency ?? 3, batch.length));
    await Promise.all(Array.from({ length: workers }, guarded));
  } catch (err) {
    logRunEnded(err);
  }
  return stats;
}

function logRunEnded(err: unknown): void {
  console.error("extract-facts: run ended early:", err instanceof Error ? err.message : "error");
}

function recency(row: Pick<FactsDocumentMetaRow, "posted_at" | "updated_at" | "fetched_at">): number {
  const ms = Date.parse(row.posted_at ?? row.updated_at ?? row.fetched_at);
  return Number.isNaN(ms) ? 0 : ms;
}

// ---------------------------------------------------------------------
// Wiring: environment and Supabase
// ---------------------------------------------------------------------

function positiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

export const FACTS_MAX_DOCUMENTS_PER_RUN = 10;

/** True when the operator has switched fact extraction off
 * (`LHF_FACTS_DISABLED=1`). Read per call, not at module load, so the switch
 * works without a cold start in tests; in production a changed secret takes
 * effect on the next isolate either way. */
export function factsDisabled(): boolean {
  const raw = Deno.env.get("LHF_FACTS_DISABLED");
  return raw === "1" || raw === "true";
}

/** The context production uses: the real `fetch`, `OPENROUTER_API_KEY`,
 * `LHF_FACTS_MODEL` (default Haiku 5.5) and the budget limits from the
 * environment. `undefined` when there is no key, which the caller treats as
 * "not configured" rather than an error. */
export function factsContextFromEnv(client: SupabaseClient): FactsContext | undefined {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) return undefined;
  const order = (Deno.env.get("LHF_PROVIDER_ORDER") ?? "").split(",").map((e) => e.trim()).filter((e) => e.length > 0);
  return {
    store: supabaseFactsStore(client),
    fetchImpl: fetch,
    apiKey,
    model: Deno.env.get("LHF_FACTS_MODEL") ?? FACTS_DEFAULT_MODEL,
    now: () => new Date(),
    limits: {
      courseDaily: positiveInt(Deno.env.get("FACTS_COURSE_DAILY_LIMIT"), DEFAULT_COURSE_DAILY_LIMIT),
      courseMonthly: positiveInt(Deno.env.get("FACTS_COURSE_MONTHLY_LIMIT"), DEFAULT_COURSE_MONTHLY_LIMIT),
      monthlyGlobal: positiveInt(Deno.env.get("FACTS_MONTHLY_GLOBAL_LIMIT"), DEFAULT_MONTHLY_GLOBAL_LIMIT),
    },
    timezone: Deno.env.get("FACTS_TIMEZONE") ?? "America/New_York",
    provider: order.length > 0 ? { order } : undefined,
  };
}

/**
 * What `sync` and the `extract-facts` function call: run the pending
 * extractions for these courses with the production context. Never throws
 * (it is an enrichment; see the rule in the manifest code), does nothing when
 * switched off or unconfigured, and returns the run's counts.
 */
export async function runPendingFactExtractions(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<RunStats> {
  try {
    if (factsDisabled()) return EMPTY_STATS();
    const ctx = factsContextFromEnv(client);
    if (!ctx) {
      console.warn("extract-facts: OPENROUTER_API_KEY is not configured");
      return EMPTY_STATS();
    }
    return await runPendingFactExtractionsWith(ctx, courseIDs, {
      maxDocuments: positiveInt(Deno.env.get("FACTS_MAX_DOCUMENTS_PER_RUN"), FACTS_MAX_DOCUMENTS_PER_RUN),
      budgetMs: positiveInt(Deno.env.get("FACTS_RUN_BUDGET_MS"), 50_000),
    });
  } catch (err) {
    console.error("extract-facts: failed:", err instanceof Error ? err.message : "error");
    return EMPTY_STATS();
  }
}

function chunks<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export function supabaseFactsStore(client: SupabaseClient): FactsStore {
  return {
    async claim({ documentID, courseID, contentHash, limits }) {
      const { data, error } = await client.rpc("claim_fact_extraction", {
        p_document_id: documentID,
        p_course_id: courseID,
        p_content_hash: contentHash,
        p_max_attempts: MAX_FACT_ATTEMPTS,
        p_course_daily_limit: limits.courseDaily,
        p_monthly_global_limit: limits.monthlyGlobal,
        p_course_monthly_limit: limits.courseMonthly,
      });
      if (error) throw new Error(`claim_fact_extraction: ${error.message}`);
      if (data !== "claimed" && data !== "not_pending" && data !== "skipped_budget") {
        throw new Error("claim_fact_extraction: unexpected answer");
      }
      return data;
    },

    async finish(input) {
      // One transaction on the database side (`finish_fact_extraction`,
      // 20261105090000): delete the old facts, insert the new, update the
      // row. Three separate statements let a run that died after the insert
      // be retried and hand phones the same facts under new seqs (a fact's
      // id on the phone is documentID+seq).
      const { error } = await client.rpc("finish_fact_extraction", {
        p_document_id: input.documentID,
        p_content_hash: input.contentHash,
        p_status: input.status,
        p_facts: input.status === "done"
          ? input.facts.map((fact) => ({
            fact_type: fact.type,
            target_source_id: fact.target,
            title: fact.title ?? null,
            due_at: fact.due_at === null ? null : new Date(fact.due_at).toISOString(),
            kind: fact.kind ?? null,
            quote: fact.quote,
            confidence: fact.confidence,
          }))
          : [],
        p_posted_at: input.postedAt,
        p_fact_count: input.facts.length,
        p_rejected_count: input.rejectedCount,
        p_reject_reasons: input.rejectReasons,
        p_model: input.model,
        p_prompt_tokens: input.usage.promptTokens ?? null,
        p_completion_tokens: input.usage.completionTokens ?? null,
        p_reasoning_tokens: input.usage.reasoningTokens ?? null,
        p_cost_usd: input.usage.cost ?? null,
        p_latency_ms: input.latencyMs,
        p_detail: input.detail ? input.detail.slice(0, 200) : null,
      });
      if (error) throw new Error(`finish_fact_extraction: ${error.message}`);
    },

    listLiveDocuments: (courseIDs, now) => selectLiveDocumentMetaForFacts(client, courseIDs, now),

    async listExtractions(documentIDs) {
      const out: ExtractionState[] = [];
      for (const ids of chunks(documentIDs, EXTRACTION_ID_CHUNK)) {
        const { data, error } = await client
          .from("course_fact_extractions")
          .select("document_id, content_hash, status, attempts, updated_at")
          .in("document_id", ids);
        if (error) throw new Error(`listExtractions: ${error.message}`);
        for (const r of (data ?? []) as Array<Record<string, unknown>>) {
          out.push({
            documentID: String(r.document_id),
            contentHash: String(r.content_hash),
            status: r.status as ExtractionState["status"],
            attempts: Number(r.attempts),
            updatedAt: String(r.updated_at),
          });
        }
      }
      return out;
    },

    loadText: (documentID) => selectDocumentText(client, documentID),

    async loadMeetings(courseIDs, now) {
      const entries = await selectCatalogEntriesForCourses(client, courseIDs, academicSemester(now));
      return new Map(entries.map((entry) => [entry.courseID, meetingsFromCatalog(entry)]));
    },
  };
}

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/**
 * Starts fact extraction for `courseIDs` after an upload's response is
 * decided, and returns at once. `EdgeRuntime.waitUntil` keeps the isolate
 * alive for the work when the runtime has it; without it (a test, local
 * `deno serve`) the work simply runs unobserved. Whatever goes wrong -- the
 * kill switch, a missing `EdgeRuntime`, a runner that throws synchronously or
 * returns a rejected promise -- is logged and swallowed: an enrichment must
 * never fail the exchange it decorates. `run` is injectable for tests only.
 */
export function scheduleFactExtraction(
  client: SupabaseClient,
  courseIDs: string[],
  run: (client: SupabaseClient, courseIDs: string[]) => Promise<unknown> = runPendingFactExtractions,
): void {
  if (courseIDs.length === 0 || factsDisabled()) return;
  try {
    const work = Promise.resolve(run(client, courseIDs)).catch((err) => {
      console.error("sync: fact extraction failed", err instanceof Error ? err.message : String(err));
    });
    if (typeof EdgeRuntime !== "undefined" && typeof EdgeRuntime.waitUntil === "function") {
      EdgeRuntime.waitUntil(work);
    }
  } catch (err) {
    console.error("sync: fact extraction not started", err instanceof Error ? err.message : String(err));
  }
}
