import { test } from "node:test";
import assert from "node:assert/strict";
import { makeAssignment, Source, Kind } from "../src/core/assignment.js";
import {
  normalize, similarTitleDueDateTolerance, isLikelyDuplicate, isLikelyAnnouncementDuplicate,
  matchPairs, merge, mergedAssignment, collapseCanvasDuplicates, collapseCanvasOverrides,
} from "../src/core/dedup.js";

// AssignmentDeduplicatorTests.swift:12-34 (helpers)
const NOW = new Date(1_700_000_000 * 1000);
const plus = (d, seconds) => new Date(d.getTime() + seconds * 1000);
const DAY = 86_400;

function canvas({ id = "c1", course = "CIS 1200", title, due = NOW, submitted = false }) {
  return makeAssignment({ source: Source.CANVAS, sourceID: id, kind: Kind.ASSIGNMENT, course, title, dueAt: due, url: null, submitted });
}
function gradescope({ id = "g1", course = "CIS 1200", title, due = NOW, submitted = false }) {
  return makeAssignment({ source: Source.GRADESCOPE, sourceID: id, kind: Kind.ASSIGNMENT, course, title, dueAt: due, url: null, submitted });
}
// :512-535
function moduleRow({ id = "m1", course = "CIS 1200", title, due = NOW, url = null }) {
  return makeAssignment({ source: Source.CANVAS_MODULES, sourceID: id, kind: Kind.ASSIGNMENT, course, title, dueAt: due, url });
}
function canvasWithURL({ id = "c1", course = "CIS 1200", title, due = NOW, assignmentID }) {
  return makeAssignment({
    source: Source.CANVAS, sourceID: id, kind: Kind.ASSIGNMENT, course, title, dueAt: due,
    url: `https://canvas.upenn.edu/courses/1/assignments/${assignmentID}`,
  });
}
const sorted = (xs) => xs.slice().sort((a, b) => JSON.stringify(a) < JSON.stringify(b) ? -1 : 1);

// ---- isLikelyDuplicate -------------------------------------------------------

// AssignmentDeduplicatorTests.swift:38
test("HW 3 vs Homework 3 matches by exact normalized title", () => {
  assert.ok(isLikelyDuplicate("HW 3", NOW, "Homework 3", NOW));
});

// :46
test("HW 3 vs Homework 3 still matches with no due dates at all", () => {
  assert.ok(isLikelyDuplicate("HW 3", null, "Homework 3", null));
});

// :54
test("PS1 vs Problem Set 1 (autograded) matches with due dates within 26h", () => {
  assert.ok(isLikelyDuplicate("PS1", NOW, "Problem Set 1 (autograded)", plus(NOW, 3600)));
});

// :62
test("Lab 2 vs labs, 02! matches", () => {
  assert.ok(isLikelyDuplicate("Lab 2", NOW, "labs, 02!", NOW));
});

// :70
test("Project 1 vs Proj. 1 matches", () => {
  assert.ok(isLikelyDuplicate("Project 1", NOW, "Proj. 1", NOW));
});

// :80
test("HW 3 vs HW 4 never match", () => {
  assert.ok(!isLikelyDuplicate("HW 3", NOW, "HW 4", NOW));
});

// :88
test("Midterm vs Final never match", () => {
  assert.ok(!isLikelyDuplicate("Midterm", NOW, "Final", NOW));
});

// :96
test("similar-but-not-identical title with no due date on either side does not match", () => {
  assert.ok(!isLikelyDuplicate("Midterm Review", null, "Midterm", null));
});

// :106
test("similar-but-not-identical title with due dates far apart does not match", () => {
  assert.ok(!isLikelyDuplicate("PS1", NOW, "Problem Set 1 (autograded)", plus(NOW, 10 * DAY)));
});

// :114
test("identical title with due dates weeks apart does not match", () => {
  assert.ok(!isLikelyDuplicate("Reading Response", NOW, "Reading Response", plus(NOW, 30 * DAY)));
});

// ---- announcement tier -------------------------------------------------------

// :122
test("announcement directive is ignored when the structured title matches, even if one date is absent", () => {
  assert.ok(isLikelyAnnouncementDuplicate("Please remember to take Quiz 2", null, "Quiz 2", NOW));
});

