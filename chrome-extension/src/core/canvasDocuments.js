// Pure builders from Canvas REST JSON to the `CourseDocumentWire` objects the
// phone uploads (backend/PROTOCOL.md, Wire types). Ports of:
//   CanvasAPI/CanvasCourseContentClient.swift  CourseDocumentBuilder, DateText,
//                                              CourseContentAssignment/Page DTOs
//   Canvas/CanvasAnnouncementsClient.swift     decodeAnnouncements, plainText(fromHTML:)
//   Canvas/CanvasModulesClient.swift           moduleItems(fromPages:)
//   Syllabus/CanvasSyllabusClient.swift        the candidate shapes
//   Syllabus/SyllabusTextExtractor.swift       text(fromHTML:)
//   Knowledge/CourseKnowledgeCollector.swift   the 400-link dedupe, the page-body cap
// Same id, same title, same text, same contentHash as the phone for the same
// source, or the two clients fight over the pool.
//
// A "course" argument is `{ courseID, code, url? }` (CourseSummary). Dates in
// the output are ISO strings with milliseconds ("2026-09-07T14:03:00.000Z"),
// which is what BackendJSON.encoder() writes. Optional fields that are absent
// are omitted, as Swift's synthesized Codable omits nil.
import { documentID, documentContentHash, fnv1a } from "./contentHash.js";
import { trimWhitespaceAndNewlines } from "./text.js";
import * as html from "./html.js";
import { parseDate } from "./canvasApi.js";

// ------------------------------------------------------------------ wire

function toDate(value) {
  if (value === undefined || value === null) return null;
  if (value instanceof Date) return value;
  if (typeof value === "number") return new Date(value);
  const parsed = parseDate(value);
  if (parsed === null) throw new TypeError(`not a date: ${value}`);
  return parsed;
}

function isoOrUndefined(value) {
  const d = toDate(value);
  return d === null ? undefined : d.toISOString();
}

// CourseDocument.init + CourseDocumentWire.init(document:). Keys in sorted
// order, as BackendJSON.encoder() (.sortedKeys) writes them. `submitted` is
// not on the wire.
export function courseDocumentWire({
  courseID, course, kind, sourceID, title, url, text,
  updatedAt, fetchedAt = new Date(), dueAt, pointsPossible,
}) {
  const wire = {
    contentHash: documentContentHash(title, text),
    course,
    courseID,
    dueAt: isoOrUndefined(dueAt),
    fetchedAt: toDate(fetchedAt).toISOString(),
    id: documentID(kind, courseID, sourceID),
    kind,
    pointsPossible: pointsPossible ?? undefined,
    sourceID,
    text,
    title,
    updatedAt: isoOrUndefined(updatedAt),
    url: url ?? undefined,
  };
  for (const key of Object.keys(wire)) if (wire[key] === undefined) delete wire[key];
  return wire;
}

// ------------------------------------------------------------- DateText

// DateText.long / short / trimmed (CanvasCourseContentClient.swift:417-444).
// The Swift formats in Calendar.current's zone, so the text of an assignment
// ("Due: Thu, Sep 17 at 11:59 PM") depends on the device zone. Both clients
// are used by the same student, so the extension formats in the runtime's
// zone by default; pass `timeZone` to pin one ("America/New_York" in tests).
function zonedParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const get = (type) => parts.find((p) => p.type === type).value;
  const hour24 = Number(get("hour")) % 24;
  return {
    weekday: get("weekday"),
    month: get("month"),
    day: get("day"),
    clock: `${hour24 % 12 === 0 ? 12 : hour24 % 12}:${get("minute")} ${hour24 < 12 ? "AM" : "PM"}`,
  };
}

// "EEE, MMM d 'at' h:mm a"
export function dateTextLong(date, { timeZone } = {}) {
  const p = zonedParts(toDate(date), timeZone);
  return `${p.weekday}, ${p.month} ${p.day} at ${p.clock}`;
}

