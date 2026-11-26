import { strict as assert } from "node:assert";
import {
  acceptableCanvasURL,
  sameCourse,
  validateSnapshot,
  type WorkItem,
  workView,
} from "../supabase/functions/_shared/agentSnapshot.ts";

const item = (over: Record<string, unknown> = {}) => ({
  id: "canvas:1",
  course: "PHYS 0151",
  title: "Homework 4",
  kind: "assignment",
  dueAt: "2026-11-10T17:00:00Z",
  done: false,
  noSubmission: false,
  url: "https://canvas.upenn.edu/courses/1001/assignments/1",
  source: "canvas",
  ...over,
});
const good = (over: Record<string, unknown> = {}) => ({
  courses: [{ courseID: "1001", code: "PHYS 0151", name: "Mechanics" }],
  workList: [item()],
  manual: [{ id: "m1", course: "PHYS 0151", title: "Read", dueAt: null, repeatsWeekly: false }],
  ...over,
});
const reason = (body: unknown) => {
  const r = validateSnapshot(body);
  assert.ok(!r.ok);
  return r.ok ? "" : r.reason;
};

Deno.test("validateSnapshot: a good body round-trips", () => {
  const r = validateSnapshot(good());
  assert.ok(r.ok);
  if (r.ok) {
    assert.deepStrictEqual(r.snapshot.courses, [{ courseID: "1001", code: "PHYS 0151", name: "Mechanics" }]);
    assert.strictEqual(r.snapshot.workList.length, 1);
    assert.strictEqual(r.snapshot.manual.length, 1);
  }
});

Deno.test("validateSnapshot: manual is optional, workList and courses are not", () => {
  const { manual: _m, ...rest } = good();
  assert.ok(validateSnapshot(rest).ok);
  assert.match(reason({ ...good(), workList: undefined }), /workList/);
  assert.match(reason({ ...good(), courses: "x" }), /courses/);
  assert.match(reason(null), /object/);
});

Deno.test("validateSnapshot: caps", () => {
  const many = (n: number, make: (i: number) => unknown) => Array.from({ length: n }, (_, i) => make(i));
  const course = (i: number) => ({ courseID: String(i), code: "C", name: "N" });
  assert.ok(validateSnapshot(good({ courses: many(60, course) })).ok);
  assert.match(reason(good({ courses: many(61, course) })), /courses/);
  assert.ok(validateSnapshot(good({ workList: many(2000, (i) => item({ id: `w${i}` })) })).ok);
  assert.match(reason(good({ workList: many(2001, (i) => item({ id: `w${i}` })) })), /workList/);
  const m = (i: number) => ({ id: `m${i}`, course: "X", title: "t", dueAt: null, repeatsWeekly: false });
  assert.ok(validateSnapshot(good({ manual: many(500, m) })).ok);
  assert.match(reason(good({ manual: many(501, m) })), /manual/);
  // string caps
  assert.match(reason(good({ workList: [item({ id: "x".repeat(201) })] })), /id/);
  assert.match(reason(good({ workList: [item({ course: "x".repeat(41) })] })), /course/);
  assert.match(reason(good({ workList: [item({ title: "x".repeat(301) })] })), /title/);
  assert.match(reason(good({ workList: [item({ source: "x".repeat(41) })] })), /source/);
  assert.match(reason(good({ courses: [{ courseID: "1", code: "x".repeat(41), name: "n" }] })), /code/);
  assert.match(reason(good({ courses: [{ courseID: "1", code: "c", name: "x".repeat(201) }] })), /name/);
  assert.match(reason(good({ courses: [{ courseID: "abc", code: "c", name: "n" }] })), /digits/);
});

Deno.test("validateSnapshot: field types", () => {
  assert.match(reason(good({ workList: [item({ kind: "reading" })] })), /kind/);
  assert.match(reason(good({ workList: [item({ done: "no" })] })), /done/);
  assert.match(reason(good({ workList: [item({ dueAt: "tomorrow" })] })), /dueAt/);
  assert.ok(validateSnapshot(good({ workList: [item({ dueAt: null, url: null })] })).ok);
  assert.match(reason(good({ manual: [{ id: "m", course: "", title: "t", dueAt: null, repeatsWeekly: 1 }] })), /repeatsWeekly/);
});

Deno.test("validateSnapshot: grade and name fields refuse the whole snapshot", () => {
  for (const key of ["score", "grade", "points", "name", "firstName", "email", "Email"]) {
    assert.strictEqual(reason(good({ workList: [item({ [key]: "x" })] })), "forbidden_field", key);
    assert.strictEqual(reason(good({ manual: [{ id: "m", course: "", title: "t", dueAt: null, repeatsWeekly: false, [key]: 1 }] })), "forbidden_field", key);
  }
  // A course has a name by design, but not a grade.
  assert.strictEqual(reason(good({ courses: [{ courseID: "1", code: "c", name: "n", grade: "A" }] })), "forbidden_field");
});

Deno.test("validateSnapshot: unknown keys are dropped", () => {
  const r = validateSnapshot(good({ extra: 1, workList: [item({ colour: "red", nested: { a: 1 } })] }));
  assert.ok(r.ok);
  if (r.ok) {
    assert.deepStrictEqual(Object.keys(r.snapshot.workList[0]).sort(), ["course", "done", "dueAt", "id", "kind", "noSubmission", "source", "title", "url"]);
    assert.deepStrictEqual(Object.keys(r.snapshot), ["courses", "workList", "manual"]);
  }
});

