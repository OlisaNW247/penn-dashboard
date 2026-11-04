// Server-side fact extraction (`_shared/factsExtraction.ts`) with an
// in-memory `FactsStore` and a fake OpenRouter `fetch`: no Postgres, no
// network. The store mirrors `claim_fact_extraction`'s rules (done/given-up/
// in-flight are not pending, two budgets) so these tests pin the behaviour
// the SQL is written to provide; the SQL itself is exercised by
// `rls.test.sql` against a scratch Postgres.
//
// Fixtures are three of the labelled synthetic documents from
// bench/extract-facts/corpus/synthetic (copied under test/fixtures/facts,
// which is the only directory the test runner may read).
import { strict as assert } from "node:assert";
import {
  buildItemIndex,
  extractFactsForDocument,
  FACT_ELIGIBLE_KINDS,
  meetingsFromCatalog,
  needsExtraction,
  postedAtFor,
  runPendingFactExtractionsWith,
  type ClaimResult,
  type ExtractionState,
  type FactsContext,
  type FactsDocumentRow,
  type FactsStore,
  type FinishInput,
} from "../supabase/functions/_shared/factsExtraction.ts";
import type { FactsDocumentMetaRow } from "../supabase/functions/_shared/db.ts";
import type { Fact, IndexItem, Meeting } from "../supabase/functions/_shared/facts.ts";

interface CorpusDoc {
  id: string;
  course: string;
  kind: FactsDocumentRow["kind"];
  title: string;
  postedAt: string;
  text: string;
  index: IndexItem[];
  meetings: Meeting[];
  timezone: string;
  now: string;
}

async function fixture(name: string): Promise<CorpusDoc> {
  return JSON.parse(await Deno.readTextFile(`test/fixtures/facts/${name}.json`));
}

const COURSE = "4001";

function metaRow(doc: CorpusDoc, overrides: Partial<FactsDocumentMetaRow> = {}): FactsDocumentMetaRow {
  return {
    id: `announcement:${COURSE}:${doc.id}`,
    course_id: COURSE,
    course_code: doc.course,
    kind: doc.kind,
    source_id: doc.id,
    title: doc.title,
    content_hash: "hash-1",
    updated_at: doc.postedAt,
    fetched_at: doc.now,
    due_at: null,
    posted_at: doc.postedAt,
    ...overrides,
  };
}

function assignmentRows(doc: CorpusDoc): FactsDocumentMetaRow[] {
  return doc.index.map((item) => ({
    id: `assignment:${COURSE}:${item.sourceID}`,
    course_id: COURSE,
    course_code: doc.course,
    kind: "assignment",
    source_id: item.sourceID,
    title: item.title,
    content_hash: `h-${item.sourceID}`,
    updated_at: null,
    fetched_at: doc.now,
    due_at: item.dueAt ?? null,
    posted_at: null,
  }));
}

/** An in-memory store with the claim semantics of the SQL function. */
class MemoryStore implements FactsStore {
  rows: FactsDocumentMetaRow[] = [];
  texts = new Map<string, string>();
  /** Hash a document has "now" when read, if different from its listed one. */
  hashNow = new Map<string, string>();
  meetings = new Map<string, Meeting[]>();
  extractions = new Map<string, ExtractionState & { factCount?: number; detail?: string; rejectReasons?: Record<string, number>; usage?: FinishInput["usage"]; model?: string; rejectedCount?: number }>();
  facts: Array<Fact & { documentID: string; contentHash: string; postedAt: string | null }> = [];
  budget = new Map<string, number>(); // course -> extractions today
  courseMonth = new Map<string, number>();
  monthly = 0;
  failLists = false;
  claims: ClaimResult[] = [];

  private key(id: string, hash: string) {
    return `${id}\u0000${hash}`;
  }