// "EEE MMM d, h:mm a"
export function dateTextShort(date, { timeZone } = {}) {
  const p = zonedParts(toDate(date), timeZone);
  return `${p.weekday} ${p.month} ${p.day}, ${p.clock}`;
}

// `value.rounded() == value ? String(Int(value)) : String(value)`: 100.0 is
// "100", 12.5 is "12.5". JavaScript's String(number) already prints both so.
export function dateTextTrimmed(value) {
  return String(value);
}

// ------------------------------------------------------ strict DTO decoding

// Swift's Decodable fails the whole page on one field of the wrong type. A
// failure here throws, and the caller treats it as the endpoint failing.
export class CanvasDecodeError extends Error {
  constructor(detail) {
    super(`Canvas returned data the app could not read: ${detail}`);
    this.name = "CanvasDecodeError";
  }
}

function isObject(v) {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function reqInt(o, key) {
  if (!Number.isSafeInteger(o[key])) throw new CanvasDecodeError(`${key} is not an integer`);
  return o[key];
}
function reqString(o, key) {
  if (typeof o[key] !== "string") throw new CanvasDecodeError(`${key} is not a string`);
  return o[key];
}
function optString(o, key) {
  const v = o[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new CanvasDecodeError(`${key} is not a string`);
  return v;
}
// URL?: `URL(string: "")` is nil, which fails the decode.
function optURL(o, key) {
  const v = optString(o, key);
  if (v === null) return null;
  if (v === "") throw new CanvasDecodeError(`${key} is not a URL`);
  return v;
}
function optNumber(o, key) {
  const v = o[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "number") throw new CanvasDecodeError(`${key} is not a number`);
  return v;
}
function optBool(o, key) {
  const v = o[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "boolean") throw new CanvasDecodeError(`${key} is not a boolean`);
  return v;
}
// CourseContentAPI.decoder(): a date string that is neither shape throws.
function optDate(o, key) {
  const v = optString(o, key);
  if (v === null) return null;
  const d = parseDate(v);
  if (d === null) throw new CanvasDecodeError(`Unrecognized date ${v}`);
  return d;
}
function reqArray(json) {
  if (!Array.isArray(json)) throw new CanvasDecodeError("expected an array");
  return json;
}

// CourseContentSubmission
function decodeSubmission(raw) {
  if (raw === undefined || raw === null) return null;
  if (!isObject(raw)) throw new CanvasDecodeError("submission is not an object");
  const workflowState = optString(raw, "workflow_state");
  const submittedAt = optDate(raw, "submitted_at");
  // CourseContentSubmission.isSubmitted
  const isSubmitted =
    submittedAt !== null || ["submitted", "graded", "pending_review"].includes(workflowState);
  return { workflowState, submittedAt, isSubmitted };
}

// CourseContentAssignment: one element of GET /courses/:id/assignments.
export function decodeAssignment(raw) {
  if (!isObject(raw)) throw new CanvasDecodeError("assignment is not an object");
  return {
    id: reqInt(raw, "id"),
    name: reqString(raw, "name"),
    description: optString(raw, "description"),
    dueAt: optDate(raw, "due_at"),
    htmlURL: optURL(raw, "html_url"),
    pointsPossible: optNumber(raw, "points_possible"),
    updatedAt: optDate(raw, "updated_at"),
    submission: decodeSubmission(raw.submission),
  };
}
export function decodeAssignments(json) {
  return reqArray(json).map(decodeAssignment);
}

// CourseContentPage: an element of the pages listing, or a single page.
export function decodePage(raw) {
  if (!isObject(raw)) throw new CanvasDecodeError("page is not an object");
  return {
    url: reqString(raw, "url"),
    title: reqString(raw, "title"),
    body: optString(raw, "body"),
    htmlURL: optURL(raw, "html_url"),
    updatedAt: optDate(raw, "updated_at"),
    published: optBool(raw, "published"),
  };
}
export function decodePages(json) {
  return reqArray(json).map(decodePage);
}

// ----------------------------------------------------------- assignments

// CourseDocumentBuilder.assignment
export function assignmentDocument(assignment, course, { now = new Date(), timeZone } = {}) {
  const lines = [];
  if (assignment.dueAt) {
    lines.push(`Due: ${dateTextLong(assignment.dueAt, { timeZone })}`);
  } else {
    lines.push("Due: no due date");
  }
  if (assignment.pointsPossible !== null) {
    lines.push(`Points: ${dateTextTrimmed(assignment.pointsPossible)}`);
  }
  if (assignment.submission) {
    lines.push(assignment.submission.isSubmitted ? "Status: submitted" : "Status: not submitted");
  }
  const description = html.plainText(assignment.description ?? "");
  if (description !== "") lines.push(description);

  return courseDocumentWire({
    courseID: course.courseID,
    course: course.code,
    kind: "assignment",
    sourceID: String(assignment.id),
    title: assignment.name,
    url: assignment.htmlURL,
    text: lines.join("\n"),
    updatedAt: assignment.updatedAt,
    fetchedAt: now,
    dueAt: assignment.dueAt,
    pointsPossible: assignment.pointsPossible,
  });
}

// ----------------------------------------------------------------- pages

// CourseDocumentBuilder.page
export function pageDocument(page, course, { now = new Date() } = {}) {
  return courseDocumentWire({
    courseID: course.courseID,
    course: course.code,
    kind: "page",
    sourceID: page.url,
    title: page.title,
    url: page.htmlURL,
    text: html.plainText(page.body ?? ""),
    updatedAt: page.updatedAt,
    fetchedAt: now,
  });
}

// The phone fetches bodies for the first 40 listed pages
// (CanvasCourseContentClient.pages `maxBodies: Int = 40`, "a course with two
// hundred pages is a course packet, not a syllabus"). The extension does not
// limit: the default is Infinity. The phone's value is kept here so a caller
// can reproduce it.
export const PHONE_MAX_PAGE_BODIES = 40;

// The slugs whose bodies to fetch, from the listing (newest `updated_at`
// first). As in Swift the cap is applied to the listing BEFORE the
// unpublished filter, so a cap of N may yield fewer than N bodies. A page
// with `published: false` is skipped; `null`/absent counts as published.
export function pageSlugsToFetch(listing, { maxBodies = Infinity } = {}) {
  return listing.slice(0, maxBodies).filter((p) => p.published !== false).map((p) => p.url);
}

// -------------------------------------------------------------- syllabus

// SyllabusParser.normalizedText (Syllabus/SyllabusParser.swift:59)
export function syllabusNormalizedText(raw) {
  const s = raw
    .replaceAll("\r\n", "\n")
    .replaceAll("\r", "\n")
    .replaceAll(" ", " ")
    .replaceAll("–", "-")
    .replaceAll("—", "-")
    .replaceAll("’", "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n");
  return trimWhitespaceAndNewlines(s);
}

const SYLLABUS_ENTITIES = [
  ["&nbsp;", " "], ["&amp;", "&"], ["&lt;", "<"], ["&gt;", ">"],
  ["&quot;", '"'], ["&#39;", "'"], ["&rsquo;", "'"], ["&lsquo;", "'"],
  ["&ldquo;", '"'], ["&rdquo;", '"'], ["&ndash;", "-"], ["&mdash;", "-"],
  ["&percnt;", "%"], ["&ge;", "≥"],
];

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// SyllabusTextExtractor.text(fromHTML:). Note the entity pass is
// case-insensitive and decodes "&amp;" second, not last, so "&amp;lt;" ends up
// "<" here (unlike HTMLText); that is Swift's behaviour and is kept.
export function syllabusTextFromHTML(source) {
  let s = source;
  s = s.replace(/<script(?![\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}])[^>]*>[\s\S]*?<\/script>/giu, " ");
  s = s.replace(/<style(?![\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}])[^>]*>[\s\S]*?<\/style>/giu, " ");
  s = s.replace(/<!--[\s\S]*?-->/g, " ");
  s = s.replace(/<\/t[dh]>/gi, " \t ");
  s = s.replace(
    /<(br|\/tr|\/p|\/div|\/li|\/h[1-6]|\/table)(?![\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}])[^>]*>/giu,
    "\n",
  );
  s = s.replace(/<[^>]+>/g, " ");
  for (const [entity, replacement] of SYLLABUS_ENTITIES) {
    s = s.replace(new RegExp(escapeRegExp(entity), "gi"), () => replacement);
  }
  s = s.replace(/&#\p{Nd}+;/gu, " ");
  return syllabusNormalizedText(s);
}

