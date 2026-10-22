import { test } from "node:test";
import assert from "node:assert/strict";
import { buildState, dueLabel, toStored, fromStored, isCanvasRelevant, completionOf } from "../src/core/workList.js";
import { makeAssignment, assignmentID } from "../src/core/assignment.js";
import { visibleItems } from "../src/popup/popup.js";

// Tuesday 2026-10-20 12:00 in America/New_York (npm test sets TZ).
const NOW = new Date(2026, 9, 20, 12, 0, 0);
const at = (days, hours = 0) => new Date(NOW.getTime() + days * 86_400_000 + hours * 3_600_000);

function a(sourceID, dueAt, extra = {}) {
  return toStored(makeAssignment({
    source: "canvas", sourceID, kind: "assignment", course: "CIS 1200", title: `t ${sourceID}`, dueAt, ...extra,
  }));
}

const ids = (state, view) => visibleItems({ ...state, view }).map((i) => i.id);

test("TZ is the one the fixtures assume", () => {
  assert.equal(new Date(2026, 9, 20, 12).toString().includes("Eastern"), true);
});

// RedesignTokens.swift dueText / smoothDueValue
test("dueLabel: phone phrasing", () => {
  assert.equal(dueLabel(at(0, 5), NOW), "5h left");
  assert.equal(dueLabel(new Date(NOW.getTime() + 8 * 60_000), NOW), "8m left");
  assert.equal(dueLabel(new Date(NOW.getTime() + 20_000), NOW), "1m left");
  assert.equal(dueLabel(at(0, -3), NOW), "3h late");
  assert.equal(dueLabel(new Date(NOW.getTime() - 5 * 60_000), NOW), "5m late");
  assert.equal(dueLabel(at(-2), NOW), "2 days late");
  assert.equal(dueLabel(at(-1, -1), NOW), "1 day late");
  assert.equal(dueLabel(new Date(2026, 9, 22, 9), NOW), "in 2 days");
  assert.equal(dueLabel(new Date(2026, 9, 21, 20), NOW), "in 1 day");
  assert.equal(dueLabel(new Date(2026, 9, 23, 12), NOW), "Fri");
  assert.equal(dueLabel(new Date(2026, 10, 14, 12), NOW), "Nov 14");
  assert.equal(dueLabel(null, NOW), "no date");
});

test("dueLabel: calendar days across the DST change (Nov 1 2026)", () => {
  const now = new Date(2026, 9, 31, 23, 0, 0);
  assert.equal(dueLabel(new Date(2026, 10, 2, 9), now), "in 2 days");
});

// DashboardViewModel.todoSections / allSections
test("views: todo is overdue + next two days; all is future only; undated only in all", () => {
  const stored = [
    a("over", at(-3)),
    a("today", at(0, 5)),
    a("d2", at(2)),
    a("d3", at(3)),
    a("d30", at(30)),
    a("none", null),
  ];
  const s = buildState({ stored, now: NOW });
  const id = (x) => `canvas:${x}`;
  assert.deepEqual(ids(s, "todo"), ["over", "today", "d2"].map(id));
  assert.deepEqual(ids(s, "all"), ["today", "d2", "d3", "d30", "none"].map(id));
  assert.deepEqual(ids(s, "prev"), []);
});

test("items are sorted by due date with the id as tie-break", () => {
  const stored = [a("b", at(1)), a("a", at(1)), a("c", at(0, 2))];
  const s = buildState({ stored, now: NOW });
  assert.deepEqual(s.items.map((i) => i.id), ["canvas:c", "canvas:a", "canvas:b"]);
});

test("state shape the popup renders", () => {
  const s = buildState({ stored: [a("x", at(0, 5))], now: NOW, canvas: "in", gradescope: "out" });
  assert.equal(s.weekday, "tuesday");
  assert.equal(s.view, "todo");
  assert.equal(s.canvas, "in");
  assert.equal(s.gradescope, "out");
  assert.equal(s.paired, false);
  assert.deepEqual(s.items, [{ id: "canvas:x", course: "CIS 1200", title: "t x", due: "5h left", bucket: "todo", done: false }]);
});

test("course label is the parsed code", () => {
  const stored = [a("x", at(1), { course: "CIS 1200 001 202630 Programming" })];
  assert.equal(buildState({ stored, now: NOW }).items[0].course, "CIS 1200");
});

// completions
test("a done completion moves the item to prev; un-tick brings it back", () => {
  const stored = [a("x", at(1))];
  const done = { "canvas:x": { done: true, at: at(0, -1).toISOString() } };
  let s = buildState({ stored, completions: done, now: NOW });
  assert.deepEqual(ids(s, "todo"), []);
  assert.deepEqual(ids(s, "prev"), ["canvas:x"]);
  assert.equal(s.items[0].done, true);
  const undone = { "canvas:x": { done: false, at: at(0, 1).toISOString() } };
  s = buildState({ stored, completions: undone, now: NOW });
  assert.deepEqual(ids(s, "todo"), ["canvas:x"]);
});