  async claim(input: Parameters<FactsStore["claim"]>[0]): Promise<ClaimResult> {
    const k = this.key(input.documentID, input.contentHash);
    const existing = this.extractions.get(k);
    const result = (() => {
      if (existing?.status === "done") return "not_pending" as const;
      if (existing && (existing.status === "failed" || existing.status === "running") && existing.attempts >= 3) {
        return "not_pending" as const;
      }
      if (existing?.status === "running") return "not_pending" as const;
      if (this.monthly >= input.limits.monthlyGlobal) {
        this.extractions.set(k, { ...(existing ?? this.blank(input)), status: "skipped_budget" });
        return "skipped_budget" as const;
      }
      if ((this.courseMonth.get(input.courseID) ?? 0) >= input.limits.courseMonthly) {
        this.extractions.set(k, { ...(existing ?? this.blank(input)), status: "skipped_budget" });
        return "skipped_budget" as const;
      }
      const used = this.budget.get(input.courseID) ?? 0;
      if (used >= input.limits.courseDaily) {
        this.extractions.set(k, { ...(existing ?? this.blank(input)), status: "skipped_budget" });
        return "skipped_budget" as const;
      }
      this.budget.set(input.courseID, used + 1);
      this.courseMonth.set(input.courseID, (this.courseMonth.get(input.courseID) ?? 0) + 1);
      this.monthly += 1;
      const base = existing ?? this.blank(input);
      this.extractions.set(k, { ...base, status: "running", attempts: base.attempts + 1, updatedAt: new Date().toISOString() });
      return "claimed" as const;
    })();
    this.claims.push(result);
    return result;
  }

  private blank(input: Parameters<FactsStore["claim"]>[0]) {
    return {
      documentID: input.documentID,
      contentHash: input.contentHash,
      status: "pending" as const,
      attempts: 0,
      updatedAt: new Date().toISOString(),
    };
  }

  async finish(input: FinishInput) {
    const k = this.key(input.documentID, input.contentHash);
    const existing = this.extractions.get(k)!;
    this.facts = this.facts.filter((f) => !(f.documentID === input.documentID && f.contentHash === input.contentHash));
    if (input.status === "done") {
      for (const fact of input.facts) {
        this.facts.push({ ...fact, documentID: input.documentID, contentHash: input.contentHash, postedAt: input.postedAt });
      }
    }
    this.extractions.set(k, {
      ...existing,
      status: input.status,
      factCount: input.facts.length,
      detail: input.detail,
      rejectReasons: input.rejectReasons,
      rejectedCount: input.rejectedCount,
      usage: input.usage,
      model: input.model,
    });
  }

  async listLiveDocuments() {
    if (this.failLists) throw new Error("db down");
    return this.rows;
  }
  async listExtractions() {
    return [...this.extractions.values()];
  }
  async loadText(id: string) {
    const text = this.texts.get(id);
    if (text === undefined) return undefined;
    const listed = this.rows.find((r) => r.id === id)?.content_hash ?? "";
    return { text, contentHash: this.hashNow.get(id) ?? listed };
  }
  async loadMeetings() {
    return this.meetings;
  }
}

interface Call {
  body: Record<string, unknown>;
}

function fakeModel(
  respond: (call: number, body: Record<string, unknown>) => Response | Promise<Response>,
): { fetchImpl: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fetchImpl = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    calls.push({ body });
    return await respond(calls.length, body);
  }) as typeof fetch;
  return { fetchImpl, calls };
}

const answer = (facts: unknown[], usage: Record<string, unknown> = {}) =>
  new Response(
    JSON.stringify({
      choices: [{ message: { content: JSON.stringify({ facts }) } }],
      usage: {
        prompt_tokens: 1200,
        completion_tokens: 150,
        completion_tokens_details: { reasoning_tokens: 40 },
        cost: 0.0004,
        ...usage,
      },
    }),
    { status: 200 },
  );

const cancelFact = {
  type: "cancel",
  target: "a-41803",
  title: null,
  due_at: null,
  kind: null,
  quote: "we are cancelling HW3 entirely",
  confidence: "high",
};

function context(store: FactsStore, fetchImpl: typeof fetch, over: Partial<FactsContext> = {}): FactsContext {
  return {
    store,
    fetchImpl,
    apiKey: "k",
    model: "anthropic/claude-haiku-5.5",
    now: () => new Date("2026-10-06T14:14:00Z"),
    limits: { courseDaily: 60, courseMonthly: 400, monthlyGlobal: 5000 },
    timezone: "America/New_York",
    ...over,
  };
}

