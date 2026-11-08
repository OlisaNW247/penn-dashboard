// Pins what `PostgrestToolBackend` sends to PostgREST and how it maps rows
// back: the real supabase-js client builds the requests, only `fetch` is
// replaced (as in agentStorePostgrest.test.ts).
import { strict as assert } from "node:assert";
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { MemoryAgentStore } from "../supabase/functions/_shared/agentStoreMemory.ts";
import { canvasAssignmentID, excerptAround, PostgrestToolBackend } from "../supabase/functions/_shared/agentToolsPostgrest.ts";

const NOW = new Date("2026-11-10T12:00:00.000Z");
const USER = "u1";

interface Seen {
  method: string;
  table: string;
  q: URLSearchParams;
}

type Tables = Record<string, unknown[]>;

async function withBackend<T>(
  tables: Tables,
  run: (backend: PostgrestToolBackend, seen: Seen[], store: MemoryAgentStore) => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  const seen: Seen[] = [];
  globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
    const request = input instanceof Request ? input : new Request(String(input), init);
    const url = new URL(request.url);
    const table = url.pathname.replace("/rest/v1/", "");
    seen.push({ method: request.method, table, q: url.searchParams });
    return Promise.resolve(
      new Response(JSON.stringify(tables[table] ?? []), { status: 200, headers: { "content-type": "application/json" } }),
    );
  }) as typeof fetch;
  try {
    const client = createClient("http://supabase.test", "service-key", { auth: { persistSession: false, autoRefreshToken: false } });
    const store = new MemoryAgentStore();
    return await run(new PostgrestToolBackend({ client, store, now: () => NOW }), seen, store);
  } finally {
    globalThis.fetch = original;
  }
}

const enrolled = [{ course_id: "2002" }, { course_id: "1001" }];
const courses = [
  { course_id: "1001", code: "PHYS 0151", name: "Mechanics" },
  { course_id: "2002", code: "CIS 2400", name: "Machine Programming" },
];
const doc = (over: Record<string, unknown> = {}) => ({
  id: "announcement:1001:a1",
  course_id: "1001",
  course_code: "PHYS 0151",
  kind: "announcement",
  title: "Exam moved",
  text: "The midterm exam moved to Thursday.",
  url: "https://canvas.upenn.edu/courses/1001/discussion_topics/9",
  posted_at: "2026-11-09T10:00:00Z",
  updated_at: "2026-11-09T11:00:00Z",
  fetched_at: "2026-11-09T12:00:00Z",
  ...over,
});
const only = (seen: Seen[], table: string) => seen.filter((s) => s.table === table);
const AGE_OUT = "kind.not.in.(announcement,ed),updated_at.gte.2026-07-13T12:00:00.000Z,and(updated_at.is.null,fetched_at.gte.2026-07-13T12:00:00.000Z)";

Deno.test("listCourses: the snapshot's courses, else the enrolled ones", async () => {
  await withBackend({ enrollments: enrolled, courses }, async (backend, seen, store) => {
    const fallback = await backend.listCourses(USER);
    assert.deepStrictEqual(fallback.map((c) => c.code).sort(), ["CIS 2400", "PHYS 0151"]);
    assert.deepStrictEqual(fallback.find((c) => c.code === "PHYS 0151"), { code: "PHYS 0151", name: "Mechanics", canvasId: "1001" });
    assert.strictEqual(only(seen, "enrollments")[0].q.get("user_id"), "eq.u1");
    assert.strictEqual(only(seen, "enrollments")[0].q.get("select"), "course_id");
    assert.strictEqual(only(seen, "courses")[0].q.get("course_id"), "in.(1001,2002)");

    await store.upsertSnapshot({
      userId: USER,
      courses: [{ courseID: "3003", code: "MATH 1410", name: "Calc" }],
      workList: [],
      manual: [],
      writtenAt: NOW.toISOString(),
    });
    seen.length = 0;
    assert.deepStrictEqual(await backend.listCourses(USER), [{ code: "MATH 1410", name: "Calc", canvasId: "3003" }]);
    assert.strictEqual(seen.length, 0);
  });
});