// :132
test("numbered structured title matches a directive with trailing platform and deadline wording", () => {
  assert.ok(isLikelyAnnouncementDuplicate("Take Quiz 2 on Canvas by Friday", null, "Quiz 2", NOW));
  assert.ok(isLikelyAnnouncementDuplicate("Take mid term 1 by Thursday", null, "Midterm 1", NOW));
});

// :148
test("assessment identity matches PHYS Quiz 2 despite course and section suffixes", () => {
  assert.ok(isLikelyAnnouncementDuplicate("Take Quiz 2", null, "Quiz 2 — Chapter 4", NOW));
  assert.ok(isLikelyAnnouncementDuplicate("Take Quiz 2 on Canvas by Friday", null, "PHYS Quiz 2 Section 201", NOW));
});

// :164
test("assessment identity keeps practice, retake, and makeup variants distinct", () => {
  for (const variant of ["Practice Quiz 2", "Retake Quiz 2", "Makeup Quiz 2"]) {
    assert.ok(!isLikelyAnnouncementDuplicate(variant, null, "Quiz 2 — Chapter 4", NOW), variant);
  }
});

// :176
test("unnumbered structured titles do not use announcement prefix matching", () => {
  assert.ok(!isLikelyAnnouncementDuplicate("Take the midterm practice version by Friday", null, "Midterm", NOW));
});

// :186
test("numbered prefix does not swallow a tail naming another assignment", () => {
  assert.ok(!isLikelyAnnouncementDuplicate("Take Quiz 2 and Quiz 3", null, "Quiz 2", NOW));
});

// :196
test("announcement directive match still refuses contradictory dates", () => {
  assert.ok(!isLikelyAnnouncementDuplicate("Take Quiz 2", NOW, "Quiz 2", plus(NOW, 30 * DAY)));
});

// ---- work identity (:208 helper announcementTwin) ---------------------------

function twin(a, e, announcementDue = null, existingDue = NOW) {
  return isLikelyAnnouncementDuplicate(a, announcementDue, e, existingDue);
}

// :222
test("work identity: the CIS 4500 pair seen on a phone is one homework", () => {
  assert.ok(twin("Complete HW 2 - Relational Databases", "Complete Homework 2"));
  assert.ok(twin("Complete HW 2 - Relational Databases", "Complete Homework 2", NOW, NOW));
});

// :231
test("work identity: spellings of homework, with # and leading zeros, are one identity", () => {
  for (const other of ["Homework 2", "hw2", "HW #2", "Homework #02", "HW: 2", "Homework no. 2"]) {
    assert.ok(twin("HW 2 due Friday on Canvas, see Ed", other), `HW 2 vs ${other}`);
  }
});

// :238
test("work identity: each noun family joins its own spellings", () => {
  const pairs = [
    ["PSet 3 is out, start early", "Problem Set 3"],
    ["Problem Set 3 is out, start early", "PS3"],
    ["Lab 4 is out, start early", "Lab 04"],
    ["Project 1 is out, start early", "Proj 1"],
    ["Milestone 1 is out, start early", "Milestone #01"],
    ["Assignment 2 is out, start early", "Asst 2"],
    ["Essay 1 is out, start early", "Essay 01"],
    ["Paper 2 is out, start early", "Paper #2"],
  ];
  for (const [a, e] of pairs) assert.ok(twin(a, e), `${a} vs ${e}`);
});

// :255
test("work identity: Submission for Milestone 1 matches Milestone 1: Project Proposal", () => {
  assert.ok(twin("Submission for Milestone 1: Project Proposal", "Milestone 1: Project Proposal"));
});

// :263
test("work identity: a different ordinal or noun is not the same work", () => {
  assert.ok(!twin("Homework 2", "Homework 3"));
  assert.ok(!twin("Lab 4", "Homework 4"));
  assert.ok(!twin("Complete Homework 3", "Complete HW 2 - Relational Databases"));
});

// :270
test("work identity: same noun and different ordinal is refused despite similarity", () => {
  assert.ok(!twin("HW 2 Relational Databases", "HW 3 Relational Databases", NOW, plus(NOW, DAY)));
});

