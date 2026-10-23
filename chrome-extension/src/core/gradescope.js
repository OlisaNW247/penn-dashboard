// Port of Gradescope/GradescopeClient.swift: `GradescopeHTMLParser` (L152-841)
// and the pure decisions inside `GradescopeClient` (L3-150), minus every fetch.
// Regexes and string scanning only: a service worker has no DOMParser.
//
// Where Swift's behaviour is a quirk (and the Swift file's own comments do not
// excuse it) the port keeps it and says so. "Unverified" marks places where the
// Swift behaviour comes from Foundation/ICU and could not be run here.
import { makeTerm } from "./term.js";
import { makeAssignment, Source, Kind, isOrderedByDueDate } from "./assignment.js";
import { trimWhitespaceAndNewlines } from "./text.js";

// ---------------------------------------------------------------------------
// Regex plumbing
// ---------------------------------------------------------------------------

// NSRegularExpression is ICU: \b, \d and \s are Unicode-aware, JavaScript's are
// not (and JS \s also contains U+FEFF but lacks U+0085, which ICU has the other
// way round). Patterns below are written with \b \d \s and rewritten here.
// `\b` as a lookaround pair is ICU's definition minus its handling of some
// combining sequences (same limitation as courseCode.js).
const W = String.raw`[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}]`;
const BOUNDARY = `(?:(?<=${W})(?!${W})|(?<!${W})(?=${W}))`;

function icu(src, flags) {
  const body = src.replace(/\\([bds])/g, (_, c) =>
    c === "b" ? BOUNDARY : c === "d" ? String.raw`\p{Nd}` : String.raw`[\p{White_Space}]`);
  return new RegExp(body, flags + "u");
}

const cache = new Map();
function compiled(src, flags) {
  const key = `${flags}/${src}`;
  let re = cache.get(key);
  if (!re) cache.set(key, (re = icu(src, flags)));
  return re;
}

// `matches` in Swift (GradescopeClient.swift:710-725): every match, case
// insensitive and dot-matches-newline, whatever the pattern says. Returns the
// capture groups with non-participating groups removed (Swift compactMaps them
// away, which shifts indices; no pattern here has an optional group), plus the
// span of the whole match for the callers that slice by it.
function matchAll(src, text) {
  const re = compiled(src, "gis");
  return [...text.matchAll(re)].map((m) => ({
    groups: m.slice(1).filter((g) => g !== undefined),
    index: m.index,
    end: m.index + m[0].length,
  }));
}
const firstGroup = (src, text) => matchAll(src, text)[0]?.groups[0];

// ICU `.` without dotMatchesLineSeparators stops at \n \v \f \r U+0085 U+2028
// U+2029. JavaScript's stops at four of those.
const NO_NL = String.raw`[^\n\u000b\f\r\u0085  ]`;

// ---------------------------------------------------------------------------
// cleanText (GradescopeClient.swift:727-735, 824-841)
// ---------------------------------------------------------------------------

