// Pure request builders and response helpers for the Canvas REST calls the
// phone makes for course material. Ports of:
//   CanvasAPI/CanvasCourseContentClient.swift  (assignments, pages, tabs, CourseContentAPI)
//   CanvasAPI/CanvasCourseTab.swift            (tabs shape)
//   Canvas/CanvasAnnouncementsClient.swift     (announcementsURL, Link parsing)
//   Canvas/CanvasModulesClient.swift           (modules URL)
//   Syllabus/CanvasSyllabusClient.swift        (syllabus_body, syllabus pages, syllabus files URLs)
//   Knowledge/CourseKnowledgeCollector.swift   (which endpoints, the 200-day look-back)
// Nothing here fetches. The adapter fetches with `credentials: "include"`.

export const DEFAULT_BASE_URL = "https://canvas.upenn.edu";

// CanvasCourseContentClient.getAllPages and the other clients: stop following
// `Link: rel="next"` after 50 pages.
export const MAX_PAGES = 50;

// CourseKnowledgeCollector.announcementLookbackDays. "A semester is about 115
// days; 200 covers a course that started early or ran late."
export const ANNOUNCEMENT_LOOKBACK_DAYS = 200;

const DAY_MS = 86_400_000;

// ---------------------------------------------------------------- URLs

// URLComponents percent-encodes `[` and `]` in query items and leaves ':'
// alone (the announcements test pins `context_codes%5B%5D=` and a raw
// `T08:00:00Z`).
function encodeQueryPart(s) {
  return encodeURIComponent(s).replaceAll("%3A", ":");
}

function buildURL(baseURL, path, query = []) {
  const base = baseURL.replace(/\/+$/, "");
  let url = `${base}/api/v1/${path}`;
  if (query.length > 0) {
    url += "?" + query.map(([k, v]) => `${encodeQueryPart(k)}=${encodeQueryPart(v)}`).join("&");
  }
  return url;
}

// NSCharacterSet.urlPathAllowed: unreserved, sub-delims, ':', '@', '/'.
export function encodePathAllowed(s) {
  return encodeURIComponent(s).replace(/%(21|24|26|27|28|29|2A|2B|2C|3B|3D|3A|40|2F)/gi, (m, hex) =>
    String.fromCharCode(parseInt(hex, 16)),
  );
}

// CanvasCourseContentClient.assignments
export function assignmentsURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/assignments`, [
    ["per_page", "100"],
    ["include[]", "submission"],
    ["order_by", "due_at"],
  ]);
}

// CanvasCourseContentClient.pages, the listing (never includes bodies).
export function pagesListURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/pages`, [
    ["per_page", "100"],
    ["sort", "updated_at"],
    ["order", "desc"],
  ]);
}

// One page's body: GET /courses/:id/pages/:slug. The slug is percent-encoded
// with urlPathAllowed, as `addingPercentEncoding(withAllowedCharacters:
// .urlPathAllowed)` does in Swift.
export function pageBodyURL(courseID, slug, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/pages/${encodePathAllowed(slug)}`);
}

// CanvasCourseContentClient.tabs
export function tabsURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/tabs`, [
    ["include[]", "external"],
    ["per_page", "100"],
  ]);
}

// CanvasModulesClient.fetchAllModulePages. `content_details` is the only
// carrier of an item's due_at and is returned solely when asked for.
export function modulesURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/modules`, [
    ["include[]", "items"],
    ["include[]", "content_details"],
    ["per_page", "100"],
  ]);
}

// CanvasSyllabusClient.syllabusBody
export function syllabusBodyURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}`, [["include[]", "syllabus_body"]]);
}