// :279
test("work identity: a Canvas title that adds a topic after the same noun and ordinal still merges", () => {
  assert.ok(twin("Lab 4", "Lab 4 - Pipelining", NOW, NOW));
});

// :287
test("work identity: a noun with no ordinal gives no identity", () => {
  assert.ok(!twin("Homework", "Homework 3"));
  assert.ok(!twin("Homework due Friday on chapter 3", "Homework 3"));
  assert.ok(!twin("Complete the homework", "Complete Homework 2"));
});

// :294
test("work identity: two work nouns on one side never collapse onto either", () => {
  assert.ok(!twin("HW 2 and HW 3 solutions", "HW 2"));
  assert.ok(!twin("Do HW 2 and Lab 4 this week", "Homework 2"));
  assert.ok(!twin("Homework 2", "Homework 2 and Homework 3"));
});

// :301
test("work identity: solutions, grades, regrades, extensions and sub-parts stay distinct", () => {
  for (const variant of [
    "HW 2 solutions posted", "HW 2 solution", "HW 2 grades released",
    "HW 2 regrade requests", "HW 2 extension", "HW 2 practice",
    "HW 2 makeup", "HW 2 make up", "HW 2 redo", "HW 2 resubmission",
    "HW 2 part 2",
  ]) {
    assert.ok(!twin(variant, "Homework 2"), variant);
    assert.ok(!twin("Homework 2", variant), variant);
  }
});

// :314
test("work identity: the same modifier on both sides still matches, different sub-parts do not", () => {
  assert.ok(twin("HW 2 part 1 is out", "Homework 2 Part 1"));
  assert.ok(!twin("HW 2 part 1 is out", "Homework 2 Part 2"));
  assert.ok(twin("HW 2 solutions posted", "Homework 2 Solutions"));
});

// :321
test("work identity: absent dates never block, same day passes, contradictory dates refuse", () => {
  assert.ok(twin("Complete HW 2", "Complete Homework 2", null, NOW));
  assert.ok(twin("Complete HW 2", "Complete Homework 2", NOW, null));
  assert.ok(twin("Complete HW 2", "Complete Homework 2", NOW, NOW));
  assert.ok(twin("Complete HW 2", "Complete Homework 2", NOW, plus(NOW, 7 * DAY)));
  assert.ok(!twin("Complete HW 2", "Complete Homework 2", NOW, plus(NOW, 30 * DAY)));
});

// :338
test("work identity: a quiz-bearing title is left to the assessment tier", () => {
  assert.ok(!twin("Lab 4 quiz 1", "Lab 4"));
  assert.ok(twin("Take Quiz 2", "Quiz 2 - Chapter 4"));
});

// ---- matchPairs ---------------------------------------------------------------

// :346
test("same-titled items in different courses never match", () => {
  const matches = matchPairs(
    [canvas({ id: "c1", course: "CIS 1200", title: "HW 3" })],
    [gradescope({ id: "g1", course: "MATH 1400", title: "HW 3" })],
  );
  assert.deepEqual(matches, []);
});

// :355
test("matches within the same course and leaves unrelated items alone", () => {
  const matches = matchPairs(
    [canvas({ id: "c1", title: "Homework 3" }), canvas({ id: "c2", title: "Homework 4" })],
    [gradescope({ id: "g1", title: "HW3" }), gradescope({ id: "g2", title: "Lab 1" })],
  );
  assert.deepEqual(matches, [{ canvasID: "canvas:c1", gradescopeID: "gradescope:g1" }]);
});

// :370
test("1:1 assignment: a Gradescope item is never claimed by two Canvas items", () => {
  const matches = matchPairs(
    [canvas({ id: "c1", title: "Homework 3" }), canvas({ id: "c2", title: "Homework 3" })],
    [gradescope({ id: "g1", title: "HW3" })],
  );
  assert.equal(matches.length, 1);
  assert.equal(matches[0].gradescopeID, "gradescope:g1");
});

// ---- merge ---------------------------------------------------------------------