test("a completion on the linked Gradescope id counts; submitted counts; explicit false beats submitted", () => {
  const linked = a("c", at(1), { linkedID: "gradescope:9" });
  let s = buildState({ stored: [linked], completions: { "gradescope:9": { done: true, at: at(0).toISOString() } }, now: NOW });
  assert.equal(s.items[0].bucket, "prev");
  const sub = a("s", at(1), { submitted: true });
  s = buildState({ stored: [sub], now: NOW });
  assert.equal(s.items[0].bucket, "prev");
  s = buildState({ stored: [sub], completions: { "canvas:s": { done: false, at: at(0).toISOString() } }, now: NOW });
  assert.equal(s.items[0].bucket, "todo");
});

// doneSections: this week first (newest first), then this term, day labels
test("prev: this week first with weekday labels, then earlier this term with dates; older terms drop", () => {
  const stored = [
    a("wk", at(3)),          // due Fri this week, completed Mon
    a("wk2", at(-1)),        // completed Tue
    a("early", at(-20)),     // completed Sep 30
    a("old", at(-100)),      // before the fall term start (Aug 1)... completed Jul 12
  ];
  const c = (d) => ({ done: true, at: d.toISOString() });
  const completions = {
    "canvas:wk": c(new Date(2026, 9, 19, 9)),
    "canvas:wk2": c(new Date(2026, 9, 20, 8)),
    "canvas:early": c(new Date(2026, 8, 30, 9)),
    "canvas:old": c(new Date(2026, 6, 12, 9)),
  };
  const s = buildState({ stored, completions, now: NOW });
  const prev = s.items.filter((i) => i.bucket === "prev");
  assert.deepEqual(prev.map((i) => [i.id, i.due]), [
    ["canvas:wk2", "Tue"], ["canvas:wk", "Mon"], ["canvas:early", "Sep 30"],
  ]);
});

test("a done item without a completion time is placed by its due date", () => {
  const s = buildState({ stored: [a("sub", at(-1), { submitted: true })], now: NOW });
  assert.deepEqual(s.items.map((i) => [i.bucket, i.due]), [["prev", "Mon"]]);
});

// AppState.isTooOld / withinTermCap
test("hidden: due over 5 months ago; a future term; beyond the term end", () => {
  const stored = [
    a("ancient", new Date(2026, 4, 1)),
    a("futureTerm", at(40), { term: { year: 2027, season: 10, code: "202710" } }),
    a("pastTerm", at(-30), { term: { year: 2026, season: 10, code: "202610" } }),
    a("afterEnd", new Date(2027, 1, 1)),
    a("inTerm", new Date(2026, 11, 15)),
  ];
  const s = buildState({ stored, now: NOW });
  assert.deepEqual(ids(s, "all"), ["canvas:inTerm"]);
  assert.deepEqual(ids(s, "todo"), ["canvas:pastTerm"]); // a past term still passes, as on the phone
});

// the Canvas relevance gate
test("isCanvasRelevant: assignments and assessments, not events or plain discussions", () => {
  const k = (kind, title = "x", course = "CIS 1200") => makeAssignment({ source: "canvas", sourceID: "1", kind, course, title });
  assert.equal(isCanvasRelevant(k("assignment")), true);
  assert.equal(isCanvasRelevant(k("quiz")), true);
  assert.equal(isCanvasRelevant(k("discussion", "Midterm review")), true);
  assert.equal(isCanvasRelevant(k("discussion")), false);
  assert.equal(isCanvasRelevant(k("event", "Lecture 3")), false);
  assert.equal(isCanvasRelevant(k("event", "No exams today", "(unknown course)")), false);
});

test("storage form round-trips and is JSON-safe", () => {
  const orig = makeAssignment({ source: "canvas", sourceID: "9", kind: "assignment", course: "C", title: "T", dueAt: at(1), url: "https://x", term: { year: 2026, season: 30, code: "202630" }, linkedID: "gradescope:1" });
  const json = JSON.parse(JSON.stringify(toStored(orig)));
  const back = fromStored(json);
  assert.equal(back.dueAt.getTime(), orig.dueAt.getTime());
  assert.equal(assignmentID(back), "canvas:9");
  assert.equal(back.linkedID, "gradescope:1");
  assert.deepEqual(back.term, orig.term);
});

test("completionOf: later records are not merged here; own id beats linked id", () => {
  const x = fromStored(JSON.parse(JSON.stringify(a("x", at(1), { linkedID: "gradescope:1" }))));
  const r = completionOf(x, { "canvas:x": { done: false, at: "2026-10-20T00:00:00.000Z" }, "gradescope:1": { done: true, at: "2026-10-20T00:00:00.000Z" } });
  assert.equal(r.done, false);
});