Deno.test("listWork: nothing without a snapshot; views over work plus manual with one", async () => {
  await withBackend({}, async (backend, seen, store) => {
    assert.deepStrictEqual(await backend.listWork(USER, "todo", undefined, NOW), []);
    assert.strictEqual(seen.length, 0);
    await store.upsertSnapshot({
      userId: USER,
      courses: [],
      workList: [
        { id: "canvas:1", course: "PHYS 0151", title: "HW4", kind: "assignment", dueAt: "2026-11-11T12:00:00Z", done: false, noSubmission: false, url: null, source: "canvas" },
        { id: "canvas:2", course: "CIS 2400", title: "P1", kind: "assignment", dueAt: "2026-11-11T13:00:00Z", done: false, noSubmission: false, url: null, source: "canvas" },
      ],
      manual: [{ id: "m1", course: "PHYS 0151", title: "Pset review", dueAt: "2026-11-10T20:00:00Z", repeatsWeekly: false }],
      writtenAt: NOW.toISOString(),
    });
    const all = await backend.listWork(USER, "todo", undefined, NOW);
    assert.deepStrictEqual(all.map((i) => i.id), ["m1", "canvas:1", "canvas:2"]);
    assert.deepStrictEqual(all[0], { id: "m1", course: "PHYS 0151", title: "Pset review", kind: "other", dueAt: "2026-11-10T20:00:00Z", done: false, noSubmission: false, url: null, source: "manual" });
    assert.deepStrictEqual((await backend.listWork(USER, "todo", "cis-2400", NOW)).map((i) => i.id), ["canvas:2"]);
    assert.strictEqual(seen.length, 0);
  });
});

Deno.test("searchCourseMaterial: enrolled courses only, full text, live, aged out, paged", async () => {
  const rows = Array.from({ length: 11 }, (_, i) => doc({ id: `d${i}`, text: `${"x".repeat(900)} Midterm ${i}` }));
  await withBackend({ enrollments: enrolled, course_documents: rows }, async (backend, seen) => {
    const page = await backend.searchCourseMaterial(USER, "midterm exam", undefined, "announcement", 2);
    const docs = only(seen, "course_documents")[0];
    assert.strictEqual(docs.method, "GET");
    assert.strictEqual(docs.q.get("text"), "wfts(english).midterm exam");
    assert.strictEqual(docs.q.get("course_id"), "in.(1001,2002)");
    assert.strictEqual(docs.q.get("gone_at"), "is.null");
    assert.strictEqual(docs.q.get("kind"), "eq.announcement");
    assert.strictEqual(docs.q.get("or"), `(${AGE_OUT})`);
    assert.strictEqual(docs.q.get("order"), "updated_at.desc.nullslast");
    assert.strictEqual(docs.q.get("offset"), "10");
    assert.strictEqual(docs.q.get("limit"), "11");
    assert.ok(!(docs.q.get("select") ?? "").includes("collector"));
    assert.strictEqual(page.page, 2);
    assert.strictEqual(page.hasMore, true);
    assert.strictEqual(page.items.length, 10);
    const first = page.items[0];
    assert.strictEqual(first.documentId, "d0");
    assert.strictEqual(first.course, "PHYS 0151");
    assert.strictEqual(first.excerpt.length, 600);
    assert.strictEqual(first.postedAt, "2026-11-09T10:00:00Z");
  });
});

Deno.test("searchCourseMaterial: a course the caller is not enrolled in is never queried", async () => {
  await withBackend({ enrollments: enrolled, courses, course_documents: [doc()] }, async (backend, seen) => {
    await backend.searchCourseMaterial(USER, "exam", "PHYS 0151");
    assert.strictEqual(only(seen, "course_documents")[0].q.get("course_id"), "in.(1001)");
    seen.length = 0;
    // Named by id, but not enrolled: nothing is queried at all.
    const none = await backend.searchCourseMaterial(USER, "exam", "9999");
    assert.deepStrictEqual(none, { items: [], page: 1, hasMore: false });
    assert.strictEqual(only(seen, "course_documents").length, 0);
    // Unknown code, same.
    assert.deepStrictEqual((await backend.searchCourseMaterial(USER, "exam", "MATH 1410")).items, []);
    assert.strictEqual(only(seen, "course_documents").length, 0);
  });
  await withBackend({ enrollments: [], course_documents: [doc()] }, async (backend, seen) => {
    assert.deepStrictEqual((await backend.searchCourseMaterial(USER, "exam")).items, []);
    assert.strictEqual(only(seen, "course_documents").length, 0);
  });
});