// :387
test("merge collapses a matched pair into one Canvas-anchored item carrying linkedID", () => {
  const c = canvas({ id: "c1", title: "Homework 3", due: NOW });
  const g = gradescope({ id: "g1", title: "HW3", due: NOW });
  const merged = merge([c], [g]);
  assert.equal(merged.length, 1);
  assert.equal(`${merged[0].source}:${merged[0].sourceID}`, "canvas:c1");
  assert.equal(merged[0].source, Source.CANVAS);
  assert.equal(merged[0].linkedID, "gradescope:g1");
  assert.ok(Object.isFrozen(merged[0]));
});

// :400
test("merge leaves unmatched items from both sources untouched", () => {
  const c = canvas({ id: "c1", title: "Homework 3" });
  const g = gradescope({ id: "g1", title: "Lab 1" });
  const merged = merge([c], [g]);
  assert.equal(merged.length, 2);
  assert.ok(merged.some((x) => x === c && x.linkedID === null));
  assert.ok(merged.some((x) => x === g));
});

// :411
test("merge marks the merged item submitted if EITHER side reports it", () => {
  const c = canvas({ id: "c1", title: "Homework 3", submitted: false });
  const g = gradescope({ id: "g1", title: "HW3", submitted: true });
  assert.equal(merge([c], [g])[0].submitted, true);
});

// ---- collapseCanvasDuplicates ----------------------------------------------------

// :537
test("a module row collapses onto a canvas row by matching canvasAssignmentID", () => {
  const c = canvasWithURL({ title: "Homework 3", assignmentID: "555" });
  const m = moduleRow({ title: "Something Completely Different", url: "https://canvas.upenn.edu/courses/1/assignments/555" });
  const result = collapseCanvasDuplicates([c], [m]);
  assert.deepEqual(result.canvasItems, [c]);
  assert.deepEqual(result.moduleItems, []);
  assert.deepEqual(result.collapses, [{ canvasID: "canvas:c1", moduleID: "canvasModules:m1" }]);
});

// :554
test("a module row with no url collapses onto a canvas row by title/due match", () => {
  const c = canvas({ id: "c1", title: "Homework 3", due: NOW });
  const m = moduleRow({ id: "m1", title: "HW3", due: NOW });
  const result = collapseCanvasDuplicates([c], [m]);
  assert.deepEqual(result.moduleItems, []);
  assert.deepEqual(result.collapses, [{ canvasID: "canvas:c1", moduleID: "canvasModules:m1" }]);
});

// :567
test("a module row in a different course never collapses", () => {
  const c = canvas({ id: "c1", course: "CIS 1200", title: "Homework 3", due: NOW });
  const m = moduleRow({ id: "m1", course: "MATH 1400", title: "Homework 3", due: NOW });
  const result = collapseCanvasDuplicates([c], [m]);
  assert.deepEqual(result.moduleItems, [m]);
  assert.deepEqual(result.collapses, []);
});

// :578
test("survivors preserve input order", () => {
  const c = canvas({ id: "c1", title: "Unrelated Canvas Item", due: NOW });
  const a = moduleRow({ id: "m-a", title: "Reading Week 1", due: NOW });
  const b = moduleRow({ id: "m-b", title: "Reading Week 2", due: NOW });
  const result = collapseCanvasDuplicates([c], [a, b]);
  assert.deepEqual(result.moduleItems, [a, b]);
  assert.deepEqual(result.collapses, []);
});

// :590
test("a collapse reports both the surviving canvas id and the hidden module id", () => {
  const c = canvasWithURL({ id: "c1", title: "Lab 2", assignmentID: "777" });
  const m = moduleRow({ id: "m1", title: "Lab 2", url: "https://canvas.upenn.edu/courses/1/assignments/777" });
  const { collapses } = collapseCanvasDuplicates([c], [m]);
  assert.equal(collapses[0].canvasID, "canvas:c1");
  assert.equal(collapses[0].moduleID, "canvasModules:m1");
});

// :605
test("two module rows for the same assignment both collapse onto the one canvas row", () => {
  const url = "https://canvas.upenn.edu/courses/1/assignments/555";
  const c = canvasWithURL({ id: "c1", title: "Homework 3", assignmentID: "555" });
  const w = moduleRow({ id: "week3", title: "Homework 3", url });
  const l = moduleRow({ id: "labs", title: "Homework 3", url });
  const result = collapseCanvasDuplicates([c], [w, l]);
  assert.deepEqual(result.moduleItems, []);
  assert.deepEqual(sorted(result.collapses), sorted([
    { canvasID: "canvas:c1", moduleID: "canvasModules:week3" },
    { canvasID: "canvas:c1", moduleID: "canvasModules:labs" },
  ]));
});