async function seeded(name = "01-cis-hw3-cancelled") {
  const doc = await fixture(name);
  const store = new MemoryStore();
  const row = metaRow(doc);
  store.rows = [row, ...assignmentRows(doc)];
  store.texts.set(row.id, doc.text);
  store.meetings.set(COURSE, doc.meetings);
  return { doc, store, row, full: { ...row, text: doc.text } as FactsDocumentRow };
}

// ---------------------------------------------------------------------
// One document
// ---------------------------------------------------------------------

Deno.test("accepted and rejected facts: the cancel is stored, the invented-target fact is counted and dropped", async () => {
  const { doc, store, full } = await seeded();
  const bad = { ...cancelFact, target: "a-99999" }; // not in the index
  const invented = { ...cancelFact, quote: "this sentence is not in the post" };
  const { fetchImpl } = fakeModel(() => answer([cancelFact, bad, invented]));
  const result = await extractFactsForDocument(context(store, fetchImpl), full, buildItemIndex(store.rows), doc.meetings);

  assert.deepEqual(result, { status: "done", facts: 1, rejected: 2 });
  assert.equal(store.facts.length, 1);
  assert.equal(store.facts[0].type, "cancel");
  assert.equal(store.facts[0].target, "a-41803");
  assert.equal(store.facts[0].postedAt, doc.postedAt);
  const row = store.extractions.get(`${full.id}\u0000hash-1`)!;
  assert.equal(row.status, "done");
  assert.equal(row.factCount, 1);
  assert.equal(row.rejectedCount, 2);
  assert.deepEqual(row.rejectReasons, { unknown_target: 1, quote_not_in_text: 1 });
  assert.deepEqual(row.usage, { promptTokens: 1200, completionTokens: 150, reasoningTokens: 40, cost: 0.0004 });
  assert.equal(row.model, "anthropic/claude-haiku-5.5");
});

Deno.test("a new_task document stores the task with its resolved date", async () => {
  const { doc, store, full } = await seeded("15-cis-read-before-tuesday");
  const task = {
    type: "new_task",
    target: null,
    title: "Read 3.1-3.3",
    due_at: "2026-11-03T13:45:00-05:00",
    kind: "preparation",
    quote: "please read 3.1-3.3 in the textbook before lecture",
    confidence: "high",
  };
  const { fetchImpl } = fakeModel(() => answer([task]));
  const result = await extractFactsForDocument(context(store, fetchImpl, { now: () => new Date(doc.now) }), full, [], doc.meetings);
  assert.deepEqual(result, { status: "done", facts: 1, rejected: 0 });
  assert.equal(store.facts[0].title, "Read 3.1-3.3");
  assert.equal(store.facts[0].due_at, "2026-11-03T13:45:00-05:00");
  assert.equal(store.facts[0].kind, "preparation");
});

Deno.test("the request: strict json_schema, Haiku, low reasoning, temperature 0, 4000 tokens, never require_parameters", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl, calls } = fakeModel(() => answer([]));
  await extractFactsForDocument(context(store, fetchImpl), full, buildItemIndex(store.rows), doc.meetings);
  const body = calls[0].body;
  assert.equal(body.model, "anthropic/claude-haiku-5.5");
  assert.deepEqual(body.reasoning, { effort: "low" });
  assert.equal(body.temperature, 0);
  assert.equal(body.max_tokens, 4000);
  assert.equal(body.stream, false);
  const format = body.response_format as { type: string; json_schema: { name: string; strict: boolean; schema: { required: string[] } } };
  assert.equal(format.type, "json_schema");
  assert.equal(format.json_schema.name, "facts");
  assert.equal(format.json_schema.strict, true);
  assert.deepEqual(format.json_schema.schema.required, ["facts"]);
  assert.equal("require_parameters" in ((body.provider as Record<string, unknown>) ?? {}), false);
  const messages = body.messages as Array<{ role: string; content: string }>;
  assert.match(messages[1].content, /^Course: CIS 2400/);
  assert.match(messages[1].content, /a-41803 \| HW3: Finite State Machines/);
  assert.match(messages[1].content, /CLASS MEETINGS:\nTue 13:45-15:14 Towne 100/);
  assert.match(messages[1].content, /Current date: 2026-10-06T14:14:00.000Z/);
});