// CanvasSyllabusClient.syllabusBody + findCandidates: the `syllabus_body` of
// GET /courses/:id?include[]=syllabus_body. Null when there is no text.
export function syllabusBodyCandidate(courseID, courseJSON) {
  const body = isObject(courseJSON) && typeof courseJSON.syllabus_body === "string" ? courseJSON.syllabus_body : "";
  if (body === "") return null;
  const text = syllabusTextFromHTML(body);
  if (text === "") return null;
  return {
    id: `syllabus-body-${courseID}`,
    source: "canvasSyllabusPage",
    name: "Course syllabus page",
    text,
    links: html.links(body),
  };
}

// CanvasSyllabusClient.syllabusPages: one hit of the `search_term=syllabus`
// listing (`hit`, for its slug and title) with its fetched body (`full`).
// The phone only looks at the first three hits (SYLLABUS_PAGE_HITS). Page
// candidates carry no links, as in Swift.
export function syllabusPageCandidate(hit, full) {
  const slug = isObject(hit) && typeof hit.url === "string" ? hit.url : null;
  if (slug === null) return null;
  const body = isObject(full) && typeof full.body === "string" ? full.body : "";
  if (body === "") return null;
  const text = syllabusTextFromHTML(body);
  if (text === "") return null;
  return {
    id: `page-${slug}`,
    source: "canvasPage",
    name: typeof hit.title === "string" ? hit.title : "Course page",
    text,
    links: [],
  };
}