// ---- collapseCanvasOverrides --------------------------------------------------------

function threeRows() {
  return [
    canvasWithURL({ id: "mon", title: "Lab 3 (Section 201)", due: NOW, assignmentID: "555" }),
    canvasWithURL({ id: "wed", title: "Lab 3 (Section 202)", due: plus(NOW, 2 * DAY), assignmentID: "555" }),
    canvasWithURL({ id: "fri", title: "Lab 3 (Section 203)", due: plus(NOW, 4 * DAY), assignmentID: "555" }),
  ];
}

// :634
test("three override rows sharing an assignment id keep the row nearest the preferred due date", () => {
  const rows = threeRows();
  const result = collapseCanvasOverrides(rows, new Map([["555", plus(NOW, 2 * DAY)]]));
  assert.deepEqual(result.canvasItems.map((a) => a.sourceID), ["wed"]);
  assert.deepEqual(sorted(result.collapses), sorted([
    { survivorID: "canvas:wed", hiddenID: "canvas:mon" },
    { survivorID: "canvas:wed", hiddenID: "canvas:fri" },
  ]));
});

// :650
test("with no preferred due date, the earliest row survives", () => {
  const result = collapseCanvasOverrides(threeRows(), new Map());
  assert.deepEqual(result.canvasItems.map((a) => a.sourceID), ["mon"]);
  assert.deepEqual(sorted(result.collapses), sorted([
    { survivorID: "canvas:mon", hiddenID: "canvas:wed" },
    { survivorID: "canvas:mon", hiddenID: "canvas:fri" },
  ]));
});

// :666
test("rows with no resolvable canvasAssignmentID are untouched", () => {
  const noID = canvas({ id: "no-id", title: "Reading Response", due: NOW });
  const result = collapseCanvasOverrides([noID], new Map());
  assert.deepEqual(result.canvasItems, [noID]);
  assert.deepEqual(result.collapses, []);
});

// :677
test("the same assignment id in different courses never groups", () => {
  const phys = canvasWithURL({ id: "phys", course: "PHYS 0151", title: "Lab 3 (Section 201)", due: NOW, assignmentID: "555" });
  const chem = canvasWithURL({ id: "chem", course: "CHEM 1012", title: "Lab 3 (Section 201)", due: NOW, assignmentID: "555" });
  const result = collapseCanvasOverrides([phys, chem], new Map());
  assert.deepEqual(result.canvasItems.map((a) => a.sourceID), ["phys", "chem"]);
  assert.deepEqual(result.collapses, []);
});

// :689
test("a Gradescope row is untouched even if it shares a course with grouped canvas rows", () => {
  const [mon, wed] = threeRows();
  const g = gradescope({ id: "g1", title: "Lab 3" });
  const result = collapseCanvasOverrides([mon, wed, g], new Map());
  assert.ok(result.canvasItems.includes(g));
  assert.ok(!result.collapses.some((c) => c.hiddenID === "gradescope:g1" || c.survivorID === "gradescope:g1"));
});

// ---- JS-only tests: behaviours the Swift suite does not pin ---------------------------

// AssignmentDeduplicator.swift:26-42 (no Swift test): the constants.
test("similarTitleDueDateTolerance is 26 hours in seconds", () => {
  assert.equal(similarTitleDueDateTolerance, 93_600);
});

// AssignmentDeduplicator.swift:54,88: the 26h bound is inclusive.
test("fuzzy tier: exactly 26h passes, one second more fails", () => {
  assert.ok(isLikelyDuplicate("PS1", NOW, "Problem Set 1 (autograded)", plus(NOW, 93_600)));
  assert.ok(!isLikelyDuplicate("PS1", NOW, "Problem Set 1 (autograded)", plus(NOW, 93_601)));
});

// AssignmentDeduplicator.swift:81: the 21-day bound is inclusive.
test("identical-title tier: exactly 21 days passes, one second more fails", () => {
  assert.ok(isLikelyDuplicate("Reading Response", NOW, "Reading Response", plus(NOW, 21 * DAY)));
  assert.ok(!isLikelyDuplicate("Reading Response", NOW, "Reading Response", plus(NOW, 21 * DAY + 1)));
});

