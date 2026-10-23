// Port of Models/CourseCode.swift. Read that file's comments first: the rules
// are old scar tissue, and this port keeps each of them, quirks included.
import { termFromCode } from "./term.js";
import { trimWhitespaceAndNewlines } from "./text.js";

// ICU (NSRegularExpression) treats \b, \w and \d as Unicode-aware; JavaScript's
// are ASCII even with the `u` flag. `W` is ICU's \w
// ([\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}]) and every `\b` below is
// written as a lookaround against it. That is exact here because each \b in
// these patterns sits against a word character on its inner side (a letter or
// digit), so "boundary" reduces to "outer neighbour is not a word character".
// `\d` becomes \p{Nd}. Where this can still differ from ICU: ICU's \b has
// extra handling for some combining sequences, and JS indexes by UTF-16 unit
// as NSString does, so astral characters behave the same; nothing the Swift
// tests exercise reaches either.
const W = String.raw`[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}]`;
const NOT_AFTER_WORD = `(?<!${W})`;
const NOT_BEFORE_WORD = `(?!${W})`;

// CourseCode.swift:129-131, `\b20\d{2}(?:10|20|30)\b`.
const TERM_STAMP = new RegExp(
  `${NOT_AFTER_WORD}20\\p{Nd}{2}(?:10|20|30)${NOT_BEFORE_WORD}`,
  "u",
);
// CourseCode.swift:133-135. The class holds a literal en dash and em dash.
const DEPT_NUMBER = new RegExp(
  `${NOT_AFTER_WORD}([A-Za-z]{2,4})([ \\t]*[-\u2013\u2014][ \\t]*|[ \\t]*)(\\p{Nd}{3,4})${NOT_BEFORE_WORD}`,
  "gu",
);
// CourseCode.swift:138. Uppercase only (no `i`), as in Swift.
const SECTION = new RegExp(
  `${NOT_AFTER_WORD}[A-Z]{2,5}[ -]?\\p{Nd}{3,4}[A-Z]?-(\\p{Nd}{3}[A-Z]?)${NOT_BEFORE_WORD}`,
  "u",
);

const DELIMITERS = new Set(["-", "\u2013", "\u2014"]);

// CourseCode.swift:84-103. Underscore is a word character, so `\b` never fires
// beside one; rewriting to hyphens up front is what makes `ban_phys_151` parse.
function normalizeUnderscores(raw) {
  return raw.replaceAll("_", "-");
}

function firstPass(text) {
  let best = null;
  for (const m of text.matchAll(DEPT_NUMBER)) {
    const [, dept, separator, number] = m;
    const isDelimited = [...separator].some((c) => DELIMITERS.has(c));
    // Spacing alone only counts for an uppercase dept, so "of" in
    // "Class of 2028" is not a department. An empty separator is accepted in
    // any case ("phys151"), CourseCode.swift:161.
    if (!(isDelimited || separator === "" || dept === dept.toUpperCase())) continue;
    // Last valid match wins, so a leading cross-list tag ("ban-") loses.
    best = `${dept.toUpperCase()} ${number}`;
  }
  return best;
}

function extractCode(rawText) {
  const text = normalizeUnderscores(rawText);
  const stamp = TERM_STAMP.exec(text);
  // Search only before the term stamp: the title after it contains things
  // shaped like codes ("THE 1960"). With no code there, fall back to the whole
  // string, title included (CourseCode.swift:102).
  const codeRegion = stamp ? text.slice(0, stamp.index) : text;
  return firstPass(codeRegion) ?? (codeRegion === text ? null : firstPass(text));
}

function extractSection(rawText) {
  // Whole string on purpose, not bounded by the term stamp
  // (CourseCode.swift:193-200): the pattern needs dept, number and a dash.
  const m = SECTION.exec(normalizeUnderscores(rawText));
  return m ? m[1] : null;
}

// Returns { code, term, section }; term and section are null where Swift has nil.
export function parse(raw) {
  const trimmed = trimWhitespaceAndNewlines(raw);
  // The term is looked up on the raw text, before the underscore rewrite
  // (CourseCode.swift:37). `_202630` therefore yields no term, because \b does
  // not fire after `_`, while code and section, which use the rewritten text,
  // still parse. That asymmetry is Swift's and is kept.
  const stamp = TERM_STAMP.exec(trimmed);
  const term = stamp ? termFromCode(stamp[0]) : null;
  const section = extractSection(trimmed);
  const code = extractCode(trimmed);
  if (code !== null) return { code, term, section };
  // Unrecognizable names keep their own text so nothing loses its name.
  return { code: trimmed === "" ? "(unknown course)" : trimmed, term, section };
}

export function containsExplicitCode(raw) {
  return extractCode(trimWhitespaceAndNewlines(raw)) !== null;
}