// URL.appendingPathComponent
function appendPath(url, component) {
  return url.replace(/\/+$/, "") + "/" + component;
}

// CourseDocumentBuilder.syllabus. Null for blank text. Only the syllabus-body
// source gets a URL.
export function syllabusDocument(candidate, course, { now = new Date() } = {}) {
  const text = trimWhitespaceAndNewlines(candidate.text);
  if (text === "") return null;
  const url =
    candidate.source === "canvasSyllabusPage" && course.url
      ? appendPath(course.url, "assignments/syllabus")
      : undefined;
  return courseDocumentWire({
    courseID: course.courseID,
    course: course.code,
    kind: "syllabus",
    sourceID: candidate.id,
    title: candidate.name === "" ? `${course.code} syllabus` : candidate.name,
    url,
    text,
    fetchedAt: now,
  });
}

// --------------------------------------------------------- announcements

// CanvasAnnouncementsClient.plainText(fromHTML:). A different, smaller
// converter than HTMLText.plainText (no bullets, no entity set beyond six),
// and it is the one the phone uses for announcements.
export function announcementPlainText(source) {
  if (source === "") return "";
  let text = source;
  text = text.replace(
    new RegExp(String.raw`<br[\p{White_Space}]*/?>|</p[\p{White_Space}]*>|</div[\p{White_Space}]*>|</li[\p{White_Space}]*>`, "giu"),
    "\n",
  );
  text = text.replace(/<[^>]+>/g, "");
  for (const [entity, replacement] of [
    ["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'], ["&#39;", "'"], ["&nbsp;", " "], ["&amp;", "&"],
  ]) {
    text = text.replaceAll(entity, replacement);
  }
  text = text.replace(/\n{3,}/g, "\n\n");
  return trimWhitespaceAndNewlines(text);
}

// CanvasAnnouncementsClient.decodeAnnouncements: a page of
// GET /api/v1/announcements. An element that is not an object, has a field of
// the wrong type, no id, or a context_code that is not `course_<digits>` is
// dropped; the page survives. Throws if the page is not an array.
export function decodeAnnouncements(json) {
  if (!Array.isArray(json)) throw new CanvasDecodeError("announcements: expected an array");
  const out = [];
  for (const el of json) {
    if (!isObject(el)) continue;
    let dto;
    try {
      dto = {
        id: el.id === undefined || el.id === null ? null : reqInt(el, "id"),
        contextCode: optString(el, "context_code"),
        title: optString(el, "title"),
        message: optString(el, "message"),
        postedAt: optString(el, "posted_at"),
        htmlURL: optString(el, "html_url"),
      };
    } catch {
      continue;
    }
    if (dto.id === null) continue;
    if (dto.contextCode === null || !/^course_\p{N}+$/u.test(dto.contextCode)) continue;
    out.push({
      id: String(dto.id),
      courseID: dto.contextCode.slice("course_".length),
      title: dto.title ?? "",
      message: announcementPlainText(dto.message ?? ""),
      postedAt: dto.postedAt ? parseDate(dto.postedAt) : null,
      url: dto.htmlURL ? dto.htmlURL : null,
    });
  }
  return out;
}

// CourseDocumentBuilder.announcement
export function announcementDocument(announcement, course, { now = new Date(), timeZone } = {}) {
  const lines = [];
  if (announcement.postedAt) {
    lines.push(`Posted: ${dateTextLong(announcement.postedAt, { timeZone })}`);
  }
  const message = trimWhitespaceAndNewlines(announcement.message);
  if (message !== "") lines.push(message);
  return courseDocumentWire({
    courseID: course.courseID,
    course: course.code,
    kind: "announcement",
    sourceID: announcement.id,
    title: announcement.title,
    url: announcement.url,
    text: lines.join("\n"),
    updatedAt: announcement.postedAt,
    fetchedAt: now,
  });
}

// --------------------------------------------------------------- modules

// CanvasModulesClient.moduleItems(fromPages:): flat items from pages of
// GET /courses/:id/modules?include[]=items&include[]=content_details. A page
// that does not decode contributes nothing (Swift: `guard let ... try?`).
export function decodeModuleItems(pages) {
  const items = [];
  for (const page of pages) {
    let decoded;
    try {
      decoded = reqArray(page).map((module) => {
        if (!isObject(module)) throw new CanvasDecodeError("module is not an object");
        const name = optString(module, "name");
        const rawItems = module.items;
        if (rawItems !== undefined && rawItems !== null && !Array.isArray(rawItems)) {
          throw new CanvasDecodeError("items is not an array");
        }
        const mapped = (rawItems ?? []).map((item) => {
          if (!isObject(item)) throw new CanvasDecodeError("module item is not an object");
          const id = reqInt(item, "id");
          const title = reqString(item, "title");
          const type = reqString(item, "type");
          const contentID = item.content_id === undefined || item.content_id === null ? null : reqInt(item, "content_id");
          const details = item.content_details;
          if (details !== undefined && details !== null && !isObject(details)) {
            throw new CanvasDecodeError("content_details is not an object");
          }
          const dueRaw = details ? optString(details, "due_at") : null;
          const externalURL = optURL(item, "external_url");
          return { id, title, type, contentID, dueRaw, externalURL };
        });
        return { name, items: mapped };
      });
    } catch {
      continue;
    }
    for (const module of decoded) {
      for (const item of module.items) {
        if (item.type === "SubHeader") continue;
        items.push({
          id: String(item.id),
          title: item.title,
          // parseDate(""): empty is nil, not an error
          dueAt: item.dueRaw ? parseDate(item.dueRaw) : null,
          typeRaw: item.type,
          contentID: item.contentID === null ? null : String(item.contentID),
          moduleName: module.name,
          // Only an ExternalUrl item's external_url is a course-site candidate.
          externalURL: item.type === "ExternalUrl" ? item.externalURL : null,
        });
      }
    }
  }
  return items;
}

// CourseDocumentBuilder.modules: one document per module, grouped by module
// name in first-seen order, items without a module under "Modules".
export function moduleDocuments(items, course, { now = new Date(), timeZone } = {}) {
  const order = [];
  const grouped = new Map();
  for (const item of items) {
    const name = item.moduleName ?? "Modules";
    if (!grouped.has(name)) {
      order.push(name);
      grouped.set(name, []);
    }
    grouped.get(name).push(item);
  }
  return order.map((name) => {
    const lines = grouped.get(name).map((item) => {
      const due = item.dueAt ? ` · due ${dateTextShort(item.dueAt, { timeZone })}` : "";
      return `• ${item.title} (${item.typeRaw.toLowerCase()})${due}`;
    });
    return courseDocumentWire({
      courseID: course.courseID,
      course: course.code,
      kind: "module",
      sourceID: fnv1a(name),
      title: name,
      url: course.url ? appendPath(course.url, "modules") : undefined,
      text: lines.join("\n"),
      fetchedAt: now,
    });
  });
}

// ----------------------------------------------------------------- links

// CourseDocumentBuilder.links(from:). `origin` is "page", "assignment",
// "module" or "syllabus". Announcements are deliberately not scanned.
export function linksFromPage(page, course) {
  return html.links(page.body ?? "").map((l) => ({ courseID: course.courseID, href: l.href, text: l.text, origin: "page" }));
}
export function linksFromAssignment(assignment, course) {
  return html.links(assignment.description ?? "").map((l) => ({ courseID: course.courseID, href: l.href, text: l.text, origin: "assignment" }));
}
export function linksFromModuleItems(items, course) {
  return items
    .filter((item) => item.externalURL)
    .map((item) => ({ courseID: course.courseID, href: item.externalURL, text: item.title, origin: "module" }));
}
export function linksFromSyllabusCandidate(candidate, course) {
  return candidate.links.map((l) => ({ courseID: course.courseID, href: l.href, text: l.text, origin: "syllabus" }));
}

// CourseKnowledgeCollector.run: de-duplicated by (courseID, href), first
// kept, capped at 400 so one link-heavy course cannot balloon the upload
// (the server accepts at most 400 per call, each href at most 2048 chars).
export function dedupeLinks(links, { cap = 400 } = {}) {
  const seen = new Set();
  const out = [];
  for (const link of links) {
    const key = `${link.courseID}|${link.href}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(link);
    if (out.length === cap) break;
  }
  return out;
}

// ----------------------------------------------------------------- files

// The server's own PDF crawl cap (_shared/crawl.ts PDF_MAX_TEXT_CHARS).
export const FILE_TEXT_MAX_CHARS = 60_000;

// A `file` document (new kind, not on the phone): text extracted by the
// extension from a Canvas File. `course` is the display code ("CIS 2400");
// a `{ code }` object is accepted too. `text` is cut to 60,000 UTF-16 code
// units (the server's `.slice`), without leaving half a surrogate pair.
export function fileDocument({ courseID, course, fileID, displayName, url, updatedAt, text, fetchedAt = new Date() }) {
  let body = text;
  if (body.length > FILE_TEXT_MAX_CHARS) {
    body = body.slice(0, FILE_TEXT_MAX_CHARS);
    const last = body.charCodeAt(body.length - 1);
    if (last >= 0xd800 && last <= 0xdbff) body = body.slice(0, -1);
  }
  return courseDocumentWire({
    courseID,
    course: typeof course === "string" ? course : course.code,
    kind: "file",
    sourceID: String(fileID),
    title: displayName,
    url,
    text: body,
    updatedAt,
    fetchedAt,
  });
}