// AssignmentDeduplicator.swift:770-787 (normalize).
test("normalize: case, punctuation, letter/digit runs, value-compared numbers, phrase collapses", () => {
  assert.deepEqual(normalize("HW3"), ["hw", "3"]);
  assert.deepEqual(normalize("Problem   Set 03!"), ["hw", "3"]);
  assert.deepEqual(normalize("Mid Terms 1"), ["midterm", "1"]);
  assert.deepEqual(normalize("Proj. 1"), ["project", "1"]);
  assert.deepEqual(normalize("labs, 02!"), ["lab", "2"]);
  assert.deepEqual(normalize("Quiz 2 — Chapter 4"), ["quiz", "2", "chapter", "4"]);
  assert.deepEqual(normalize("  ---  "), []);
  assert.deepEqual(normalize(""), []);
});

// AssignmentDeduplicator.swift:833: Int() is nil past Int64, so the token is
// left as written (leading zeros kept) rather than parsed.
test("normalize: a digit run beyond Int64 is not canonicalized", () => {
  assert.deepEqual(normalize("HW 0099999999999999999999"), ["hw", "0099999999999999999999"]);
  assert.deepEqual(normalize("HW 0000000000000000000000003"), ["hw", "3"]);
});

// Lookup tables are Maps: title words named like Object.prototype members
// must not be read as table entries.
test("title words named like Object.prototype members are plain words", () => {
  assert.ok(!twin("constructor 2 toString", "__proto__ 2"));
  assert.ok(!isLikelyDuplicate("constructor", NOW, "hasOwnProperty", NOW));
  assert.ok(isLikelyDuplicate("constructor 2", NOW, "Constructor 02", NOW));
});

// AssignmentDeduplicator.swift:415-420: the exact-title tier (2.0) outranks
// any fuzzy score even when the fuzzy candidate has the closer date.
test("matchPairs: an exact title beats a closer-dated fuzzy title", () => {
  const c = canvas({ id: "c1", title: "Problem Set 1", due: NOW });
  const exact = gradescope({ id: "gExact", title: "PS1", due: plus(NOW, 20 * 3600) });
  const fuzzy = gradescope({ id: "gFuzzy", title: "PS1 autograded", due: NOW });
  assert.deepEqual(matchPairs([c], [fuzzy, exact]), [{ canvasID: "canvas:c1", gradescopeID: "gradescope:gExact" }]);
});

// AssignmentDeduplicator.swift:396-402: equal score, smaller gap wins.
test("matchPairs: equal scores break on the closer due date, then canvas id", () => {
  const c = canvas({ id: "c1", title: "HW 1", due: NOW });
  const far = gradescope({ id: "gFar", title: "Homework 1", due: plus(NOW, 5 * DAY) });
  const near = gradescope({ id: "gNear", title: "Homework 1", due: plus(NOW, 1 * DAY) });
  assert.equal(matchPairs([c], [far, near])[0].gradescopeID, "gradescope:gNear");

  const c1 = canvas({ id: "c1", title: "HW 1", due: NOW });
  const c2 = canvas({ id: "c2", title: "HW 1", due: NOW });
  const g = gradescope({ id: "g1", title: "HW 1", due: NOW });
  assert.equal(matchPairs([c2, c1], [g])[0].canvasID, "canvas:c1");
});

