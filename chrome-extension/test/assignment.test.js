import { test } from "node:test";
import assert from "node:assert/strict";
import {
  makeAssignment, assignmentID, canvasAssignmentID, isOrderedByDueDate, Source, Kind,
} from "../src/core/assignment.js";

// CanvasAssignmentIDPinTests.swift:23-35 (the `canvas` helper)
function canvas({ sourceID, url = null, source = Source.CANVAS }) {
  return makeAssignment({
    source, sourceID, kind: Kind.ASSIGNMENT, course: "PIN 0001", title: "Pinned", dueAt: null, url,
  });
}

// CanvasAssignmentIDPinTests.swift:37-41
test("a sub-assignment UID with no URL resolves to the digits after 'assignment-', which is 7", () => {
  assert.equal(canvasAssignmentID(canvas({ sourceID: "event-sub_assignment-7@canvas.upenn.edu" })), "7");
});

// CanvasAssignmentIDPinTests.swift:43-52
test("a sub-assignment UID under a #sub_assignment_ fragment still resolves to 7, through the UID", () => {
  const a = canvas({
    sourceID: "event-sub_assignment-7@canvas.upenn.edu",
    url: "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#sub_assignment_7",
  });
  assert.equal(canvasAssignmentID(a), "7");
});

// CanvasAssignmentIDPinTests.swift:54-58
test("the UID fallback is never run for a module-imported row", () => {
  const a = canvas({ sourceID: "event-sub_assignment-7@canvas.upenn.edu", source: Source.CANVAS_MODULES });
  assert.equal(canvasAssignmentID(a), null);
});

// CanvasAssignmentIDPinTests.swift:60-64
test("a section-override UID does not match the UID fallback", () => {
  assert.equal(canvasAssignmentID(canvas({ sourceID: "event-assignment-override-99@canvas.upenn.edu" })), null);
});

// CanvasAssignmentIDPinTests.swift:66-80
test("the three expressions are still tried in order: path, then fragment, then UID", () => {
  const all = canvas({
    sourceID: "event-assignment-3@canvas.upenn.edu",
    url: "https://canvas.upenn.edu/courses/1/assignments/1#assignment_2",
  });
  assert.equal(canvasAssignmentID(all), "1");
  const fragmentAndUID = canvas({
    sourceID: "event-assignment-3@canvas.upenn.edu",
    url: "https://canvas.upenn.edu/calendar?include_contexts=course_1#assignment_2",
  });
  assert.equal(canvasAssignmentID(fragmentAndUID), "2");
  assert.equal(canvasAssignmentID(canvas({ sourceID: "event-assignment-3@canvas.upenn.edu" })), "3");
});

// No Swift test; Assignment.swift:168-209 (module rows trust the URL, other sources get nil).
test("canvasAssignmentID: modules rows use the URL, other sources are nil, fragment needs the # anchor", () => {
  const mod = canvas({
    sourceID: "module-item-5", source: Source.CANVAS_MODULES,
    url: "https://canvas.upenn.edu/courses/1/assignments/88",
  });
  assert.equal(canvasAssignmentID(mod), "88");
  assert.equal(canvasAssignmentID(canvas({ sourceID: "assignment-5", source: Source.GRADESCOPE })), null);
  const quizFragment = canvas({ sourceID: "x", url: "https://canvas.upenn.edu/calendar#quiz_5" });
  assert.equal(canvasAssignmentID(quizFragment), null);
});

// No Swift test; Assignment.swift:52-53 and the memberwise defaults at :211-236.
test("makeAssignment defaults and id", () => {
  const a = makeAssignment({ source: Source.CANVAS, sourceID: "u1", kind: Kind.QUIZ, course: "CIS 1200", title: "Q" });
  assert.equal(assignmentID(a), "canvas:u1");
  assert.deepEqual(
    [a.dueAt, a.url, a.term, a.submitted, a.scoreEarned, a.scoreMax, a.linkedID],
    [null, null, null, false, null, null, null],
  );
  assert.equal(Source.CANVAS_MODULES, "canvasModules");
});

// No Swift test; Assignment.swift:61-72.
test("isOrderedByDueDate: earlier first, undated last, id breaks ties", () => {
  const mk = (id, dueAt) => makeAssignment({ source: Source.CANVAS, sourceID: id, kind: Kind.ASSIGNMENT, course: "C", title: "t", dueAt });
  const d1 = new Date("2026-05-01T00:00:00Z");
  const d2 = new Date("2026-05-02T00:00:00Z");
  assert.equal(isOrderedByDueDate(mk("b", d1), mk("a", d2)), true);
  assert.equal(isOrderedByDueDate(mk("a", d2), mk("b", d1)), false);
  assert.equal(isOrderedByDueDate(mk("a", null), mk("b", d1)), false);
  assert.equal(isOrderedByDueDate(mk("a", d1), mk("b", null)), true);
  assert.equal(isOrderedByDueDate(mk("a", d1), mk("b", new Date(d1))), true); // equal dates: id order
  assert.equal(isOrderedByDueDate(mk("b", null), mk("a", null)), false);
  assert.equal(isOrderedByDueDate(mk("a", null), mk("b", null)), true);
  assert.equal(isOrderedByDueDate(mk("a", null), mk("a", null)), false);
  const sorted = [mk("c", null), mk("b", d2), mk("a", d1)].sort((x, y) => (isOrderedByDueDate(x, y) ? -1 : isOrderedByDueDate(y, x) ? 1 : 0));
  assert.deepEqual(sorted.map((a) => a.sourceID), ["a", "b", "c"]);
});