// Hazard #1. Swift decodes by iterating a Dictionary literal, so the order is
// unspecified and `&amp;lt;` may come out as `<` or `&lt;`. The tests need only
// `&amp;` -> `&` (GradescopeTests.swift:470). This fixes the order with `&amp;`
// LAST, so `&amp;lt;` decodes once, to the literal text `&lt;`.
const ENTITIES = [
  ["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'], ["&#39;", "'"],
  ["&apos;", "'"], ["&nbsp;", " "], ["&amp;", "&"],
];
function htmlDecoded(s) {
  for (const [entity, value] of ENTITIES) s = s.replaceAll(entity, value);
  return s;
}

// Hazard #7. Script and style are stripped with `.` NOT matching newlines
// (Swift passes .regularExpression + .caseInsensitive only, L729-730). A
// multi-line <script> body therefore survives and its text leaks into the
// cleaned output, where it can trip isCompletedStatus. Kept.
export function cleanText(html) {
  let s = html
    .replace(compiled(`<script\\b[^>]*>${NO_NL}*?</script>`, "gi"), " ")
    .replace(compiled(`<style\\b[^>]*>${NO_NL}*?</style>`, "gi"), " ")
    .replace(/<[^>]+>/g, " ");
  s = htmlDecoded(s).replace(compiled(String.raw`\s+`, "g"), " ");
  return trimWhitespaceAndNewlines(s);
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

// `URL(string:relativeTo:)?.absoluteURL`. WHATWG URL normalises a little more
// than Foundation (host case, default port); not exercised by the tests.
function resolveURL(href, base) {
  try {
    return new URL(href, base).href;
  } catch {
    return null;
  }
}

// GradescopeClient.swift:559-564. First "courses" component and the one after.
function courseIDFromURL(url) {
  let path;
  try {
    path = new URL(url).pathname;
  } catch {
    return null;
  }
  const parts = path.split("/").filter((p) => p !== "").map((p) => {
    try { return decodeURIComponent(p); } catch { return p; }
  });
  const i = parts.indexOf("courses");
  if (i < 0 || i + 1 >= parts.length) return null;
  const id = parts[i + 1];
  return id !== "" && /^\p{N}+$/u.test(id) ? id : null;
}

// ---------------------------------------------------------------------------
// Course discovery (L152-346)
// ---------------------------------------------------------------------------

function makeCourseLink(name, url, term = null) {
  return Object.freeze({ name, url, term });
}

function shortCourseName(inner) {
  const short = firstGroup(String.raw`courseBox--shortname[^>]*>(.*?)<`, inner);
  if (short !== undefined) {
    const s = cleanText(short);
    if (s !== "") return s;
  }
  // Fallback: drop a trailing "N assignment(s)" (L203-204).
  return cleanText(inner).replace(compiled(String.raw`\s*\d+\s+assignments?$`, "gi"), "");
}

// L181-193. `seen` is only consulted for links that have a name, so a nameless
// link does not claim its URL (the guard short-circuits in Swift).
export function courseLinks(html, baseURL) {
  const pattern = String.raw`<a\b[^>]*href\s*=\s*["']([^"']*/courses/\d+)/?["'][^>]*>(.*?)</a>`;
  const seen = new Set();
  const out = [];
  for (const { groups } of matchAll(pattern, html)) {
    if (groups.length < 2) continue;
    const url = resolveURL(groups[0], baseURL);
    if (url === null) continue;
    const name = shortCourseName(groups[1]);
    if (name === "" || seen.has(url)) continue;
    seen.add(url);
    out.push(makeCourseLink(name, url));
  }
  return out;
}

// GradescopeTerm (L742-822), file-private in Swift.
const GS = Object.freeze({ WINTER: 0, SPRING: 1, SUMMER: 2, FALL: 3 });

function gradescopeTermFromLabel(label) {
  const lower = label.toLowerCase();
  const year = firstGroupWhole(String.raw`\b(19|20)\d{2}\b`, lower);
  // Int() reads ASCII only; \d here is Unicode, so "٢٠٢٦" matches and then
  // fails to parse, giving nil exactly as in Swift.
  if (year === undefined || !/^[0-9]+$/.test(year)) return null;
  let season;
  if (lower.includes("spring")) season = GS.SPRING;
  else if (lower.includes("summer")) season = GS.SUMMER;
  else if (lower.includes("fall") || lower.includes("autumn")) season = GS.FALL;
  else if (lower.includes("winter")) season = GS.WINTER;
  else return null;
  return { year: Number(year), season };
}

function firstGroupWhole(src, text) {
  const m = compiled(src, "i").exec(text);
  return m ? m[0] : undefined;
}

// Winter has no Penn season (Term.swift), so it files under spring (L768-774).
function pennTermOf(t) {
  switch (t.season) {
    case GS.WINTER:
    case GS.SPRING: return makeTerm(t.year, 10);
    case GS.SUMMER: return makeTerm(t.year, 20);
    default: return makeTerm(t.year, 30);
  }
}

// L795-817. Local-time dates (Calendar(identifier: .gregorian) uses the
// current zone). Both bounds inclusive: Swift's ClosedRange.
function windowOf(t) {
  const day = (y, m, d, endOfDay = false) =>
    endOfDay ? new Date(y, m - 1, d, 23, 59, 59) : new Date(y, m - 1, d);
  switch (t.season) {
    case GS.WINTER: return [day(t.year - 1, 12, 1), day(t.year, 3, 31, true)];
    case GS.SPRING: return [day(t.year, 1, 1), day(t.year, 6, 30, true)];
    case GS.SUMMER: return [day(t.year, 5, 1), day(t.year, 8, 31, true)];
    default: return [day(t.year, 8, 1), day(t.year, 12, 31, true)];
  }
}

const gsTermLess = (a, b) => a.year < b.year || (a.year === b.year && a.season < b.season);

// L314-341. A heading's group runs from the end of the heading match to the
// start of the next heading; groups with no course links are dropped.
function coursesByTerm(html, baseURL) {
  const heading = String.raw`<[^>]*\bclass\s*=\s*["'][^"']*courseList--term[^"']*["'][^>]*>(.*?)</[^>]+>`;
  const headings = matchAll(heading, html);
  const out = [];
  headings.forEach((h, i) => {
    const label = cleanText(h.groups[0]);
    const segmentEnd = i + 1 < headings.length ? headings[i + 1].index : html.length;
    const courses = courseLinks(html.slice(h.end, segmentEnd), baseURL);
    if (courses.length > 0) out.push({ term: label, courses });
  });
  return out;
}

function dedupedByURL(courses) {
  const seen = new Set();
  return courses.filter((c) => (seen.has(c.url) ? false : (seen.add(c.url), true)));
}

const FALLBACK_GRACE_MS = 21 * 86_400 * 1000;

// L258-300. `now` is a Date; the result is { courses, isFallback }.
export function currentTermCourses(html, baseURL, now = new Date()) {
  const groups = coursesByTerm(html, baseURL);
  if (groups.length === 0) {
    return { courses: courseLinks(html, baseURL), isFallback: false };
  }

  const dated = [];
  for (const g of groups) {
    const term = gradescopeTermFromLabel(g.term);
    if (term) dated.push({ term, courses: g.courses });
  }

  // Every dated group whose window covers `now`, not just one: Winter and
  // Spring overlap in February, Spring and Summer in May (L273-277).
  const active = dated
    .filter(({ term }) => {
      const [lo, hi] = windowOf(term);
      return lo <= now && now <= hi;
    })
    .flatMap(({ term, courses }) => courses.map((c) => makeCourseLink(c.name, c.url, pennTermOf(term))));
  if (active.length > 0) return { courses: dedupedByURL(active), isFallback: false };

  // Strict `<` keeps the FIRST of equal terms, as max(by:) does.
  let newest = null;
  for (const d of dated) if (newest === null || gsTermLess(newest.term, d.term)) newest = d;
  if (newest) {
    // Hazard #12. Only the upper bound is checked: a term that has not started
    // yet can be chosen as the fallback (L286-293).
    const hi = windowOf(newest.term)[1];
    if (!(now.getTime() < hi.getTime() + FALLBACK_GRACE_MS)) {
      return { courses: [], isFallback: false };
    }
    const term = pennTermOf(newest.term);
    return {
      courses: dedupedByURL(newest.courses.map((c) => makeCourseLink(c.name, c.url, term))),
      isFallback: true,
    };
  }

  // No label parsed at all: the first group, and not a fallback (L296-299).
  return { courses: dedupedByURL(groups[0].courses), isFallback: false };
}

// L309-312.
export function filterFallbackAssignments(assignments, isFallback) {
  return isFallback ? assignments.filter((a) => a.dueAt != null) : assignments;
}

// ---------------------------------------------------------------------------
// Dates (L402-454, 670-708)
// ---------------------------------------------------------------------------

const MONTHS = ["january", "february", "march", "april", "may", "june", "july",
  "august", "september", "october", "november", "december"];
const MONTH_ALT = [...MONTHS, ...MONTHS.map((m) => m.slice(0, 3))]
  .sort((a, b) => b.length - a.length).join("|");
const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const WEEKDAY_ALT = [...WEEKDAYS, ...WEEKDAYS.map((d) => d.slice(0, 3))]
  .sort((a, b) => b.length - a.length).join("|");

// DateFormatter patterns, compiled to anchored regexes. The Swift formatter is
// en_US_POSIX, not lenient, and uses the current time zone (L670-681).
// Behaviour taken from ICU and UNVERIFIED because Swift cannot run here:
//  - the whole string must be consumed;
//  - `yyyy` accepts any number of digits as the literal year ("5/24/26" is
//    year 26, and since M/d/yyyy precedes M/d/yy the yy formats are
//    unreachable); `yy` windows exactly-two-digit years to now-80..now+20;
//  - month and weekday names match case-insensitively, long or short form
//    under either MMM or MMMM (the result is the same either way because the
//    formats are tried in order);
//  - out-of-range fields (Feb 30, hour 24, 2:30 on a spring-forward night) fail
//    the whole format rather than rolling over;
//  - the weekday is read and ignored;
//  - with no year in the pattern the year is 1970, so "Feb 29 ..." and
//    1970's DST gap hours fail (ICU's default calendar year).
function compileFormat(fmt) {
  const fields = [];
  let src = "";
  const field = (name, re) => { fields.push(name); src += `(${re})`; };
  for (let i = 0; i < fmt.length;) {
    const c = fmt[i];
    if (c === "'") {
      const j = fmt.indexOf("'", i + 1);
      src += fmt.slice(i + 1, j).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      i = j + 1;
      continue;
    }
    let n = 1;
    while (fmt[i + n] === c) n++;
    const run = c.repeat(n);
    i += n;
    switch (c) {
      case "y": field(n === 2 ? "yy" : "yyyy", "[0-9]+"); break;
      case "M": n >= 3 ? field("mon", MONTH_ALT) : field("M", "[0-9]+"); break;
      case "d": field("d", "[0-9]+"); break;
      case "H": field("H", "[0-9]+"); break;
      case "h": field("h", "[0-9]+"); break;
      case "m": field("m", "[0-9]+"); break;
      case "s": field("s", "[0-9]+"); break;
      case "S": field("S", "[0-9]+"); break;
      case "a": field("a", "am|pm"); break;
      case "E": field("E", WEEKDAY_ALT); break;
      // XXXXX: ISO 8601 with a colon, or Z.
      case "X": field("tz", "Z|[+-][0-9]{2}:[0-9]{2}"); break;
      // Z: RFC 822 offset; the colon form is also accepted (unverified).
      case "Z": field("tz", "[+-][0-9]{2}:?[0-9]{2}"); break;
      default: src += run.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }
  }
  return { re: new RegExp(`^${src}$`, "iu"), fields };
}

const FORMATS_WITH_YEAR = [
  "yyyy-MM-dd'T'HH:mm:ssXXXXX",
  "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
  "yyyy-MM-dd'T'HH:mm:ssZ",
  "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
  "yyyy-MM-dd HH:mm:ss Z",
  "yyyy-MM-dd HH:mm:ssZ",
  "MMM d, yyyy h:mm a",
  "MMM d, yyyy, h:mm a",
  "MMMM d, yyyy h:mm a",
  "MMMM d, yyyy, h:mm a",
  "E, MMM d, yyyy h:mm a",
  "E, MMM d, yyyy, h:mm a",
  "M/d/yyyy h:mm a",
  "M/d/yy h:mm a",
  "yyyy-MM-dd h:mm a",
  "yyyy-MM-dd HH:mm",
].map(compileFormat);

const FORMATS_WITHOUT_YEAR = [
  "MMM d h:mm a",
  "MMM d, h:mm a",
  "MMMM d h:mm a",
  "MMMM d, h:mm a",
  "E, MMM d h:mm a",
  "E, MMM d, h:mm a",
  "M/d h:mm a",
].map(compileFormat);

function expandTwoDigitYear(y) {
  const start = new Date().getFullYear() - 80;
  let full = Math.floor(start / 100) * 100 + y;
  if (full < start) full += 100;
  return full;
}

function localDate(y, mo, d, h, mi, s, ms) {
  const base = new Date(2000, 0, 1, 0, 0, 0, 0);
  base.setFullYear(y, mo - 1, d);
  base.setHours(h, mi, s, ms);
  const same = (x) =>
    x.getFullYear() === y && x.getMonth() === mo - 1 && x.getDate() === d &&
    x.getHours() === h && x.getMinutes() === mi && x.getSeconds() === s;
  // A wall time that does not exist (DST gap) or an out-of-range day fails.
  if (!same(base)) return null;
  // Repeated wall time (DST end): JS picks the first; ICU's default picks the
  // last (UCAL_WALLTIME_LAST, unverified), so look one shift later.
  for (const shift of [3_600_000, 1_800_000]) {
    const later = new Date(base.getTime() + shift);
    if (same(later)) return later;
  }
  return base;
}

function formatToDate(fmt, text, yearDefault) {
  const m = fmt.re.exec(text);
  if (!m) return null;
  const v = {};
  fmt.fields.forEach((name, i) => { v[name] = m[i + 1]; });
  const num = (k) => Number(v[k]);

  let year = yearDefault;
  if (v.yyyy !== undefined) year = num("yyyy");
  if (v.yy !== undefined) year = v.yy.length === 2 ? expandTwoDigitYear(num("yy")) : num("yy");

  const name = v.mon?.toLowerCase();
  const month = name !== undefined
    ? MONTHS.findIndex((n) => n === name || n.slice(0, 3) === name) + 1
    : num("M");
  const day = num("d");

  let hour;
  if (v.H !== undefined) {
    hour = num("H");
    if (hour > 23) return null;
  } else {
    const h12 = num("h");
    if (h12 < 1 || h12 > 12) return null;
    hour = (h12 % 12) + (v.a.toLowerCase() === "pm" ? 12 : 0);
  }
  const minute = num("m");
  const second = v.s !== undefined ? num("s") : 0;
  if (minute > 59 || second > 59 || month < 1 || month > 12) return null;
  // SSS: the fraction of a second, whatever the digit count.
  const ms = v.S !== undefined ? Math.floor(Number(`0.${v.S}`) * 1000) : 0;

  if (v.tz === undefined) return localDate(year, month, day, hour, minute, second, ms);

  let offsetMs = 0;
  if (v.tz !== "Z" && v.tz !== "z") {
    const sign = v.tz[0] === "-" ? -1 : 1;
    const digits = v.tz.slice(1).replace(":", "");
    offsetMs = sign * (Number(digits.slice(0, 2)) * 60 + Number(digits.slice(2))) * 60_000;
  }
  const utc = new Date(0);
  utc.setUTCFullYear(year, month - 1, day);
  utc.setUTCHours(hour, minute, second, ms);
  if (utc.getUTCFullYear() !== year || utc.getUTCMonth() !== month - 1 || utc.getUTCDate() !== day) return null;
  return new Date(utc.getTime() - offsetMs);
}

function parseWith(raw, formats, yearDefault) {
  for (const fmt of formats) {
    const d = formatToDate(fmt, raw, yearDefault);
    if (d) return d;
  }
  return null;
}

// L687-708. Hazard #13: the comment says the window is (reference - 12 months,
// reference + grace], but the lower bound is (reference + 45 days) - 1 year,
// 45 days later than the comment claims. The code is what is ported.
function normalizeYear(date, referenceDate) {
  const referenceYear = referenceDate.getFullYear();
  const month = date.getMonth();
  const dayOfMonth = date.getDate();
  const h = date.getHours();
  const mi = date.getMinutes();
  const s = date.getSeconds();
  const make = (y) => new Date(y, month, dayOfMonth, h, mi, s);

  const upper = new Date(referenceDate.getTime() + 45 * 86_400 * 1000);
  // Calendar.date(byAdding: .year, -1): same local fields, Feb 29 clamps to 28.
  const ly = upper.getFullYear() - 1;
  const dim = new Date(ly, upper.getMonth() + 1, 0).getDate();
  const lower = new Date(ly, upper.getMonth(), Math.min(upper.getDate(), dim),
    upper.getHours(), upper.getMinutes(), upper.getSeconds(), upper.getMilliseconds());

  let year = referenceYear;
  const candidate = make(referenceYear);
  if (candidate.getTime() > upper.getTime()) year = referenceYear - 1;
  else if (candidate.getTime() <= lower.getTime()) year = referenceYear + 1;
  return make(year);
}

// L402-454. Returns a Date or null.
export function parseDate(raw, referenceDate = new Date()) {
  let s = cleanText(raw);
  s = s.replace(compiled(String.raw`\b(due|late due|deadline|released?|date)\b:?`, "gi"), "");
  // Hazard #6. The alternation is not grouped, so `\b` binds only the first
  // and last alternatives: "EST" needs a boundary before it and "MDT" after
  // it; EDT, UTC, PST, PDT, CST, CDT and MST are removed from inside words
  // too (L405).
  s = s.replace(compiled(String.raw`\bEST|EDT|UTC|PST|PDT|CST|CDT|MST|MDT\b`, "gi"), "");
  s = s.replace(compiled(String.raw`\s+at\s+`, "gi"), " ");
  s = s.replace(compiled(String.raw`(\d)(am|pm)\b`, "gi"), "$1 $2");
  s = s.replaceAll(",", ", ");
  s = s.replace(compiled(String.raw`\s+`, "g"), " ");
  s = trimWhitespaceAndNewlines(s);

  // localizedCaseInsensitiveContains: a plain substring, so "piano due" is
  // "no due" too.
  if (s === "" || s.toLowerCase().includes("no due")) return null;

  const withYear = parseWith(s, FORMATS_WITH_YEAR, 1970);
  if (withYear) return withYear;
  const withoutYear = parseWith(s, FORMATS_WITHOUT_YEAR, 1970);
  if (withoutYear) return normalizeYear(withoutYear, referenceDate);
  return null;
}

// ---------------------------------------------------------------------------
// Score, completion, login (L532-556, 625-668, 373-378)
// ---------------------------------------------------------------------------

const BARE_SCORE = String.raw`^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\s*(?:points?|pts?)?$`;
const LABELLED_SCORE = String.raw`\b(?:score|grade)\b\s*:?\s*.{0,40}?(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\b`;

// Swift's Double(String) reads ASCII only; \d here is Unicode.
const toDouble = (s) => (/^[0-9]+(?:\.[0-9]+)?$/.test(s) ? Number(s) : null);

// Only the FIRST match per text is tried: if its numbers do not convert, the
// search moves to the next text, not the next match (L535-548).
function scoreFrom(src, text) {
  const g = matchAll(src, text)[0]?.groups;
  if (!g || g.length < 2) return null;
  const earned = toDouble(g[0]);
  const max = toDouble(g[1]);
  return earned === null || max === null ? null : { earned, max };
}

// Returns { earned, max } or null.
export function scoreValues(texts) {
  for (const text of texts) {
    const r = scoreFrom(BARE_SCORE, trimWhitespaceAndNewlines(text));
    if (r) return r;
  }
  for (const text of texts) {
    const r = scoreFrom(LABELLED_SCORE, text);
    if (r) return r;
  }
  return null;
}

const NEGATIVE = ["not submitted", "unsubmitted", "not graded", "ungraded",
  "no submission", "no submissions", "missing"];
const POSITIVE = ["view submission", "download submission", "submission history",
  "submission uploaded", "your submission", "submitted at", "submitted on",
  "submission time", "submitted", "resubmitted", "resubmit", "graded", "uploaded"];

// Hazard #10. Substring tests over a whole row (or page): a title containing
// "submitted", "graded", "uploaded" or "resubmit" and no negative word marks
// the row submitted. A negative word anywhere in that text wins over every
// positive one. Kept.
function isCompletedStatus(texts) {
  return texts.some((text) => {
    const normalized = text.toLowerCase().replace(compiled(String.raw`\s+`, "g"), " ");
    if (NEGATIVE.some((p) => normalized.includes(p))) return false;
    if (POSITIVE.some((p) => normalized.includes(p))) return true;
    // This one is not Swift's `matches`: no dot-matches-newline (L663-666).
    return compiled(
      `\\b(score|grade)\\b${NO_NL}{0,40}\\b\\d+(?:\\.\\d+)?\\s*/\\s*\\d+(?:\\.\\d+)?\\b`, "",
    ).test(normalized);
  });
}

export function isCompletedAssignmentPage(html) {
  return isCompletedStatus([cleanText(html)]);
}

export function isLoginPage(html) {
  const text = cleanText(html).toLowerCase();
  return text.includes("log in") && text.includes("gradescope") &&
    (text.includes("email") || text.includes("password") || text.includes("school credentials"));
}

// ---------------------------------------------------------------------------
// Assignments (L348-367, 456-516, 566-623)
// ---------------------------------------------------------------------------

// L380-400. With no <tr>, each assignment link opens a window that runs to the
// next link; the last one runs 1200 UTF-16 units past its own link.
function assignmentWindows(html) {
  const link = String.raw`<a\b[^>]*href\s*=\s*["'][^"']*/courses/\d+/assignments/\d+[^"']*["'][^>]*>.*?</a>`;
  const found = matchAll(link, html);
  if (found.length === 0) return [html];
  return found.map((m, i) => {
    const end = i + 1 < found.length ? found[i + 1].index : Math.min(html.length, m.end + 1200);
    return html.slice(m.index, end);
  });
}

const DATE_SUFFIX = String.raw`(?:\s+(?:status|submitted|graded|released|late due)\b|$)`;

function trimDateCandidate(raw) {
  return trimWhitespaceAndNewlines(raw.replace(
    compiled(`\\s+(?:status|submitted|not submitted|graded|ungraded|released|late due|points?|score)\\b${NO_NL}*$`, "gi"),
    "",
  ));
}

// L566-613. Precedence: the dedicated due-date <time>, the cells right to
// left, other date attributes, then "Due:"-style text.
function dueDate(row, cells, referenceDate) {
  const chart = firstGroup(String.raw`submissionTimeChart--dueDate[^>]*\bdatetime\s*=\s*["']([^"']+)["']`, row);
  if (chart !== undefined) {
    const due = parseDate(chart, referenceDate);
    if (due) return due;
  }

  for (let i = cells.length - 1; i >= 0; i--) {
    const due = parseDate(cells[i], referenceDate);
    if (due) return due;
  }

  const attributes = [
    String.raw`\bdatetime\s*=\s*["']([^"']+)["']`,
    String.raw`\bdata-due-date\s*=\s*["']([^"']+)["']`,
    String.raw`\bdata-deadline\s*=\s*["']([^"']+)["']`,
    String.raw`\btitle\s*=\s*["']([^"']*(?:due|deadline)[^"']*)["']`,
    String.raw`\baria-label\s*=\s*["']([^"']*(?:due|deadline)[^"']*)["']`,
  ];
  for (const pattern of attributes) {
    for (const { groups } of matchAll(pattern, row)) {
      if (groups.length === 0) continue;
      const due = parseDate(groups[0], referenceDate);
      if (due) return due;
    }
  }

  const text = cleanText(row);
  const patterns = [
    String.raw`\bdue date:?\s*(.+?)${DATE_SUFFIX}`,
    String.raw`\bdue:?\s*(.+?)${DATE_SUFFIX}`,
    String.raw`\bdeadline:?\s*(.+?)${DATE_SUFFIX}`,
  ];
  for (const pattern of patterns) {
    for (const { groups } of matchAll(pattern, text)) {
      if (groups.length === 0) continue;
      const due = parseDate(trimDateCandidate(groups[0]), referenceDate);
      if (due) return due;
    }
  }
  return null;
}

function parseAssignmentRow(row, courseName, courseURL, term, referenceDate) {
  const course = courseIDFromURL(courseURL);
  let assignmentID = null;
  let title = null;
  let url = null;

  // Submitted assignments link their name to the submission page.
  const linkPattern = String.raw`<a\b[^>]*href\s*=\s*["']([^"']*/courses/(\d+)/assignments/(\d+)[^"']*)["'][^>]*>(.*?)</a>`;
  const link = matchAll(linkPattern, row)[0]?.groups;
  if (link && link.length >= 4) {
    assignmentID = link[2];
    url = resolveURL(link[0], courseURL);
    const linkTitle = cleanText(link[3]);
    if (linkTitle !== "") title = linkTitle;
  }

  // Unsubmitted assignments render a "submit" button with data attributes and
  // no href (L477-490).
  if (assignmentID === null) {
    const id = firstGroup(String.raw`\bdata-assignment-id\s*=\s*["'](\d+)["']`, row);
    if (id !== undefined) assignmentID = id;
  }
  if (title === null || title === "") {
    const t = firstGroup(String.raw`\bdata-assignment-title\s*=\s*["']([^"']+)["']`, row);
    if (t !== undefined) {
      title = cleanText(t);
    } else {
      const th = firstGroup(String.raw`<th\b[^>]*>(.*?)</th>`, row);
      if (th !== undefined) title = cleanText(th);
    }
  }

  if (assignmentID === null || title === null || title === "") return null;

  // Hazard #8. The host is hard-coded; the baseURL given to the client is not
  // consulted (L494-496).
  if (url === null && course !== null) {
    url = resolveURL(`https://www.gradescope.com/courses/${course}/assignments/${assignmentID}`);
  }

  const cells = matchAll(String.raw`<t[dh]\b[^>]*>(.*?)</t[dh]>`, row).map((m) => cleanText(m.groups[0]));
  const dueAt = dueDate(row, cells, referenceDate);
  const rowText = cleanText(row);
  const submitted = isCompletedStatus(cells) || isCompletedStatus([rowText]);
  const score = scoreValues([...cells, rowText]);

  return makeAssignment({
    source: Source.GRADESCOPE,
    sourceID: `course-${course ?? "0"}-assignment-${assignmentID}`,
    kind: Kind.ASSIGNMENT,
    course: courseName,
    title,
    dueAt,
    url,
    term,
    submitted,
    scoreEarned: score ? score.earned : null,
    scoreMax: score ? score.max : null,
  });
}

// L348-367. `courseURL` is an absolute URL string.
export function assignments(html, { courseName, courseURL, term = null, referenceDate = new Date() }) {
  const rows = matchAll(String.raw`<tr\b[^>]*>(.*?)</tr>`, html).map((m) => m.groups[0]);
  const candidates = rows.length === 0 ? assignmentWindows(html) : rows;
  const out = [];
  for (const row of candidates) {
    const a = parseAssignmentRow(row, courseName, courseURL, term, referenceDate);
    if (a) out.push(a);
  }
  return out;
}

// ---------------------------------------------------------------------------
// The pure decisions of GradescopeClient (L3-150), fetch-free
// ---------------------------------------------------------------------------

// Only these failures prove the saved session is dead (L27-36). `error` is
// { kind: "http", status } | { kind: "notHTTP" | "invalidResponseEncoding" | "notLoggedIn" }.
export function requiresReauthentication(error) {
  switch (error.kind) {
    case "notLoggedIn": return true;
    case "http": return error.status === 401 || error.status === 403;
    default: return false;
  }
}

// L58-65. When the account page lists no courses its own HTML is parsed as an
// assignment list. Hazard #11: no fallback filter on this path, so undated
// items are kept.
export function accountPageAssignments(accountHTML, baseURL, referenceDate = new Date()) {
  return assignments(accountHTML, { courseName: "Gradescope", courseURL: baseURL, referenceDate });
}

// L67-80: one course page, parsed and filtered. A course page that fails to
// fetch aborts the whole Swift fetch (hazard #9); that is the caller's concern.
export function courseAssignments(html, course, isFallback, referenceDate = new Date()) {
  return filterFallbackAssignments(
    assignments(html, { courseName: course.name, courseURL: course.url, term: course.term, referenceDate }),
    isFallback,
  );
}

// L88-100, L843-858: a detail page can only upgrade an unsubmitted assignment.
// `withSubmitted` rebuilds without linkedID, as Swift does.
export function refineWithDetailPage(assignment, detailHTML) {
  if (assignment.submitted || !isCompletedAssignmentPage(detailHTML)) return assignment;
  return makeAssignment({ ...assignment, submitted: true, linkedID: null });
}

// L64, L81, L147-149.
export function sortAssignments(list) {
  return [...list].sort((a, b) => (isOrderedByDueDate(a, b) ? -1 : isOrderedByDueDate(b, a) ? 1 : 0));
}