// AssignmentDeduplicator.swift:358-375, 345-350: confirmed pairings are
// honored without re-testing, only while both sides exist and are unclaimed.
test("matchPairs: confirmed pairings survive a moved due date and stale ones are dropped", () => {
  const c = canvas({ id: "c1", title: "Homework 3", due: NOW });
  const g = gradescope({ id: "g1", title: "HW3", due: plus(NOW, 10 * DAY) });
  assert.deepEqual(matchPairs([c], [g]), [{ canvasID: "canvas:c1", gradescopeID: "gradescope:g1" }]); // identical titles: 21d guard not hit
  const c2 = canvas({ id: "c2", title: "Problem Set 1", due: NOW });
  const g2 = gradescope({ id: "g2", title: "PS1 autograded", due: plus(NOW, 10 * DAY) });
  assert.deepEqual(matchPairs([c2], [g2]), []);
  const pin = { canvasID: "canvas:c2", gradescopeID: "gradescope:g2" };
  assert.deepEqual(matchPairs([c2], [g2], [pin]), [pin]);
  assert.deepEqual(matchPairs([c2], [g2], [{ canvasID: "canvas:c2", gradescopeID: "gradescope:gone" }]), []);
  assert.deepEqual(matchPairs([], [g2], [pin]), []);
  // The pairing claims c2 and g2, so no heuristic candidate can reuse them,
  // and a second pairing naming the same canvas id is ignored.
  assert.deepEqual(
    matchPairs([c2], [g2, gradescope({ id: "g3", title: "Problem Set 1" })],
      [pin, { canvasID: "canvas:c2", gradescopeID: "gradescope:g3" }]),
    [pin],
  );
});

// AssignmentDeduplicator.swift:473-488
test("mergedAssignment: Canvas metadata, either-side submitted, per-field score fallback, linkedID", () => {
  const term = { year: 2026, season: 10, code: "202610" };
  const c = makeAssignment({
    source: Source.CANVAS, sourceID: "c1", kind: Kind.QUIZ, course: "CIS 1200", title: "Quiz 1",
    dueAt: NOW, url: "https://canvas.upenn.edu/courses/1/assignments/9", term, scoreEarned: 0, scoreMax: null,
  });
  const g = makeAssignment({
    source: Source.GRADESCOPE, sourceID: "g1", kind: Kind.ASSIGNMENT, course: "CIS 1200", title: "Q1",
    dueAt: plus(NOW, DAY), url: "https://www.gradescope.com/x", term: null, submitted: true, scoreEarned: 9, scoreMax: 10,
  });
  const m = mergedAssignment(c, g);
  assert.ok(Object.isFrozen(m));
  assert.deepEqual(m, {
    source: "canvas", sourceID: "c1", kind: "quiz", course: "CIS 1200", title: "Quiz 1",
    dueAt: NOW, url: "https://canvas.upenn.edu/courses/1/assignments/9", term,
    submitted: true, scoreEarned: 0, scoreMax: 10, linkedID: "gradescope:g1",
  });
});

// AssignmentDeduplicator.swift:445-458: unmatched gradescope items follow the
// merged canvas items, in input order.
test("merge: output order is canvas order, then unmatched gradescope in input order", () => {
  const c1 = canvas({ id: "c1", title: "Homework 3" });
  const c2 = canvas({ id: "c2", title: "Reading" , due: null });
  const g1 = gradescope({ id: "g1", title: "Zed 9" });
  const g2 = gradescope({ id: "g2", title: "HW3" });
  const g3 = gradescope({ id: "g3", title: "Alpha 1" });
  assert.deepEqual(merge([c1, c2], [g1, g2, g3]).map((a) => `${a.source}:${a.sourceID}`),
    ["canvas:c1", "canvas:c2", "gradescope:g1", "gradescope:g3"]);
  // No matches: inputs concatenated unchanged.
  assert.deepEqual(merge([c2], [g1, g3]), [c2, g1, g3]);
});

// AssignmentDeduplicator.swift:558-578: ids beat titles; a canvas id in another course does not count.
test("collapseCanvasDuplicates: pass 1 id match wins over a closer title match, and ids are course-scoped", () => {
  const byTitle = canvas({ id: "cTitle", title: "Lab 2", due: NOW });
  const byID = canvasWithURL({ id: "cID", title: "Something Else", due: plus(NOW, 9 * DAY), assignmentID: "777" });
  const m = moduleRow({ id: "m1", title: "Lab 2", due: NOW, url: "https://canvas.upenn.edu/courses/1/assignments/777" });
  assert.equal(collapseCanvasDuplicates([byTitle, byID], [m]).collapses[0].canvasID, "canvas:cID");
  const other = canvasWithURL({ id: "cID", course: "MATH 1400", title: "Something Else", assignmentID: "777" });
  assert.deepEqual(collapseCanvasDuplicates([other], [m]).collapses, []);
});

