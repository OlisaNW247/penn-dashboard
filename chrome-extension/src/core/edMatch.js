// Port of Ed/EdCourseMatcher.swift: which of the student's Ed courses belongs
// to which of their Canvas courses. A wrong match publishes the wrong class's
// announcements into a shared pool, so every rule errs toward fewer matches
// and an ambiguous case returns none (the Swift doc comment lists them).
//
//   edCourses      [{ id, code, name, year, session }]   (ed.js decodeUserResponse)
//   canvasCourses  [{ code, term }]                      term is a term.js Term or null
//   edLinks        { [canvasCode]: edCourseID }          the phone passes none
// Returns [{ edCourseID, canvasCourseCode, confidence }] sorted by edCourseID;
// confidence is "link" | "codeAndTerm" | "codeOnly".
import { makeTerm, Season, termFromCode, termsEqual } from "./term.js";

const SEPARATORS = new Set(["-", "_", "–", "—", "/", ".", " ", "\t", " "]);
const isLetter = (c) => /^\p{L}$/u.test(c);
const isNumber = (c) => /^\p{N}$/u.test(c);

// EdCourseMatcher.normalizedCode
export function normalizedCode(raw) {
  const chars = Array.from(raw.toUpperCase());
  let i = 0;
  while (i < chars.length) {
    if (!isLetter(chars[i])) { i += 1; continue; }
    const deptStart = i;
    while (i < chars.length && isLetter(chars[i])) i += 1;
    const dept = chars.slice(deptStart, i).join("");
    let j = i;
    while (j < chars.length && SEPARATORS.has(chars[j])) j += 1;
    if (!(dept.length >= 2 && dept.length <= 8 && j < chars.length && isNumber(chars[j]))) continue;
    const numberStart = j;
    while (j < chars.length && isNumber(chars[j])) j += 1;
    let number = chars.slice(numberStart, j).join("");
    if (j < chars.length && isLetter(chars[j]) && (j + 1 === chars.length || !isLetter(chars[j + 1]))) {
      number += chars[j];
    }
    return dept + " " + number;
  }
  return chars.filter((c) => isLetter(c) || isNumber(c)).join("");
}

function seasonFromText(text) {
  const lower = text.toLowerCase();
  if (lower.includes("fall") || lower.includes("autumn")) return Season.FALL;
  if (lower.includes("spring")) return Season.SPRING;
  if (lower.includes("summer")) return Season.SUMMER;
  return null;
}

// The year, only when the text names exactly one distinct four-digit year.
function singleYear(text) {
  const years = new Set();
  let run = "";
  for (const ch of text + " ") {
    if (/^[0-9]$/.test(ch)) {
      run += ch;
    } else {
      if (run.length === 4) years.add(Number(run));
      run = "";
    }
  }
  return years.size === 1 ? [...years][0] : null;
}

// EdCourseMatcher.term(of:): null for anything ambiguous.
export function termOfEdCourse(course) {
  if (course.session === null || course.session === undefined) return null;
  const season = seasonFromText(course.session);
  if (season === null) return null;
  const year = (course.year !== null && course.year !== undefined ? singleYear(course.year) : null) ?? singleYear(course.session);
  return year === null ? null : makeTerm(year, season);
}

// EdCourseMatcher.term(fromText:): "Fall 2026" or "202630".
export function termFromText(text) {
  const byCode = termFromCode(text);
  if (byCode !== null) return byCode;
  const season = seasonFromText(text);
  const year = singleYear(text);
  return season === null || year === null ? null : makeTerm(year, season);
}

const byString = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

export function match({ edCourses, canvasCourses, edLinks = {} }) {
  const results = [];
  const claimedEd = new Set();
  const claimedCanvasCodes = new Set();
  const edByID = new Map();
  for (const c of edCourses) if (!edByID.has(c.id)) edByID.set(c.id, c);

  // 1. Links, in code order.
  for (const canvasCode of Object.keys(edLinks).sort(byString)) {
    const edID = edLinks[canvasCode];
    if (!edByID.has(edID) || claimedEd.has(edID)) continue;
    claimedEd.add(edID);
    claimedCanvasCodes.add(canvasCode);
    results.push({ edCourseID: edID, canvasCourseCode: canvasCode, confidence: "link" });
  }

  // 2 and 3. Heuristics.
  const refsByCode = new Map();
  for (const ref of canvasCourses) {
    if (claimedCanvasCodes.has(ref.code)) continue;
    if (!refsByCode.has(ref.code)) refsByCode.set(ref.code, []);
    refsByCode.get(ref.code).push(ref);
  }

  let candidates = [];
  const sortedEd = [...edCourses].sort((a, b) => a.id - b.id);
  for (const canvasCode of [...refsByCode.keys()].sort(byString)) {
    const refs = refsByCode.get(canvasCode);
    const canvasKey = normalizedCode(canvasCode);
    let forThisCode = [];
    for (const ed of sortedEd) {
      if (claimedEd.has(ed.id)) continue;
      if (normalizedCode(ed.code) !== canvasKey) continue;
      const edTerm = termOfEdCourse(ed);
      let best = null;
      for (const ref of refs) {
        let confidence;
        if (edTerm && ref.term) {
          if (!termsEqual(edTerm, ref.term)) continue;
          confidence = "codeAndTerm";
        } else {
          confidence = "codeOnly";
        }
        if (best === null || confidence === "codeAndTerm") best = confidence;
      }
      if (best !== null) forThisCode.push({ edID: ed.id, canvasCode, confidence: best });
    }
    if (forThisCode.some((c) => c.confidence === "codeAndTerm")) {
      forThisCode = forThisCode.filter((c) => c.confidence === "codeAndTerm");
    } else if (forThisCode.length > 1) {
      forThisCode = [];
    }
    candidates = candidates.concat(forThisCode);
  }

  candidates.sort((l, r) => {
    if (l.confidence !== r.confidence) return l.confidence === "codeAndTerm" ? -1 : 1;
    if (l.edID !== r.edID) return l.edID - r.edID;
    return byString(l.canvasCode, r.canvasCode);
  });
  for (const c of candidates) {
    if (claimedEd.has(c.edID)) continue;
    claimedEd.add(c.edID);
    results.push({ edCourseID: c.edID, canvasCourseCode: c.canvasCode, confidence: c.confidence });
  }
  return results.sort((a, b) => a.edCourseID - b.edCourseID);
}