Deno.test("excerptAround: 600 characters around the first hit, case-insensitive", () => {
  const text = "a".repeat(1000) + "NEEDLE" + "b".repeat(1000);
  const ex = excerptAround(text, "needle");
  assert.strictEqual(ex.length, 600);
  assert.ok(ex.includes("NEEDLE"));
  assert.strictEqual(excerptAround(text, "absent"), text.slice(0, 600));
  assert.strictEqual(excerptAround("short", "hort"), "short");
});

Deno.test("getAnnouncements: live, aged out, within days, newest first, 10 per page", async () => {
  const rows = Array.from({ length: 11 }, (_, i) => doc({ id: `a${i}`, text: "y".repeat(9000) }));
  await withBackend({ enrollments: enrolled, course_documents: rows }, async (backend, seen) => {
    const page = await backend.getAnnouncements(USER, undefined, 7, 1);
    const q = only(seen, "course_documents")[0].q;
    assert.strictEqual(q.get("kind"), "eq.announcement");
    assert.strictEqual(q.get("course_id"), "in.(1001,2002)");
    assert.strictEqual(q.get("gone_at"), "is.null");
    assert.deepStrictEqual(q.getAll("or"), [
      `(${AGE_OUT})`,
      "(posted_at.gte.2026-11-03T12:00:00.000Z,and(posted_at.is.null,updated_at.gte.2026-11-03T12:00:00.000Z),and(posted_at.is.null,updated_at.is.null,fetched_at.gte.2026-11-03T12:00:00.000Z))",
    ]);
    assert.strictEqual(q.get("order"), "posted_at.desc.nullslast,updated_at.desc.nullslast");
    assert.strictEqual(q.get("offset"), "0");
    assert.strictEqual(q.get("limit"), "11");
    assert.strictEqual(page.items.length, 10);
    assert.strictEqual(page.hasMore, true);
    assert.strictEqual(page.items[0].text.length, 8000);
    assert.deepStrictEqual(
      { ...page.items[0], text: "" },
      { documentId: "a0", course: "PHYS 0151", kind: "announcement", title: "Exam moved", text: "", postedAt: "2026-11-09T10:00:00Z", url: "https://canvas.upenn.edu/courses/1001/discussion_topics/9" },
    );
  });
});

Deno.test("getEdPosts: kind ed, no days window, one course by code", async () => {
  await withBackend({ enrollments: enrolled, courses, course_documents: [doc({ kind: "ed", posted_at: null })] }, async (backend, seen) => {
    const page = await backend.getEdPosts(USER, "cis 2400");
    const q = only(seen, "course_documents")[0].q;
    assert.strictEqual(q.get("kind"), "eq.ed");
    assert.strictEqual(q.get("course_id"), "in.(2002)");
    assert.deepStrictEqual(q.getAll("or"), [`(${AGE_OUT})`]);
    assert.strictEqual(page.hasMore, false);
    assert.strictEqual(page.items[0].postedAt, "2026-11-09T11:00:00Z"); // falls back to updated_at
  });
});

const fact = (seq: number, over: Record<string, unknown> = {}) => ({
  seq,
  course_id: "1001",
  document_id: "announcement:1001:a1",
  content_hash: "h1",
  fact_type: "reschedule",
  target_source_id: "555",
  title: "Exam moved to Thursday",
  due_at: null,
  kind: null,
  quote: "The midterm exam moved to Thursday.",
  confidence: "high",
  posted_at: "2026-11-09T10:00:00Z",
  created_at: "2026-11-09T10:05:00Z",
  course_documents: { content_hash: "h1", gone_at: null },
  ...over,
});