// AssignmentDeduplicator.swift:608-612: pass 2 ranks by gap, then ids; a canvas row stays open to other modules.
test("collapseCanvasDuplicates: pass 2 takes the smallest gap and does not claim the canvas row", () => {
  const far = canvas({ id: "cFar", title: "Homework 3", due: plus(NOW, 3600) });
  const near = canvas({ id: "cNear", title: "Homework 3", due: NOW });
  const m1 = moduleRow({ id: "m1", title: "HW 3", due: NOW });
  const m2 = moduleRow({ id: "m2", title: "HW 3", due: NOW });
  const result = collapseCanvasDuplicates([far, near], [m2, m1]);
  assert.deepEqual(result.collapses, [
    { canvasID: "canvas:cNear", moduleID: "canvasModules:m2" },
    { canvasID: "canvas:cNear", moduleID: "canvasModules:m1" },
  ]); // module input order, both onto cNear
  assert.deepEqual(result.moduleItems, []);
});

// AssignmentDeduplicator.swift:548-550
test("collapseCanvasDuplicates: an empty side returns the inputs and no collapses", () => {
  const m = moduleRow({ title: "x" });
  assert.deepEqual(collapseCanvasDuplicates([], [m]), { canvasItems: [], moduleItems: [m], collapses: [] });
});

// AssignmentDeduplicator.swift:714-724: with a preferred date a nil dueAt is infinitely far; ties break on id.
test("collapseCanvasOverrides: undated row loses to a dated one under a preferred date; id breaks ties", () => {
  const dated = canvasWithURL({ id: "b", title: "Lab", due: plus(NOW, 30 * DAY), assignmentID: "9" });
  const undated = canvasWithURL({ id: "a", title: "Lab", due: null, assignmentID: "9" });
  const r1 = collapseCanvasOverrides([undated, dated], { 9: NOW });
  assert.deepEqual(r1.canvasItems.map((x) => x.sourceID), ["b"]);

  const x = canvasWithURL({ id: "x", title: "Lab", due: NOW, assignmentID: "9" });
  const y = canvasWithURL({ id: "y", title: "Lab", due: NOW, assignmentID: "9" });
  assert.deepEqual(collapseCanvasOverrides([y, x], new Map()).canvasItems.map((a) => a.sourceID), ["x"]);
  // Equidistant from the preferred date: id decides.
  const early = canvasWithURL({ id: "z", title: "Lab", due: plus(NOW, -DAY), assignmentID: "9" });
  const late = canvasWithURL({ id: "k", title: "Lab", due: plus(NOW, DAY), assignmentID: "9" });
  assert.deepEqual(collapseCanvasOverrides([early, late], new Map([["9", NOW]])).canvasItems.map((a) => a.sourceID), ["k"]);
});

// AssignmentDeduplicator.swift:719-721: without a preferred date an undated row is the last resort.
test("collapseCanvasOverrides: with no preferred date an undated row is the last resort", () => {
  const dated = canvasWithURL({ id: "z", title: "Lab", due: plus(NOW, 99 * DAY), assignmentID: "9" });
  const undated = canvasWithURL({ id: "a", title: "Lab", due: null, assignmentID: "9" });
  assert.deepEqual(collapseCanvasOverrides([undated, dated], new Map()).canvasItems.map((a) => a.sourceID), ["z"]);
});

// AssignmentDeduplicator.swift:732-735: non-participating rows pass through; survivors keep position; collapses follow hidden-row input order.
test("collapseCanvasOverrides: survivors keep input position and collapses follow hidden-row input order", () => {
  const [mon, wed, fri] = threeRows();
  const g = gradescope({ id: "g1", title: "Lab 3" });
  const mod = moduleRow({ id: "m1", title: "Lab 3", url: "https://canvas.upenn.edu/courses/1/assignments/555" });
  const result = collapseCanvasOverrides([fri, g, mon, mod, wed], new Map());
  assert.deepEqual(result.canvasItems.map((a) => a.sourceID), ["g1", "mon", "m1"]);
  assert.deepEqual(result.collapses.map((c) => c.hiddenID), ["canvas:fri", "canvas:wed"]);
  assert.deepEqual(collapseCanvasOverrides([], new Map()), { canvasItems: [], collapses: [] });
});