Deno.test("a document with nothing in it is still recorded done, and is never asked again", async () => {
  const { doc, store, full } = await seeded("19-phys-hw-slides-posted");
  const { fetchImpl, calls } = fakeModel(() => answer([]));
  const ctx = context(store, fetchImpl);
  assert.deepEqual(await extractFactsForDocument(ctx, full, [], doc.meetings), { status: "done", facts: 0, rejected: 0 });
  assert.equal(store.extractions.get(`${full.id}\u0000hash-1`)?.status, "done");
  assert.deepEqual(await extractFactsForDocument(ctx, full, [], doc.meetings), { status: "not_pending" });
  assert.equal(calls.length, 1);
});

Deno.test("dedupe is by (id, content_hash): the same revision is skipped, an edited one is extracted again", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl, calls } = fakeModel(() => answer([cancelFact]));
  const ctx = context(store, fetchImpl);
  await extractFactsForDocument(ctx, full, buildItemIndex(store.rows), doc.meetings);
  assert.equal((await extractFactsForDocument(ctx, full, buildItemIndex(store.rows), doc.meetings)).status, "not_pending");
  assert.equal(calls.length, 1);
  const edited = { ...full, content_hash: "hash-2" };
  assert.equal((await extractFactsForDocument(ctx, edited, buildItemIndex(store.rows), doc.meetings)).status, "done");
  assert.equal(calls.length, 2);
  assert.equal(store.facts.length, 2, "one fact per revision, kept apart by content_hash");
});

Deno.test("budget exhausted: the model is not called and the row says skipped_budget", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl, calls } = fakeModel(() => answer([]));
  store.budget.set(COURSE, 60);
  const result = await extractFactsForDocument(context(store, fetchImpl), full, [], doc.meetings);
  assert.deepEqual(result, { status: "skipped_budget" });
  assert.equal(calls.length, 0);
  assert.equal(store.extractions.get(`${full.id}\u0000hash-1`)?.status, "skipped_budget");

  // The next UTC day's counter is empty: the same document is picked up.
  store.budget.clear();
  assert.equal((await extractFactsForDocument(context(store, fetchImpl), full, [], doc.meetings)).status, "done");
});

Deno.test("the per-course monthly cap skips even when the daily and global caps have room", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl, calls } = fakeModel(() => answer([]));
  store.courseMonth.set(COURSE, 400);
  assert.deepEqual(await extractFactsForDocument(context(store, fetchImpl), full, [], doc.meetings), { status: "skipped_budget" });
  assert.equal(calls.length, 0);
  assert.equal(store.monthly, 0, "one course's junk must not have spent the global cap");
});

Deno.test("a document edited between listing and reading is skipped, with no row and no model call", async () => {
  const { store, row } = await seeded();
  store.hashNow.set(row.id, "hash-EDITED");
  const { fetchImpl, calls } = fakeModel(() => answer([cancelFact]));
  const stats = await runPendingFactExtractionsWith(context(store, fetchImpl), [COURSE], { maxDocuments: 5, budgetMs: 5000, concurrency: 1 });
  assert.equal(calls.length, 0);
  assert.equal(store.extractions.size, 0);
  assert.equal(store.facts.length, 0);
  assert.equal(stats.attempted, 0);
});

Deno.test("the global monthly cap also skips", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl, calls } = fakeModel(() => answer([]));
  store.monthly = 5000;
  assert.deepEqual(await extractFactsForDocument(context(store, fetchImpl), full, [], doc.meetings), { status: "skipped_budget" });
  assert.equal(calls.length, 0);
});

