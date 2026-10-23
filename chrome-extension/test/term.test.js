import { test } from "node:test";
import assert from "node:assert/strict";
import { Season, makeTerm, termFromCode, compareTerms, termsEqual } from "../src/core/term.js";

// CourseCodeTests.swift:125-134 (termCodes)
test("term codes parse, reject, and order", () => {
  assert.ok(termsEqual(termFromCode("202610"), makeTerm(2026, Season.SPRING)));
  assert.ok(termsEqual(termFromCode("202620"), makeTerm(2026, Season.SUMMER)));
  assert.ok(termsEqual(termFromCode("202630"), makeTerm(2026, Season.FALL)));
  assert.equal(termFromCode("abc"), null);
  assert.equal(termFromCode("202640"), null); // 40 isn't a valid season
  assert.ok(compareTerms(makeTerm(2025, Season.FALL), makeTerm(2026, Season.SPRING)) < 0);
  assert.ok(compareTerms(makeTerm(2026, Season.SPRING), makeTerm(2026, Season.SUMMER)) < 0);
});

// Term.swift:32-42 and :105-107 (code round-trips through init?(code:)); no Swift test pins these edges.
test("code round-trips and the parser is strict about shape", () => {
  for (const c of ["202610", "202620", "202630"]) assert.equal(termFromCode(c).code, c);
  assert.equal(makeTerm(2026, Season.FALL).code, "202630");
  assert.equal(termFromCode(" 202630 ").code, "202630"); // .whitespaces are trimmed
  assert.equal(termFromCode("20263"), null);
  assert.equal(termFromCode("2026300"), null);
  assert.equal(termFromCode("+02630"), null);
  assert.equal(termFromCode("٢٠٢٦١٠"), null); // Unicode digits pass isNumber, fail Int()
});