// CanvasSyllabusClient.syllabusPages. The phone then fetches the first three
// hits' bodies (SYLLABUS_PAGE_HITS).
export function syllabusPagesSearchURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/pages`, [
    ["search_term", "syllabus"],
    ["per_page", "10"],
  ]);
}
export const SYLLABUS_PAGE_HITS = 3;

// CanvasSyllabusClient.syllabusFiles (the phone downloads up to three PDFs).
// The extension has no PDF parser in this layer; the URL is here so the file
// step can reuse it.
export function syllabusFilesURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return buildURL(baseURL, `courses/${courseID}/files`, [
    ["search_term", "syllabus"],
    ["per_page", "10"],
  ]);
}

// "2027-01-15T08:00:00Z": internet date-time, whole seconds, UTC. JS's
// toISOString always carries milliseconds, so they are cut.
function isoWholeSeconds(date) {
  return new Date(date).toISOString().replace(/\.\d{3}Z$/, "Z");
}

// CanvasAnnouncementsClient.announcementsURL, byte for byte (the Swift test
// pins the literal). With `until` omitted it is the request the phone's
// course-material collector sends, which is the trap: Canvas defaults
// `end_date` to 28 days after `start_date`.
export function announcementsURL(courseIDs, since, until, { baseURL = DEFAULT_BASE_URL } = {}) {
  const query = courseIDs.map((id) => ["context_codes[]", `course_${id}`]);
  query.push(["start_date", isoWholeSeconds(since)]);
  if (until !== undefined && until !== null) query.push(["end_date", isoWholeSeconds(until)]);
  query.push(["per_page", "100"]);
  return buildURL(baseURL, "announcements", query);
}

// The extension's announcement window (CLAUDE.md, the announcements-window
// trap): `lookbackDays` back through one day after `now`, always with both
// ends sent. `until` is exactly what the phone's own `announcementFetchWindow`
// uses (`now + 24h`); `since` is the collector's 200 days.
export function announcementWindow(now, { lookbackDays = ANNOUNCEMENT_LOOKBACK_DAYS } = {}) {
  const t = new Date(now).getTime();
  return { since: new Date(t - lookbackDays * DAY_MS), until: new Date(t + DAY_MS) };
}

// The extension's announcements request: never without `end_date`.
export function announcementsRequestURL(courseIDs, now, { baseURL = DEFAULT_BASE_URL, lookbackDays = ANNOUNCEMENT_LOOKBACK_DAYS } = {}) {
  const { since, until } = announcementWindow(now, { lookbackDays });
  return announcementsURL(courseIDs, since, until, { baseURL });
}

// ------------------------------------------------------------- responses

// CourseContentAPI.stripAntiHijackPrefix / CanvasAnnouncementsClient.stripXSSIPrefix:
// only at the very start, exactly `while(1);`.
export function stripAntiHijackPrefix(text) {
  return text.startsWith("while(1);") ? text.slice("while(1);".length) : text;
}

// Canvas answers a logged-out API call with HTTP 200 and its HTML login page.
// CanvasAnnouncementsClient.looksLikeHTML.
export function looksLikeHTML(text) {
  const m = /[^ \t\n\r]/.exec(text);
  return m !== null && m[0] === "<";
}

// Strip the prefix and parse. Throws SyntaxError on garbage.
export function parseCanvasJSON(text) {
  return JSON.parse(stripAntiHijackPrefix(text));
}

// CourseContentAPI.parseDate: ISO 8601 internet date-time, with or without
// fractional seconds. Returns a Date or null.
export function parseDate(raw) {
  if (typeof raw !== "string") return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})$/.exec(raw);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, frac, zone] = m;
  const year = Number(y), month = Number(mo), day = Number(d);
  const hour = Number(h), minute = Number(mi), second = Number(s);
  if (month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59) return null;
  const ms = frac ? Number(frac.slice(0, 3).padEnd(3, "0")) : 0;
  let offsetMinutes = 0;
  if (zone !== "Z") {
    const sign = zone[0] === "-" ? -1 : 1;
    const digits = zone.slice(1).replace(":", "");
    offsetMinutes = sign * (Number(digits.slice(0, 2)) * 60 + Number(digits.slice(2)));
  }
  const utc = Date.UTC(year, month - 1, day, hour, minute, second, ms);
  const check = new Date(utc);
  if (check.getUTCDate() !== day || check.getUTCMonth() !== month - 1) return null; // Feb 31
  return new Date(utc - offsetMinutes * 60_000);
}

export class UnsafePaginationURLError extends Error {
  constructor() {
    super("Canvas pointed pagination at an unexpected host.");
    this.name = "UnsafePaginationURLError";
  }
}

function parseURL(s) {
  try {
    return new URL(s);
  } catch {
    return null;
  }
}

// The candidate `rel="next"` URL of a Link header, with no host check
// (CanvasAnnouncementsClient.nextPageURL(fromLinkHeader:)).
export function parseNextLink(header) {
  if (header === null || header === undefined) return null;
  for (const part of header.split(",")) {
    const segments = part.split(";").map((p) => p.replace(/^[ \t]+|[ \t]+$/g, ""));
    const first = segments[0];
    if (!first || !first.startsWith("<") || !first.endsWith(">")) continue;
    const isNext = segments.slice(1).some((p) => p.replaceAll(" ", "") === 'rel="next"');
    const url = first.slice(1, -1);
    if (isNext && parseURL(url) !== null) return url;
  }
  return null;
}

// CanvasAnnouncementsClient.isTrustedNextPageURL: https and the same host.
export function isTrustedNextPageURL(url, baseURL = DEFAULT_BASE_URL) {
  const u = parseURL(url);
  const b = parseURL(baseURL);
  if (!u || !b) return false;
  return u.protocol === "https:" && u.hostname.toLowerCase() === b.hostname.toLowerCase();
}

// CourseContentAPI.nextPageURL(fromLinkHeader:sameHostAs:): the `rel="next"`
// URL, or null; throws UnsafePaginationURLError rather than hand the browser
// session to another host. Pieces split with `.split(separator:)` in Swift,
// which drops empty pieces; a header is never meaningfully empty-pieced.
export function nextPageURL(header, baseURL = DEFAULT_BASE_URL) {
  if (header === null || header === undefined) return null;
  for (const part of header.split(",")) {
    if (part === "") continue;
    const pieces = part.split(";").filter((p) => p !== "").map((p) => p.replace(/^[ \t]+|[ \t]+$/g, ""));
    if (pieces.length < 2) continue;
    if (!pieces.slice(1).some((p) => p.replaceAll(" ", "") === 'rel="next"')) continue;
    if (!pieces[0].startsWith("<") || !pieces[0].endsWith(">")) continue;
    const url = pieces[0].slice(1, -1);
    if (parseURL(url) === null) continue;
    if (!isTrustedNextPageURL(url, baseURL)) throw new UnsafePaginationURLError();
    return url;
  }
  return null;
}
