// Port of Models/Term.swift: a Penn academic term, encoded in Canvas course
// descriptors as YYYYTT where TT is 10 spring, 20 summer, 30 fall. There is no
// winter (Term.swift:11-15).
import { trimWhitespaces } from "./text.js";

export const Season = Object.freeze({ SPRING: 10, SUMMER: 20, FALL: 30 });

const SEASONS = new Set(Object.values(Season));

export function makeTerm(year, season) {
  if (!SEASONS.has(season)) throw new RangeError(`unknown season ${season}`);
  // `code` is stored, not computed, so a Term survives JSON and
  // chrome.storage as a plain {year, season, code} object.
  const code = String(year).padStart(4, "0") + String(season).padStart(2, "0");
  return Object.freeze({ year, season, code });
}

// Term.swift:32-42. Returns null where Swift returns nil.
//
// `isNumber` in Swift is Unicode (\p{N}), so Arabic-Indic digits pass the
// first check and are then rejected by Int(), which only reads ASCII. The two
// steps are kept separate so the outcome is the same (nil) without relying on
// that coincidence. Length is counted in code points; Swift counts grapheme
// clusters, which differs only for combining marks, and those fail isNumber.
export function termFromCode(code) {
  const digits = [...trimWhitespaces(String(code))];
  if (digits.length !== 6) return null;
  if (!digits.every((c) => /^\p{N}$/u.test(c))) return null;
  const s = digits.join("");
  if (!/^[0-9]{6}$/.test(s)) return null;
  const season = Number(s.slice(4));
  if (!SEASONS.has(season)) return null;
  return makeTerm(Number(s.slice(0, 4)), season);
}

// Term.swift:112-114: ordered by (year, season). Negative, zero or positive.
export function compareTerms(a, b) {
  return a.year - b.year || a.season - b.season;
}

export function termsEqual(a, b) {
  if (a == null || b == null) return a == null && b == null;
  return a.year === b.year && a.season === b.season;
}