Deno.test("a model failure stores a failed row; it is retried until three attempts, then given up", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl, calls } = fakeModel(() => new Response("down", { status: 502 }));
  const ctx = context(store, fetchImpl);
  const key = `${full.id}\u0000hash-1`;
  for (let attempt = 1; attempt <= 3; attempt++) {
    assert.deepEqual(await extractFactsForDocument(ctx, full, [], doc.meetings), { status: "failed", detail: "upstream 502" });
    assert.equal(store.extractions.get(key)?.attempts, attempt);
    assert.equal(store.extractions.get(key)?.status, "failed");
    assert.equal(needsExtraction(store.extractions.get(key), new Date()), attempt < 3);
  }
  assert.deepEqual(await extractFactsForDocument(ctx, full, [], doc.meetings), { status: "not_pending" });
  assert.equal(calls.length, 3, "no fourth call");
  assert.equal(store.facts.length, 0);
});

Deno.test("a model that never answers is cut off at the timeout and recorded as failed", async () => {
  const { doc, store, full } = await seeded();
  const fetchImpl = ((_i: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
    })) as typeof fetch;
  const result = await extractFactsForDocument(context(store, fetchImpl, { modelTimeoutMs: 30 }), full, [], doc.meetings);
  assert.deepEqual(result, { status: "failed", detail: "timeout" });
});

Deno.test("an answer that is not the schema's JSON is a failed row, not zero facts", async () => {
  const { doc, store, full } = await seeded();
  const { fetchImpl } = fakeModel(() =>
    new Response(JSON.stringify({ choices: [{ message: { content: "I could not read this." } }] }), { status: 200 })
  );
  const result = await extractFactsForDocument(context(store, fetchImpl), full, [], doc.meetings);
  assert.deepEqual(result, { status: "failed", detail: "parse_failed" });
  assert.equal(store.extractions.get(`${full.id}\u0000hash-1`)?.status, "failed");
});

// ---------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------

Deno.test("buildItemIndex: assignments and dated modules, dated first by date, module ids prefixed", () => {
  const index = buildItemIndex([
    { kind: "assignment", source_id: "7", title: "Zed", due_at: null },
    { kind: "assignment", source_id: "8", title: "Late", due_at: "2026-12-01T05:00:00Z" },
    { kind: "assignment", source_id: "9", title: "Early", due_at: "2026-11-01T05:00:00Z" },
    { kind: "module", source_id: "7", title: "Week 7", due_at: "2026-11-15T05:00:00Z" },
    { kind: "module", source_id: "8", title: "Undated module", due_at: null },
    { kind: "page", source_id: "1", title: "A page", due_at: null },
  ]);
  assert.deepEqual(index.map((i) => i.sourceID), ["9", "module:7", "8", "7"]);
  assert.equal(index[1].kind, "module_item");
  assert.equal(index[3].dueAt, undefined);
});

Deno.test("meetingsFromCatalog: weekday numbers and minutes become the prompt's block, duplicates collapse", () => {
  const meetings = meetingsFromCatalog({
    meetings: [
      { sectionID: "A", activity: "LEC", weekday: 3, startMinutes: 825, endMinutes: 914 },
      { sectionID: "B", activity: "LEC", weekday: 3, startMinutes: 825, endMinutes: 914 },
      { sectionID: "A", activity: "LEC", weekday: 5, startMinutes: 825, endMinutes: 914 },
      { sectionID: "A", activity: "LEC", weekday: 9, startMinutes: 1, endMinutes: 2 },
    ],
  });
  assert.deepEqual(meetings, [
    { weekday: "Tue", start: "13:45", end: "15:14" },
    { weekday: "Thu", start: "13:45", end: "15:14" },
  ]);
  assert.deepEqual(meetingsFromCatalog(undefined), []);
});

Deno.test("postedAtFor: stored date first, an announcement's updated_at second, never Ed's or a page's", () => {
  assert.equal(postedAtFor({ kind: "ed", posted_at: "2026-10-01T00:00:00Z", updated_at: "2026-10-09T00:00:00Z" }), "2026-10-01T00:00:00Z");
  assert.equal(postedAtFor({ kind: "announcement", posted_at: null, updated_at: "2026-10-09T00:00:00Z" }), "2026-10-09T00:00:00Z");
  assert.equal(postedAtFor({ kind: "ed", posted_at: null, updated_at: "2026-10-09T00:00:00Z" }), undefined);
  assert.equal(postedAtFor({ kind: "page", posted_at: null, updated_at: "2026-10-09T00:00:00Z" }), undefined);
});

