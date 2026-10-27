// The course-material collector: reads Canvas (and Ed) with the browser's own
// session, builds the same documents the phone builds, and shares them through
// the `sync` exchange (backend/PROTOCOL.md). Mirrors
// Knowledge/CourseKnowledgeCollector.swift, Ed/EdIngestion.swift and the sync
// driver in AppState+CourseKnowledge.swift.
//
// Rules that hold throughout:
//   * Requests are sequential (one in flight) and spaced (250 ms by default),
//     so Canvas is never hammered. A 429 / rate-limit answer stops the run.
//   * No cookie is read; Canvas gets `credentials: "include"`, Ed gets its
//     token in `x-token` and no cookies.
//   * A summary carries counts and words only. Never a title, id, body or URL.
//     (`collected` itself carries documents; it is for `syncCourseMaterial`,
//     not for display or logs.)
//   * Never retries in a loop. `notPaired` and `quota` stop the run.
import {
  DEFAULT_BASE_URL, MAX_PAGES, assignmentsURL, pagesListURL, pageBodyURL, modulesURL,
  syllabusBodyURL, announcementsRequestURL, stripAntiHijackPrefix, looksLikeHTML, nextPageURL,
  canvasFileIDsFromLinks,
} from "../core/canvasApi.js";
import {
  decodeAssignments, assignmentDocument, linksFromAssignment,
  decodePages, decodePage, pageSlugsToFetch, pageDocument, linksFromPage,
  syllabusBodyCandidate, syllabusDocument, linksFromSyllabusCandidate,
  decodeAnnouncements, announcementDocument,
  decodeModuleItems, moduleDocuments, linksFromModuleItems, dedupeLinks,
} from "../core/canvasDocuments.js";
import { collectFiles } from "./files.js";
import * as edCore from "../core/ed.js";
import { match as matchEdCourses } from "../core/edMatch.js";
import { parse as parseCourseCode } from "../core/courseCode.js";
import { uploads, uploadBatches, fullyFetchedCourseIDs } from "../core/syncPlan.js";

export const DEFAULT_DELAY_MS = 250;
export const ED_HOST_ORIGIN = "https://edstem.org";
export const ED_TOKEN_KEY = "edTokenV1";
// Every document kind the extension can decode (PROTOCOL.md `acceptsKinds`).
export const ACCEPTED_KINDS = ["home", "syllabus", "assignment", "announcement", "module", "page", "website", "ed", "file"];
// Kinds a fully-fetched Canvas course replaces wholesale (the Canvas answer is
// the truth for these). `syllabus` is not here: the phone also files syllabus
// PDFs under it, which this collector does not read. `home`, `website`, `file`
// and anything unknown are never replaced.
const CANVAS_REPLACED_KINDS = new Set(["assignment", "announcement", "module", "page"]);

