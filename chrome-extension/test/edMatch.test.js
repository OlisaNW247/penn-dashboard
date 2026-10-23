// Ports of EdCourseMatcherTests (EdIngestionTests.swift:279-).
import { test } from "node:test";
import assert from "node:assert/strict";
import { match, normalizedCode, termOfEdCourse, termFromText } from "../src/core/edMatch.js";
import { makeTerm, Season } from "../src/core/term.js";

const fall2026 = makeTerm(2026, Season.FALL);
const ed = (id, code, year = null, session = null) => ({ id, code, name: "n", year, session });

test("normalizedCode makes Ed's and Canvas's spellings agree", () => {
  for (const raw of ["CIS 2400", "cis2400", "CIS-2400", "CIS 2400-001", "  cis   2400 ", "CIS 2400"]) {
    assert.equal(normalizedCode(raw), "CIS 2400", raw);
  }
  assert.equal(normalizedCode("CHEM 1010L"), "CHEM 1010L");
  assert.equal(normalizedCode("ban-phys-151-1234"), "PHYS 151");
  assert.equal(normalizedCode("Intro Seminar"), "INTROSEMINAR");
});

test("term of an Ed course reads year and session, and gives up on anything ambiguous", () => {
  assert.deepEqual(termOfEdCourse(ed(1, "X 1", "2026", "Fall")), fall2026);
  assert.deepEqual(termOfEdCourse(ed(1, "X 1", null, "Spring 2027")), makeTerm(2027, Season.SPRING));
  assert.equal(termOfEdCourse(ed(1, "X 1", "2026", "Winter")), null);
  assert.equal(termOfEdCourse(ed(1, "X 1", "2025-2026", "Spring")), null);
  assert.equal(termOfEdCourse(ed(1, "X 1", "2026", null)), null);
  assert.deepEqual(termFromText("Fall 2026"), fall2026);
  assert.deepEqual(termFromText("202630"), fall2026);
});

test("a link beats code matching, and settles that Canvas code", () => {
  const m = match({
    edCourses: [ed(1, "CIS 2400", "2026", "Fall"), ed(2, "CIS 2400", "2026", "Fall")],
    canvasCourses: [{ code: "CIS 2400", term: fall2026 }],
    edLinks: { "CIS 2400": 2 },
  });
  assert.deepEqual(m, [{ edCourseID: 2, canvasCourseCode: "CIS 2400", confidence: "link" }]);
});

test("a link to a course the student is not enrolled in is ignored", () => {
  const m = match({
    edCourses: [ed(1, "CIS 2400", "2026", "Fall")],
    canvasCourses: [{ code: "CIS 2400", term: fall2026 }],
    edLinks: { "CIS 2400": 777 },
  });
  assert.deepEqual(m, [{ edCourseID: 1, canvasCourseCode: "CIS 2400", confidence: "codeAndTerm" }]);
});

test("code and term beats code only; a missing term on either side is code only", () => {
  const m = match({
    edCourses: [ed(1, "CIS2400", "2026", "Fall"), ed(2, "MATH 1400-001"), ed(3, "PHYS 0151", "2026", "Fall")],
    canvasCourses: [
      { code: "CIS 2400", term: fall2026 },
      { code: "MATH 1400", term: fall2026 },
      { code: "PHYS 0151", term: null },
    ],
  });
  assert.deepEqual(m, [
    { edCourseID: 1, canvasCourseCode: "CIS 2400", confidence: "codeAndTerm" },
    { edCourseID: 2, canvasCourseCode: "MATH 1400", confidence: "codeOnly" },
    { edCourseID: 3, canvasCourseCode: "PHYS 0151", confidence: "codeOnly" },
  ]);
});

test("two Ed courses with one code: only the one matching the term is returned", () => {
  const m = match({
    edCourses: [ed(1, "CIS 2400", "2025", "Fall"), ed(2, "CIS 2400", "2026", "Fall")],
    canvasCourses: [{ code: "CIS 2400", term: fall2026 }],
  });
  assert.deepEqual(m, [{ edCourseID: 2, canvasCourseCode: "CIS 2400", confidence: "codeAndTerm" }]);
});

test("a previous offering with a known, different term is not matched", () => {
  const m = match({
    edCourses: [ed(1, "CIS 2400", "2025", "Fall")],
    canvasCourses: [{ code: "CIS 2400", term: fall2026 }],
  });
  assert.deepEqual(m, []);
});

test("two code-only candidates with nothing to choose between match nothing", () => {
  const m = match({
    edCourses: [ed(1, "CIS 2400"), ed(2, "CIS 2400")],
    canvasCourses: [{ code: "CIS 2400", term: null }],
  });
  assert.deepEqual(m, []);
});

test("an Ed course is never matched to two Canvas codes; the higher confidence wins", () => {
  const m = match({
    edCourses: [ed(1, "CIS 2400", "2026", "Fall")],
    canvasCourses: [{ code: "CIS 2400", term: null }, { code: "CIS 2400-001", term: fall2026 }],
  });
  assert.deepEqual(m, [{ edCourseID: 1, canvasCourseCode: "CIS 2400-001", confidence: "codeAndTerm" }]);
  const linked = match({ edCourses: [ed(1, "CIS 2400")], canvasCourses: [], edLinks: { "CIS 2400": 1, "CIS 2401": 1 } });
  assert.equal(linked.length, 1);
});