Deno.test("needsExtraction mirrors the claim rules", () => {
  const now = new Date("2026-11-04T12:00:00Z");
  const state = (status: ExtractionState["status"], attempts: number, updatedAt = "2026-11-04T11:59:00Z"): ExtractionState => ({
    documentID: "d", contentHash: "h", status, attempts, updatedAt,
  });
  assert.equal(needsExtraction(undefined, now), true);
  assert.equal(needsExtraction(state("done", 1), now), false);
  assert.equal(needsExtraction(state("failed", 2), now), true);
  assert.equal(needsExtraction(state("failed", 3), now), false);
  assert.equal(needsExtraction(state("skipped_budget", 0), now), true);
  assert.equal(needsExtraction(state("running", 1), now), false, "in flight");
  assert.equal(needsExtraction(state("running", 1, "2026-11-04T11:50:00Z"), now), true, "stale: the call died");
  assert.equal(needsExtraction(state("running", 3, "2026-11-04T11:50:00Z"), now), false);
  assert.deepEqual([...FACT_ELIGIBLE_KINDS].sort(), ["announcement", "ed", "module", "page", "syllabus"]);
});

// ---------------------------------------------------------------------
// A run
// ---------------------------------------------------------------------

Deno.test("a run takes eligible documents newest first, up to the cap, and reports what is left", async () => {
  const doc = await fixture("01-cis-hw3-cancelled");
  const store = new MemoryStore();
  const mk = (n: number, posted: string, kind: FactsDocumentRow["kind"] = "announcement") =>
    metaRow(doc, { id: `announcement:${COURSE}:n${n}`, source_id: `n${n}`, kind, posted_at: posted, content_hash: `h${n}` });
  const rows = [
    mk(1, "2026-09-01T00:00:00Z"),
    mk(2, "2026-10-05T00:00:00Z"),
    mk(3, "2026-10-01T00:00:00Z"),
    mk(4, "2026-10-04T00:00:00Z", "home" as FactsDocumentRow["kind"]), // not eligible
  ];
  store.rows = [...rows, ...assignmentRows(doc)];
  for (const r of rows) store.texts.set(r.id, doc.text);
  const order: string[] = [];
  const { fetchImpl } = fakeModel((_n, body) => {
    order.push(((body.messages as Array<{ content: string }>)[1].content.match(/Posted at: (\S+)/) ?? [])[1] ?? "?");
    return answer([]);
  });
  const stats = await runPendingFactExtractionsWith(context(store, fetchImpl), [COURSE], {
    maxDocuments: 2,
    budgetMs: 10_000,
    concurrency: 1,
  });
  assert.deepEqual(order, ["2026-10-05T00:00:00Z", "2026-10-01T00:00:00Z"]);
  assert.deepEqual(stats, { attempted: 2, done: 2, failed: 0, skippedBudget: 0, facts: 0, remaining: 1 });
});

Deno.test("a run stops asking a course whose budget said no", async () => {
  const doc = await fixture("01-cis-hw3-cancelled");
  const store = new MemoryStore();
  const rows = [1, 2, 3].map((n) =>
    metaRow(doc, { id: `announcement:${COURSE}:n${n}`, source_id: `n${n}`, posted_at: `2026-10-0${n}T00:00:00Z`, content_hash: `h${n}` })
  );
  store.rows = rows;
  for (const r of rows) store.texts.set(r.id, doc.text);
  store.budget.set(COURSE, 60);
  const { fetchImpl, calls } = fakeModel(() => answer([]));
  const stats = await runPendingFactExtractionsWith(context(store, fetchImpl), [COURSE], {
    maxDocuments: 10,
    budgetMs: 10_000,
    concurrency: 1,
  });
  assert.equal(calls.length, 0);
  assert.equal(stats.skippedBudget, 1, "one claim was refused; the other two were not even tried");
  assert.equal(stats.remaining, 2);
});

