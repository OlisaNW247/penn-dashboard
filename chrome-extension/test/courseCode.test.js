import { test } from "node:test";
import assert from "node:assert/strict";
import { parse, containsExplicitCode } from "../src/core/courseCode.js";
import { Season, makeTerm, termsEqual } from "../src/core/term.js";

const spring26 = makeTerm(2026, Season.SPRING);
const summer26 = makeTerm(2026, Season.SUMMER);
const fall26 = makeTerm(2026, Season.FALL);
const fall25 = makeTerm(2025, Season.FALL);

// CourseCodeTests.swift:15-85 (the `cases` table, in order), run by parsesTable at :87-93
const cases = [
  ["FNAR 3230-401 202610 PSYCHEDELIC ART & THE 1960s", "FNAR 3230", spring26],
  ["ENM 5100-001", "ENM 5100", null],
  ["CIS 5050-001 Software Systems", "CIS 5050", null],
  ["CIS 1200", "CIS 1200", null],
  ["PHYS 0150-002 202620 Physics I", "PHYS 0150", summer26],
  ["MATH 1400-910 202620", "MATH 1400", summer26],
  ["CIS 3200-001 202530 Algorithms", "CIS 3200", fall25],
  ["MGMT 2370-403 Management", "MGMT 2370", null],
  ["ban-cis-3200-001 202630 Cross-Listed Seminar", "CIS 3200", fall26],
  ["ban-cis-3200", "CIS 3200", null],
  ["ban - phys - 151 - 1234", "PHYS 151", null],
  ["BAN - PHYS - 151 - 1234", "PHYS 151", null],
  ["ban - phys - 0150 - 001 202630 Principles of Physics", "PHYS 0150", fall26],
  ["ban_phys_151_1234", "PHYS 151", null],
  ["phys – 151", "PHYS 151", null],
  ["FNAR 3230-401 202610 PSYCHEDELIC ART & THE 1960", "FNAR 3230", spring26],
  ["MUSC 2500-001 THE BEATLES 1967", "MUSC 2500", null],
  ["BAN_CIS-2400-001 202630", "CIS 2400", fall26],
  ["BAN_PHYS-0151-151 202630", "PHYS 0151", fall26],
  ["BAN_PHYS-0151-402 202630", "PHYS 0151", fall26],
  ["BAN_2400", "BAN 2400", null],
  ["TAP_2028", "TAP 2028", null],
  ["Class of 2028", "Class of 2028", null],
  ["(unknown course)", "(unknown course)", null],
];

for (const [raw, code, term] of cases) {
  test(`parse ${JSON.stringify(raw)}`, () => {
    const p = parse(raw);
    assert.equal(p.code, code);
    assert.ok(termsEqual(p.term, term), `term ${JSON.stringify(p.term)}`);
  });
}

// CourseCodeTests.swift:97-104
test("containsExplicitCode agrees with extractCode's underscore handling", () => {
  assert.equal(containsExplicitCode("BAN_CIS-2400-001 202630"), true);
  assert.equal(containsExplicitCode("ban-cis-3200-001 202630 Cross-Listed Seminar"), true);
  assert.equal(containsExplicitCode("FNAR 3230-401 202610 PSYCHEDELIC ART & THE 1960s"), true);
  assert.equal(containsExplicitCode("Class of 2028"), false);
  assert.equal(containsExplicitCode(""), false);
});

// CourseCodeTests.swift:106-113
test("section is captured from a dash-delimited registrar section token", () => {
  assert.equal(parse("PHYS 0151-151 202630 Physics Lab").section, "151");
  assert.equal(parse("PHYS 0151-401 202630 Physics Lecture").section, "401");
});

// CourseCodeTests.swift:115-118
test("section survives underscore normalization the same way the code does", () => {
  assert.equal(parse("PHYS_0151-401_202630").section, "401");
});

// CourseCodeTests.swift:120-124
test("section is nil when the descriptor has no dash-section", () => {
  assert.equal(parse("PHYS 0151 202630 Physics").section, null);
  assert.equal(parse("CIS 1200").section, null);
});

// No Swift test. Follows from CourseCode.swift:37 (term read off the raw text) and
// the regex semantics: `_` is a word character, so \b does not fire in `_202630`.
test("an underscore directly before the term stamp hides the term but not the code or section", () => {
  const p = parse("PHYS_0151-401_202630");
  assert.equal(p.code, "PHYS 0151");
  assert.equal(p.term, null);
});

// No Swift test; CourseCode.swift:102 (whole-string fallback) and :161 (empty separator).
test("quirks kept from Swift", () => {
  // No code before the stamp: the search falls back to the title.
  assert.equal(parse("202630 PHYS 151 Lab").code, "PHYS 151");
  // An empty separator is accepted in any case.
  assert.equal(parse("phys151").code, "PHYS 151");
  // Whitespace separator with a lowercase dept is rejected.
  assert.equal(parse("phys 151").code, "phys 151");
  // Leading zeros and letter suffixes survive.
  assert.equal(parse("PHYS 0151-201A 202630").section, "201A");
  // Section is uppercase-only.
  assert.equal(parse("phys 0151-401 202630").section, null);
  assert.equal(parse("   ").code, "(unknown course)");
  // Term stamp must be exactly six digits.
  assert.equal(parse("CIS 1200 2026100").term, null);
});

// No Swift test; the ICU Unicode \b / \d behaviour the port reproduces (courseCode.js header).
test("word boundaries and digits are Unicode-aware, as in ICU", () => {
  assert.equal(parse("éCIS 1200").code, "éCIS 1200"); // letter before dept: no boundary
  assert.equal(parse("CIS 1200é").code, "CIS 1200é");
  assert.equal(parse("CIS ١٢٠٠").code, "CIS ١٢٠٠"); // Nd digits count
});