Deno.test("getFacts: enrolled courses, seq order, limit 200, since on posted_at, stale documents dropped", async () => {
  const rows = [
    fact(1),
    fact(2, { title: null, fact_type: "note", target_source_id: null, posted_at: null }),
    fact(3, { course_documents: { content_hash: "other", gone_at: null } }),
    fact(4, { course_documents: { content_hash: "h1", gone_at: "2026-11-09T00:00:00Z" } }),
  ];
  await withBackend({ enrollments: enrolled, courses, course_facts: rows }, async (backend, seen) => {
    const facts = await backend.getFacts(USER, undefined, 1_700_000_000);
    const q = only(seen, "course_facts")[0].q;
    assert.strictEqual(q.get("course_id"), "in.(1001,2002)");
    assert.strictEqual(q.get("order"), "seq.asc");
    assert.strictEqual(q.get("limit"), "200");
    assert.strictEqual(q.get("or"), "(posted_at.is.null,posted_at.gte.2023-11-14T22:13:20.000Z)");
    assert.deepStrictEqual(facts, [
      { id: "fact-1", course: "PHYS 0151", kind: "reschedule", text: "reschedule: Exam moved to Thursday", assignmentId: "555", createdAt: Math.floor(Date.parse("2026-11-09T10:00:00Z") / 1000) },
      { id: "fact-2", course: "PHYS 0151", kind: "note", text: "note: The midterm exam moved to Thursday.", assignmentId: null, createdAt: Math.floor(Date.parse("2026-11-09T10:05:00Z") / 1000) },
    ]);
    seen.length = 0;
    await backend.getFacts(USER);
    assert.strictEqual(only(seen, "course_facts")[0].q.get("or"), null);
  });
  await withBackend({ enrollments: enrolled, courses, course_facts: rows }, async (backend, seen) => {
    await backend.getFacts(USER, "PHYS 0151");
    assert.strictEqual(only(seen, "course_facts")[0].q.get("course_id"), "in.(1001)");
  });
});

Deno.test("getAssignment: snapshot item, pooled description and facts by Canvas id", async () => {
  const tables = {
    enrollments: enrolled,
    courses,
    course_documents: [{ text: "D".repeat(25_000) }],
    course_facts: [fact(7)],
  };
  await withBackend(tables, async (backend, seen, store) => {
    assert.strictEqual(await backend.getAssignment(USER, "canvas:555"), null);
    await store.upsertSnapshot({
      userId: USER,
      courses: [],
      workList: [
        { id: "canvas:555", course: "PHYS 0151", title: "HW4", kind: "assignment", dueAt: null, done: false, noSubmission: false, url: "https://canvas.upenn.edu/courses/1001/assignments/555", source: "canvas" },
        { id: "syllabus:x", course: "PHYS 0151", title: "Reading", kind: "other", dueAt: null, done: false, noSubmission: true, url: null, source: "syllabus" },
      ],
      manual: [],
      writtenAt: NOW.toISOString(),
    });
    const found = await backend.getAssignment(USER, "canvas:555");
    assert.ok(found);
    assert.strictEqual(found.entry.title, "HW4");
    assert.strictEqual(found.description.length, 20_000);
    assert.strictEqual(found.facts.length, 1);
    assert.strictEqual(found.facts[0].text, "reschedule: Exam moved to Thursday");
    const d = only(seen, "course_documents")[0].q;
    assert.strictEqual(d.get("course_id"), "in.(1001)");
    assert.strictEqual(d.get("kind"), "eq.assignment");
    assert.strictEqual(d.get("source_id"), "eq.555");
    assert.strictEqual(d.get("gone_at"), "is.null");
    const f = only(seen, "course_facts")[0].q;
    assert.strictEqual(f.get("course_id"), "in.(1001)");
    assert.strictEqual(f.get("target_source_id"), "eq.555");

    seen.length = 0;
    const plain = await backend.getAssignment(USER, "syllabus:x");
    assert.deepStrictEqual(plain?.facts, []);
    assert.strictEqual(plain?.description, "");
    assert.strictEqual(only(seen, "course_documents").length, 0);
    assert.strictEqual(await backend.getAssignment(USER, "nope"), null);
  });
});

Deno.test("canvasAssignmentID: link first, then canvas: prefix, leniently", () => {
  assert.strictEqual(canvasAssignmentID({ id: "x", url: "https://c/courses/1/assignments/42?x=1" }), "42");
  assert.strictEqual(canvasAssignmentID({ id: "canvas:77", url: null }), "77");
  assert.strictEqual(canvasAssignmentID({ id: "canvas-ics:88", url: null }), "88");
  assert.strictEqual(canvasAssignmentID({ id: "manual-abc", url: null }), null);
});

Deno.test("proposeSubmission and draftStatus reject until Phase 3", async () => {
  await withBackend({}, async (backend) => {
    await assert.rejects(backend.proposeSubmission(USER, "c", "n", { assignmentId: "a", kind: "text", body: "b" }), /Phase 3/);
    await assert.rejects(backend.draftStatus(USER, "d"), /Phase 3/);
  });
});