class CollectError extends Error {
  constructor(kind) {
    super(kind);
    this.kind = kind; // out | forbidden | rateLimited | network | http | decode | truncated | unsafeLink
  }
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ------------------------------------------------------------- requests

function makeContext({ fetch: fetchFn, limits = {}, sleep }) {
  const delayMs = limits.delayMs ?? DEFAULT_DELAY_MS;
  const doSleep = sleep ?? limits.sleep ?? defaultSleep;
  let first = true;
  return {
    fetch: fetchFn,
    async pace() {
      if (!first && delayMs > 0) await doSleep(delayMs);
      first = false;
    },
    requests: 0,
    sessionCheck: null,
    // Is the Canvas session alive? One GET of /users/self per run, memoised on
    // the context (the promise itself, so concurrent callers share it).
    confirmSession() {
      if (!this.sessionCheck) this.sessionCheck = checkSession(this);
      return this.sessionCheck;
    },
  };
}

const CANVAS_HOST = new URL(DEFAULT_BASE_URL).host;

function hostOf(url) {
  try { return new URL(url).host; } catch { return ""; }
}

async function safeText(res) {
  try { return await res.text(); } catch { return ""; }
}

// Is the Canvas session alive? Canvas answers 401 for a forbidden resource as
// well as for a dead session: a course that hides its Files, Modules or Pages
// answers 401 {"status":"unauthorized", "user not authorized to perform that
// action"} while the session is fine (a dead one answers "unauthenticated", or
// redirects to the PennKey login, or serves HTML). The wrong fix, and what
// this code did first (as the phone's CanvasCourseContentClient still does;
// it gets away with it only because it never asks for Files), is to read every
// 401 as "signed out": one course with a hidden Files tab then discarded the
// whole run for every course. So a 401/403 is judged by asking Canvas once who
// the student is. Only a clean JSON 200 from the Canvas host counts as alive.
async function checkSession(ctx) {
  await ctx.pace();
  ctx.requests += 1;
  try {
    const res = await ctx.fetch(`${DEFAULT_BASE_URL}/api/v1/users/self`, { credentials: "include", redirect: "follow", headers: { Accept: "application/json" } });
    if (typeof res.url === "string" && res.url !== "" && hostOf(res.url) !== CANVAS_HOST) return false;
    if (res.status !== 200) return false;
    const text = stripAntiHijackPrefix(await safeText(res));
    if (looksLikeHTML(text)) return false;
    return isObject(JSON.parse(text));
  } catch {
    return false;
  }
}

// One Canvas GET. Throws CollectError: "out" for a sign-in page (a redirect to
// another host, or HTML) or a 401/403 when the session check says the session
// is dead, "forbidden" for a 401/403 while the session is alive (that endpoint
// is closed to this student; nothing else is wrong), "rateLimited", or an
// endpoint failure kind. Returns { json, link }.
async function canvasGet(ctx, url) {
  await ctx.pace();
  ctx.requests += 1;
  let res;
  try {
    res = await ctx.fetch(url, { credentials: "include", redirect: "follow", headers: { Accept: "application/json" } });
  } catch {
    throw new CollectError("network");
  }
  if (typeof res.url === "string" && res.url !== "" && hostOf(res.url) !== CANVAS_HOST) throw new CollectError("out");
  if (res.status === 429) throw new CollectError("rateLimited");
  const raw = await safeText(res);
  if (res.status === 403 && /rate limit/i.test(raw)) throw new CollectError("rateLimited");
  if (res.status === 401 || res.status === 403) {
    if (looksLikeHTML(stripAntiHijackPrefix(raw))) throw new CollectError("out");
    throw new CollectError((await ctx.confirmSession()) ? "forbidden" : "out");
  }
  if (!res.ok) throw new CollectError("http");
  const text = stripAntiHijackPrefix(raw);
  if (looksLikeHTML(text)) throw new CollectError("out");
  let json;
  try { json = JSON.parse(text); } catch { throw new CollectError("decode"); }
  return { json, link: res.headers && typeof res.headers.get === "function" ? res.headers.get("Link") : null };
}

// All pages of a paginated listing, as parsed JSON, following Link rel="next"
// on the same host only. More than MAX_PAGES pages is a failure, not a quiet
// cut: a truncated listing must not count as a complete set.
async function canvasPaged(ctx, url) {
  const pages = [];
  let next = url;
  for (let i = 0; next !== null; i++) {
    if (i >= MAX_PAGES) throw new CollectError("truncated");
    const { json, link } = await canvasGet(ctx, next);
    pages.push(json);
    try {
      next = nextPageURL(link);
    } catch {
      throw new CollectError("unsafeLink");
    }
  }
  return pages;
}

const decodeError = () => new CollectError("decode");
function decoding(fn) {
  try { return fn(); } catch { throw decodeError(); }
}

// ------------------------------------------------------------- courses

function isObject(v) { return typeof v === "object" && v !== null && !Array.isArray(v); }

// The student's active courses. The code is the phone's key:
// CourseCode.parse(name).code (courseKey(forEnrolled:)).
export function courseFromCanvas(raw) {
  if (!isObject(raw) || raw.id === undefined || raw.id === null) return null;
  if (raw.access_restricted_by_date === true) return null;
  const name = typeof raw.name === "string" && raw.name !== "" ? raw.name : typeof raw.course_code === "string" ? raw.course_code : "";
  if (name === "") return null;
  const courseID = String(raw.id);
  if (!/^[0-9]+$/.test(courseID)) return null;
  const parsed = parseCourseCode(name);
  const course = {
    courseID,
    code: parsed.code === "(unknown course)" ? name : parsed.code,
    name,
    url: `${DEFAULT_BASE_URL}/courses/${courseID}`,
  };
  if (parsed.section) course.section = parsed.section;
  if (parsed.term) course.term = parsed.term.code;
  return course;
}

async function listCourses(ctx) {
  const pages = await canvasPaged(ctx, `${DEFAULT_BASE_URL}/api/v1/courses?enrollment_state=active&per_page=100`);
  const out = [];
  const seen = new Set();
  for (const page of pages) {
    if (!Array.isArray(page)) throw decodeError();
    for (const raw of page) {
      const c = courseFromCanvas(raw);
      if (c && !seen.has(c.courseID)) { seen.add(c.courseID); out.push(c); }
    }
  }
  return out;
}

// ------------------------------------------------------- per-course reads

// Each reader returns { documents, links } or throws. A thrown endpoint keeps
// nothing it built (the course is then not fully synced).
const READERS = {
  async syllabus(ctx, course, now) {
    const { json } = await canvasGet(ctx, syllabusBodyURL(course.courseID));
    const candidate = syllabusBodyCandidate(course.courseID, json);
    if (candidate === null) return { documents: [], links: [] };
    const doc = syllabusDocument(candidate, course, { now });
    return { documents: doc ? [doc] : [], links: linksFromSyllabusCandidate(candidate, course) };
  },

  async pages(ctx, course, now) {
    const listPages = await canvasPaged(ctx, pagesListURL(course.courseID));
    const all = decoding(() => listPages.flatMap((p) => decodePages(p)));
    const documents = [];
    const links = [];
    for (const slug of pageSlugsToFetch(all)) {
      const { json } = await canvasGet(ctx, pageBodyURL(course.courseID, slug));
      const page = decoding(() => decodePage(json));
      documents.push(pageDocument(page, course, { now }));
      links.push(...linksFromPage(page, course));
    }
    return { documents, links };
  },

  async modules(ctx, course, now) {
    const pages = await canvasPaged(ctx, modulesURL(course.courseID));
    const items = decoding(() => decodeModuleItems(pages));
    const fileIDs = items.filter((i) => i.typeRaw === "File" && i.contentID).map((i) => i.contentID);
    return { documents: moduleDocuments(items, course, { now }), links: linksFromModuleItems(items, course), fileIDs };
  },

  async assignments(ctx, course, now) {
    const pages = await canvasPaged(ctx, assignmentsURL(course.courseID));
    const assignments = decoding(() => pages.flatMap((p) => decodeAssignments(p)));
    return {
      documents: assignments.map((a) => assignmentDocument(a, course, { now })),
      links: assignments.flatMap((a) => linksFromAssignment(a, course)),
    };
  },

  async announcements(ctx, course, now) {
    const pages = await canvasPaged(ctx, announcementsRequestURL([course.courseID], now));
    const announcements = decoding(() => pages.flatMap((p) => decodeAnnouncements(p)));
    return {
      documents: announcements.filter((a) => a.courseID === course.courseID).map((a) => announcementDocument(a, course, { now })).filter((d) => d !== null),
      links: [], // announcements are deliberately not scanned for links
    };
  },
};

export const ENDPOINTS = Object.keys(READERS);

// ------------------------------------------------------------------ Ed

async function edGet(ctx, url, token) {
  await ctx.pace();
  ctx.requests += 1;
  let res;
  try {
    res = await ctx.fetch(url, { credentials: "omit", redirect: "follow", headers: { Accept: "application/json", "x-token": token } });
  } catch {
    throw new CollectError("network");
  }
  if (res.status === 401 || res.status === 403) throw new CollectError("out");
  if (res.status === 429) throw new CollectError("rateLimited");
  if (!res.ok) throw new CollectError("http");
  const type = res.headers && typeof res.headers.get === "function" ? res.headers.get("Content-Type") : null;
  if (type && /text\/html/i.test(type)) throw new CollectError("out");
  try { return JSON.parse(await res.text()); } catch { throw new CollectError("decode"); }
}

// Match Ed courses to Canvas courses (as the phone: no link evidence, one
// Canvas site per code gets the documents, the first), read threads, keep only
// what ed.js keeps. Returns { status, matched, documents, readCourseIDs }.
async function collectEd(ctx, token, courses, now) {
  const result = { status: "in", matched: 0, documents: [], readCourseIDs: [] };
  let user;
  try {
    user = edCore.decodeUserResponse(await edGet(ctx, edCore.userURL(), token));
  } catch (e) {
    result.status = e instanceof CollectError && e.kind === "out" ? "out" : "error";
    return result;
  }
  const seen = new Set();
  const refs = [];
  for (const c of courses) {
    if (seen.has(c.code)) continue;
    seen.add(c.code);
    refs.push({ code: c.code, term: parseCourseCode(c.name).term });
  }
  const matches = matchEdCourses({ edCourses: user.courses.map((e) => e.course), canvasCourses: refs, edLinks: {} })
    .sort((a, b) => (a.canvasCourseCode < b.canvasCourseCode ? -1 : a.canvasCourseCode > b.canvasCourseCode ? 1 : 0));
  for (const m of matches) {
    const target = courses.find((c) => c.code === m.canvasCourseCode);
    if (!target) continue;
    let response;
    try {
      response = edCore.decodeThreadsResponse(await edGet(ctx, edCore.threadsURL(m.edCourseID), token));
    } catch (e) {
      if (e instanceof CollectError && e.kind === "out") { result.status = "out"; break; }
      if (e instanceof CollectError && e.kind === "rateLimited") break;
      continue;
    }
    result.documents.push(...edCore.documents({ course: target, edCourseID: m.edCourseID, response, now }));
    result.matched += 1;
    result.readCourseIDs.push(target.courseID);
  }
  return result;
}

// ------------------------------------------------------------- collect

function countBy(items, key) {
  const out = {};
  for (const item of items) out[item[key]] = (out[item[key]] ?? 0) + 1;
  return out;
}

function dedupeDocuments(documents) {
  const seen = new Set();
  return documents.filter((d) => (seen.has(d.id) ? false : (seen.add(d.id), true)));
}

// collectCourseMaterial: see the file header.
//   fetch      fetch-compatible function
//   now        Date | ms (defaults to the current time)
//   courses    optional pre-listed courses [{ courseID, code, name, url?, term?, section? }];
//              omitted means list them from Canvas
//   edToken    optional Ed session token (from chrome.storage.session)
//   limits     { delayMs = 250, sleep }  (sleep is for tests)
//   files      optional { extractText, seen, maxFiles }: the Canvas Files pass (PDF text,
//              adapters/files.js) after each course's other endpoints. `seen` is
//              { [courseID]: { [fileID]: updated_at } }. File failures are never listed
//              in `failures`, so they never affect a course's fully-synced status.
// Returns { canvas: "in" | "out" | "error", courses, documents, links,
//           failures: { [courseID]: [endpoint] }, ed, edReadCourseIDs, summary }
// canvas "out" means the student is signed out of Canvas: nothing is returned
// (documents is empty) so nothing can be uploaded.
export async function collectCourseMaterial({ fetch: fetchFn, now, courses, edToken, limits = {}, sleep, files } = {}) {
  const when = now === undefined ? new Date() : new Date(now);
  const ctx = makeContext({ fetch: fetchFn, limits, sleep });
  const empty = (canvas) => ({
    canvas, courses: [], documents: [], links: [], failures: {}, ed: "none", edReadCourseIDs: [], filesSeen: files?.seen ?? {},
    summary: { canvas, ed: "none", courses: 0, documents: 0, links: 0, failedEndpoints: 0, forbidden: 0, requests: ctx.requests, rateLimited: false },
  });

  let list = courses;
  if (list === undefined || list === null) {
    try {
      list = await listCourses(ctx);
    } catch (e) {
      return empty(e instanceof CollectError && e.kind === "out" ? "out" : "error");
    }
  }

  let documents = [];
  let links = [];
  const failures = {};
  let rateLimited = false;
  let forbidden = 0;
  let filesForbidden = 0;
  const filesSeen = { ...(files?.seen ?? {}) };
  const fileCounts = { extracted: 0, empty: 0, failed: 0, linked: 0, linkedForbidden: 0 };
  for (const course of list) {
    const failed = [];
    const courseLinks = [];
    const moduleFileIDs = [];
    if (rateLimited) {
      failures[course.courseID] = ["skipped"];
      continue;
    }
    for (const name of ENDPOINTS) {
      try {
        const got = await READERS[name](ctx, course, when);
        documents.push(...got.documents);
        links.push(...got.links);
        courseLinks.push(...got.links);
        moduleFileIDs.push(...(got.fileIDs ?? []));
      } catch (e) {
        if (!(e instanceof CollectError)) { failed.push(name); continue; }
        if (e.kind === "out") return empty("out"); // sign-in page: nothing is uploaded
        failed.push(name);
        if (e.kind === "forbidden") forbidden += 1;
        if (e.kind === "rateLimited") { rateLimited = true; break; }
      }
    }
    failures[course.courseID] = failed;
    if (files && typeof files.extractText === "function" && !rateLimited) {
      const got = await collectFiles({
        fetch: fetchFn, courseID: course.courseID, course, extractText: files.extractText,
        seen: filesSeen[course.courseID] ?? {}, now: when, sleep: sleep ?? limits.sleep,
        confirmSession: () => ctx.confirmSession(),
        // File ids this run's own material for the course points at (2026-10-27):
        // the Files tab is usually hidden, the links are not.
        linkedFileIDs: [...new Set([...canvasFileIDsFromLinks(courseLinks), ...moduleFileIDs])],
        limits: { delayMs: limits.delayMs, maxFiles: files.maxFiles },
      });
      ctx.requests += got.counts.requests;
      filesSeen[course.courseID] = got.seen;
      filesForbidden += got.counts.forbidden ?? 0;
      if (got.stopped === "out") return empty("out"); // the session check failed: sign-in page, nothing is uploaded
      documents.push(...got.documents);
      for (const k of Object.keys(fileCounts)) fileCounts[k] += got.counts[k];
      if (got.stopped === "rateLimited") rateLimited = true;
    }
  }

  let ed = { status: "none", matched: 0, documents: [], readCourseIDs: [] };
  if (typeof edToken === "string" && edToken !== "") {
    ed = await collectEd(ctx, edToken, list, when);
    documents.push(...ed.documents);
  }

  documents = dedupeDocuments(documents);
  links = dedupeLinks(links);
  return {
    canvas: "in",
    courses: list,
    documents,
    links,
    failures,
    ed: ed.status,
    edReadCourseIDs: ed.readCourseIDs,
    filesSeen,
    summary: {
      canvas: "in",
      ed: ed.status,
      courses: list.length,
      documents: documents.length,
      documentsByKind: countBy(documents, "kind"),
      links: links.length,
      failedEndpoints: Object.values(failures).reduce((n, f) => n + f.length, 0),
      forbidden,
      edMatched: ed.matched,
      requests: ctx.requests,
      rateLimited,
      ...(files ? { files: fileCounts, filesForbidden } : {}),
    },
  };
}

// ---------------------------------------------------------------- sync

const kindOfID = (id) => String(id).split(":", 1)[0];

function errorKindOf(e) {
  return e && typeof e.kind === "string" ? e.kind : "unknown";
}

function courseWire(c) {
  const wire = { courseID: c.courseID, code: c.code, name: c.name };
  if (c.url) wire.url = c.url;
  if (c.term) wire.term = c.term;
  if (c.section) wire.section = c.section;
  return wire;
}

// syncCourseMaterial: the manifest exchange, then the upload.
//   callFunction  (name, body) => Promise<object>, throws errors with `.kind`
//   collected     collectCourseMaterial's result
//   holdings      { [courseID]: [{ id, contentHash }] } the extension's own record
//                 (chrome.storage.local `courseHoldingsV1`): ids and hashes only
// Returns { summary, holdings, profileStale, websitesPending } where `holdings` is the new
// record to persist (the input, untouched, when the manifest step did not happen) and the
// two id lists are the union of the upload answers' lists across batches (empty when no
// upload happened).
//
// What the extension holds for a course after applying `download`, which is
// what `documentIDs` must list in full or the extension would retire the
// server's own `website` crawls and the phone's documents:
//   * a course fully fetched this run: its old holdings, minus the kinds Canvas
//     just answered for (assignment, announcement, module, page, and ed when Ed
//     was read for it), so a document deleted on Canvas can leave the pool;
//   * a course with any failed endpoint: all its old holdings;
//   * plus everything collected now, plus every document the server sent down
//     except the replaced kinds above in a fully-fetched course.
export async function syncCourseMaterial({ callFunction, collected, holdings = {} } = {}) {
  const base = collected?.summary ?? {};
  const summary = {
    canvas: collected?.canvas ?? "error",
    ed: collected?.ed ?? "none",
    courses: collected?.courses?.length ?? 0,
    documents: collected?.documents?.length ?? 0,
    fullySynced: 0,
    downloaded: 0,
    uploaded: 0,
    batches: 0,
    failedEndpoints: base.failedEndpoints ?? 0,
    stopped: null,
    errors: {},
  };
  if (!collected || collected.canvas !== "in" || collected.courses.length === 0) {
    summary.stopped = collected && collected.canvas !== "in" ? `canvas-${collected.canvas}` : "nothing-to-sync";
    return { summary, holdings, profileStale: [], websitesPending: [] };
  }

  const courseIDs = new Set(collected.courses.map((c) => c.courseID));
  const fully = fullyFetchedCourseIDs(
    Object.fromEntries(collected.courses.map((c) => [c.courseID, (collected.failures[c.courseID] ?? ["unknown"]).length])),
  );
  const edRead = new Set(collected.edReadCourseIDs ?? []);
  const replaced = (courseID, kind) =>
    fully.has(courseID) && (CANVAS_REPLACED_KINDS.has(kind) || (kind === "ed" && edRead.has(courseID)));

  const collectedByID = new Map(collected.documents.map((d) => [d.id, d]));
  const held = new Map(); // courseID -> Map(id -> contentHash)
  for (const c of collected.courses) {
    const m = new Map();
    for (const h of holdings[c.courseID] ?? []) {
      if (!h || typeof h.id !== "string" || typeof h.contentHash !== "string") continue;
      if (!replaced(c.courseID, kindOfID(h.id))) m.set(h.id, h.contentHash);
    }
    held.set(c.courseID, m);
  }
  for (const d of collected.documents) held.get(d.courseID)?.set(d.id, d.contentHash);

  const stubs = [];
  for (const m of held.values()) for (const [id, contentHash] of m) stubs.push({ id, contentHash });

  let manifest;
  try {
    manifest = await callFunction("sync", {
      action: "manifest",
      client: "extension",
      acceptsKinds: ACCEPTED_KINDS,
      courses: collected.courses.map(courseWire),
      documents: stubs,
    });
  } catch (e) {
    return { ...stop(summary, e, holdings), profileStale: [], websitesPending: [] };
  }

  // Apply download to holdings: stubs only, never text.
  for (const d of Array.isArray(manifest?.download) ? manifest.download : []) {
    if (!d || typeof d.id !== "string" || typeof d.contentHash !== "string" || !courseIDs.has(d.courseID)) continue;
    if (collectedByID.has(d.id)) continue; // ours is fresher than the server's copy
    if (replaced(d.courseID, d.kind ?? kindOfID(d.id))) continue;
    held.get(d.courseID).set(d.id, d.contentHash);
    summary.downloaded += 1;
  }

  const newHoldings = {};
  for (const [courseID, m] of held) {
    newHoldings[courseID] = [...m].map(([id, contentHash]) => ({ id, contentHash })).sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }

  // `local` for the planner: full documents for what was collected, bare stubs
  // for everything else held (they supply documentIDs; they have no text, so
  // they can never be uploaded).
  const local = [...collected.documents];
  for (const [courseID, m] of held) {
    for (const [id, contentHash] of m) if (!collectedByID.has(id)) local.push({ id, courseID, contentHash });
  }
  const request = uploads({
    local,
    serverManifest: Array.isArray(manifest?.serverManifest) ? manifest.serverManifest : [],
    fullyFetched: fully,
    links: collected.links,
    client: "extension",
  });
  request.documents = request.documents.filter((d) => typeof d.text === "string");
  summary.fullySynced = fully.size;

  const profileStale = new Set();
  const websitesPending = new Set();
  const withFollowUps = (r) => ({ ...r, profileStale: [...profileStale], websitesPending: [...websitesPending] });
  for (const batch of uploadBatches(request)) {
    let answer;
    try {
      answer = await callFunction("sync", batch);
    } catch (e) {
      return withFollowUps(stop(summary, e, newHoldings));
    }
    for (const id of Array.isArray(answer?.profileStale) ? answer.profileStale : []) if (typeof id === "string") profileStale.add(id);
    for (const id of Array.isArray(answer?.websitesPending) ? answer.websitesPending : []) if (typeof id === "string") websitesPending.add(id);
    summary.batches += 1;
    summary.uploaded += batch.documents.length;
  }
  return withFollowUps({ summary, holdings: newHoldings });
}

// notPaired is not an error the UI shows (the student has not paired yet);
// quota is a stop; every other failure is counted by kind. No retry.
function stop(summary, e, holdings) {
  const kind = errorKindOf(e);
  summary.stopped = kind;
  if (kind !== "notPaired") summary.errors[kind] = (summary.errors[kind] ?? 0) + 1;
  return { summary, holdings };
}

// ------------------------------------------------------------ Ed token

// The service worker's handler for the content script's message:
//   chrome.runtime.onMessage.addListener((m, sender, reply) =>
//     { if (m?.type === "edToken") { handleEdTokenMessage(m, sender, chrome.storage.session).then(reply); return true; } });
// Accepts only a message from a frame on https://edstem.org itself. The token
// goes into storage.session (memory, cleared when Chrome closes), never
// storage.local, and is never logged or echoed.
export async function handleEdTokenMessage(message, sender, storageSession) {
  if (!message || message.type !== "edToken") return { ok: false, reason: "ignored" };
  if (!sender || sender.origin !== ED_HOST_ORIGIN) return { ok: false, reason: "origin" };
  const token = message.token;
  if (typeof token !== "string" || token === "" || token.length > 4096) return { ok: false, reason: "token" };
  await storageSession.set({ [ED_TOKEN_KEY]: token });
  return { ok: true };
}

export async function readEdToken(storageSession) {
  const got = await storageSession.get(ED_TOKEN_KEY);
  const token = got?.[ED_TOKEN_KEY];
  return typeof token === "string" && token !== "" ? token : undefined;
}