Deno.test("a store failure ends the run quietly instead of throwing", async () => {
  const store = new MemoryStore();
  store.failLists = true;
  const { fetchImpl } = fakeModel(() => answer([]));
  const stats = await runPendingFactExtractionsWith(context(store, fetchImpl), [COURSE], { maxDocuments: 5, budgetMs: 1000 });
  assert.deepEqual(stats, { attempted: 0, done: 0, failed: 0, skippedBudget: 0, facts: 0, remaining: 0 });
});

Deno.test("two overlapping runs never extract the same revision twice", async () => {
  const doc = await fixture("01-cis-hw3-cancelled");
  const store = new MemoryStore();
  const row = metaRow(doc);
  store.rows = [row, ...assignmentRows(doc)];
  store.texts.set(row.id, doc.text);
  const { fetchImpl, calls } = fakeModel(async () => {
    await new Promise((r) => setTimeout(r, 20));
    return answer([cancelFact]);
  });
  const ctx = context(store, fetchImpl);
  const options = { maxDocuments: 5, budgetMs: 5000, concurrency: 1 };
  await Promise.all([
    runPendingFactExtractionsWith(ctx, [COURSE], options),
    runPendingFactExtractionsWith(ctx, [COURSE], options),
  ]);
  assert.equal(calls.length, 1);
  assert.equal(store.facts.length, 1);
});

// ---------------------------------------------------------------------
// scheduleFactExtraction: nothing here may fail the upload that calls it
// ---------------------------------------------------------------------

import { scheduleFactExtraction } from "../supabase/functions/_shared/factsExtraction.ts";

const fakeClient = {} as Parameters<typeof scheduleFactExtraction>[0];

async function withEdgeRuntime(value: unknown, fn: () => void | Promise<void>) {
  const g = globalThis as Record<string, unknown>;
  const had = "EdgeRuntime" in g;
  const prev = g.EdgeRuntime;
  if (value === undefined) delete g.EdgeRuntime;
  else g.EdgeRuntime = value;
  try {
    await fn();
  } finally {
    if (had) g.EdgeRuntime = prev;
    else delete g.EdgeRuntime;
  }
}

Deno.test("scheduleFactExtraction: with no EdgeRuntime it still returns and still starts the work", async () => {
  await withEdgeRuntime(undefined, async () => {
    let ran = 0;
    scheduleFactExtraction(fakeClient, ["100"], () => (ran++, Promise.resolve({})));
    await new Promise((r) => setTimeout(r, 5));
    assert.equal(ran, 1);
  });
});

Deno.test("scheduleFactExtraction: with EdgeRuntime the work is handed to waitUntil", async () => {
  const kept: Promise<unknown>[] = [];
  await withEdgeRuntime({ waitUntil: (p: Promise<unknown>) => kept.push(p) }, async () => {
    scheduleFactExtraction(fakeClient, ["100"], () => Promise.resolve({}));
    assert.equal(kept.length, 1);
    await kept[0];
  });
});

Deno.test("scheduleFactExtraction: a rejected promise or a synchronous throw is swallowed", async () => {
  const kept: Promise<unknown>[] = [];
  const originalError = console.error;
  console.error = () => {};
  try {
    await withEdgeRuntime({ waitUntil: (p: Promise<unknown>) => kept.push(p) }, async () => {
      scheduleFactExtraction(fakeClient, ["100"], () => Promise.reject(new Error("model down")));
      await kept[0]; // the kept promise resolves: the rejection was caught
      scheduleFactExtraction(fakeClient, ["100"], () => {
        throw new Error("boom");
      });
    });
  } finally {
    console.error = originalError;
  }
});

Deno.test("scheduleFactExtraction: LHF_FACTS_DISABLED and an empty course list start nothing", () => {
  let ran = 0;
  const run = () => (ran++, Promise.resolve({}));
  scheduleFactExtraction(fakeClient, [], run);
  assert.equal(ran, 0);
  const prev = Deno.env.get("LHF_FACTS_DISABLED");
  Deno.env.set("LHF_FACTS_DISABLED", "1");
  try {
    scheduleFactExtraction(fakeClient, ["100"], run);
    assert.equal(ran, 0);
  } finally {
    if (prev === undefined) Deno.env.delete("LHF_FACTS_DISABLED");
    else Deno.env.set("LHF_FACTS_DISABLED", prev);
  }
});