Deno.test("urls: Canvas links pass, feeds and credentials do not", () => {
  assert.ok(acceptableCanvasURL("https://upenn.instructure.com/courses/1/assignments/2"));
  assert.ok(acceptableCanvasURL("https://canvas.upenn.edu/anything"));
  assert.ok(acceptableCanvasURL("https://lms.example.edu/courses/5"));
  assert.ok(!acceptableCanvasURL("http://upenn.instructure.com/courses/1"));
  assert.ok(!acceptableCanvasURL("https://example.com/other"));
  assert.ok(!acceptableCanvasURL("https://upenn.instructure.com/feeds/calendars/user_AbCdEf123456.ics"));
  assert.ok(!acceptableCanvasURL("https://canvas.upenn.edu/courses/1?x=user_abcdef123456"));
  assert.ok(!acceptableCanvasURL("https://me:pw@canvas.upenn.edu/courses/1"));
  assert.ok(!acceptableCanvasURL("not a url"));
  assert.match(reason(good({ workList: [item({ url: "https://x.instructure.com/feeds/calendars/user_ABCDEFGH1234.ics" })] })), /url/);
});

// ---------------------------------------------------------------------------
// workView, now = 2026-11-10T12:00:00Z.

const NOW = new Date("2026-11-10T12:00:00Z");
const hours = (h: number) => new Date(NOW.getTime() + h * 3_600_000).toISOString();
const w = (id: string, dueAt: string | null, over: Partial<WorkItem> = {}): WorkItem => ({
  id,
  course: "PHYS 0151",
  title: id,
  kind: "assignment",
  dueAt,
  done: false,
  noSubmission: false,
  url: null,
  source: "canvas",
  ...over,
});
const ids = (xs: WorkItem[]) => xs.map((x) => x.id);

Deno.test("workView todo: overdue then next 48 hours, boundary inclusive", () => {
  const items = [
    w("later", hours(72)),
    w("edge", hours(48)),
    w("over48", hours(48.01)),
    w("soon", hours(5)),
    w("now", hours(0)),
    w("late1", hours(-1)),
    w("late30", hours(-24 * 30)),
    w("undated", null),
    w("done-soon", hours(5), { done: true }),
  ];
  assert.deepStrictEqual(ids(workView(items, "todo", NOW)), ["late30", "late1", "now", "soon", "edge"]);
});

Deno.test("workView all: future and undated, undated last, soonest first", () => {
  const items = [
    w("undated", null),
    w("far", hours(24 * 20)),
    w("late", hours(-1)),
    w("now", hours(0)),
    w("soon", hours(2)),
    w("done", hours(2), { done: true }),
  ];
  assert.deepStrictEqual(ids(workView(items, "all", NOW)), ["now", "soon", "far", "undated"]);
});

Deno.test("workView prev: done, newest first, last 150 days, undated kept last", () => {
  const items = [
    w("old", hours(-24 * 151), { done: true }),
    w("edge", hours(-24 * 150), { done: true }),
    w("recent", hours(-24), { done: true }),
    w("mid", hours(-24 * 40), { done: true }),
    w("undated", null, { done: true }),
    w("open", hours(-24)),
  ];
  assert.deepStrictEqual(ids(workView(items, "prev", NOW)), ["recent", "mid", "edge", "undated"]);
});

Deno.test("workView: course filter ignores case, spaces and dashes", () => {
  const items = [w("a", hours(1)), w("b", hours(1), { course: "CIS 2400" })];
  assert.deepStrictEqual(ids(workView(items, "todo", NOW, "phys-0151")), ["a"]);
  assert.deepStrictEqual(ids(workView(items, "todo", NOW, "cis2400")), ["b"]);
  assert.deepStrictEqual(ids(workView(items, "todo", NOW, "MATH 1")), []);
  assert.ok(sameCourse("phys 0151", "PHYS-0151"));
});

Deno.test("validateSnapshot: canvasAssignmentID and canvasCourseID are optional digit strings", () => {
  const r = validateSnapshot(good({ workList: [item({ canvasAssignmentID: "15044550", canvasCourseID: "1949400" }), item({ canvasAssignmentID: null }), item()] }));
  assert.ok(r.ok);
  if (r.ok) {
    assert.strictEqual(r.snapshot.workList[0].canvasAssignmentID, "15044550");
    assert.strictEqual(r.snapshot.workList[0].canvasCourseID, "1949400");
    assert.ok(!("canvasAssignmentID" in r.snapshot.workList[1]));
    assert.ok(!("canvasCourseID" in r.snapshot.workList[2]));
  }
  for (const bad of ["", "12a", "1".repeat(21), 5, "-1"]) {
    assert.match(reason(good({ workList: [item({ canvasAssignmentID: bad })] })), /workList\[0\]\.canvasAssignmentID/);
    assert.match(reason(good({ workList: [item({ canvasCourseID: bad })] })), /workList\[0\]\.canvasCourseID/);
  }
  assert.ok(validateSnapshot(good({ workList: [item({ canvasAssignmentID: "1".repeat(20) })] })).ok);
});
