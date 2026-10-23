// Canvas Files text: the PDFs in a course's Files, extracted in the browser
// and built into `file` documents (docs/CHROME_EXTENSION.md "Files text").
//
// Non-fatal throughout: a file that cannot be listed, downloaded or parsed is
// skipped and never counts toward whether a course is "fully synced" (the
// collector's complete-set reasoning ignores kind `file`). Sequential, spaced,
// bounded per course per run. No cookie is read; Canvas gets
// `credentials: "include"`.
import {
  DEFAULT_BASE_URL, MAX_PAGES, stripAntiHijackPrefix, looksLikeHTML, nextPageURL,
} from "../core/canvasApi.js";
import { fileDocument } from "../core/canvasDocuments.js";

export const FILES_DEFAULT_MAX = 60;
export const FILES_DEFAULT_DELAY_MS = 250;
export const FILE_MAX_BYTES = 25 * 1024 * 1024;

export function filesListURL(courseID, { baseURL = DEFAULT_BASE_URL } = {}) {
  return `${baseURL.replace(/\/+$/, "")}/api/v1/courses/${courseID}/files?content_types%5B%5D=application/pdf&per_page=100`;
}

// Whitespace cleanup: runs of spaces/tabs become one space, spaces around line
// breaks go, three or more newlines become a blank line, ends trimmed.
export function cleanFileText(raw) {
  return String(raw)
    .replace(/\r\n?/g, "\n")
    .replace(/[^\S\n]+/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class Stop extends Error {
  constructor(kind) { super(kind); this.kind = kind; } // rateLimited | out | forbidden | http | network | decode | unsafe
}

function isObject(v) { return typeof v === "object" && v !== null && !Array.isArray(v); }

function skippable(f) {
  return f.locked === true || f.hidden === true || f.locked_for_user === true || f.hidden_for_user === true;
}

// The listing entry as { id, name, url, size, updatedAt, updatedMs }, or null.
export function decodeFileEntry(raw) {
  if (!isObject(raw) || raw.id === undefined || raw.id === null) return null;
  const id = String(raw.id);
  if (!/^[0-9]+$/.test(id)) return null;
  if (typeof raw.url !== "string" || raw.url === "") return null;
  const name = typeof raw.display_name === "string" && raw.display_name !== "" ? raw.display_name
    : typeof raw.filename === "string" ? raw.filename : "";
  if (name === "") return null;
  const updatedAt = typeof raw.updated_at === "string" ? raw.updated_at : "";
  const ms = Date.parse(updatedAt);
  return {
    id, name, url: raw.url, updatedAt, updatedMs: Number.isNaN(ms) ? 0 : ms,
    size: typeof raw.size === "number" ? raw.size : 0,
    skip: skippable(raw),
  };
}

// collectFiles: one course's PDFs.
//   fetch        fetch-compatible
//   courseID     string
//   course       { code } or the display code string (for the document's `course`)
//   extractText  async (Uint8Array) => string  (adapters/pdfText.js `extractPdfText`)
//   seen         { [fileID]: updated_at } from the last run; unchanged files are skipped
//   now          fetchedAt
//   sleep        for tests
//   confirmSession  optional async () => boolean, "is the Canvas session alive?" (the
//                collector's memoised /users/self check). Canvas answers 401 for a
//                forbidden resource too (a course that hides its Files tab), so with
//                it a 401/403 on a live session is "forbidden": the listing is skipped
//                quietly (counts.forbidden) or one download is skipped. Without it a
//                401 is "out", as before.
//   limits       { maxFiles = 60, delayMs = 250, maxBytes = 25 MB, sleep }
// Returns { documents, seen, stopped, counts }. `seen` is the new map (old
// entries for files still listed, plus every file handled this run, including
// scans that had no text; failed downloads are not recorded so they retry).
// `stopped` is null, "rateLimited" or "out" (the caller stops its Canvas run
// on rateLimited). Never throws.
export async function collectFiles({ fetch: fetchFn, courseID, course, extractText, seen = {}, now, sleep, confirmSession, limits = {} } = {}) {
  const delayMs = limits.delayMs ?? FILES_DEFAULT_DELAY_MS;
  const maxFiles = limits.maxFiles ?? FILES_DEFAULT_MAX;
  const maxBytes = limits.maxBytes ?? FILE_MAX_BYTES;
  const doSleep = sleep ?? limits.sleep ?? defaultSleep;
  const counts = { listed: 0, unchanged: 0, skipped: 0, extracted: 0, empty: 0, failed: 0, attempted: 0, forbidden: 0, requests: 0 };
  const result = { documents: [], seen: { ...seen }, stopped: null, counts };
  const fetchedAt = now === undefined ? new Date() : new Date(now);

  async function get(url, accept) {
    if (delayMs > 0) await doSleep(delayMs); // also before the first: the caller just made a request
    counts.requests += 1;
    let res;
    try {
      res = await fetchFn(url, { credentials: "include", redirect: "follow", headers: { Accept: accept } });
    } catch {
      throw new Stop("network");
    }
    if (res.status === 429) throw new Stop("rateLimited");
    if (res.status === 401 || res.status === 403) {
      const t = await res.text().catch(() => "");
      if (res.status === 403 && /rate limit/i.test(t)) throw new Stop("rateLimited");
      if (typeof confirmSession !== "function") throw new Stop(res.status === 401 ? "out" : "http");
      if (looksLikeHTML(stripAntiHijackPrefix(t))) throw new Stop("out");
      throw new Stop((await confirmSession()) ? "forbidden" : "out");
    }
    if (!res.ok) throw new Stop("http");
    return res;
  }

  // ---- list (paginated); a failed later page keeps the earlier ones
  const entries = [];
  try {
    let next = filesListURL(courseID);
    for (let i = 0; next !== null && i < MAX_PAGES; i++) {
      const res = await get(next, "application/json");
      const text = stripAntiHijackPrefix(await res.text());
      if (looksLikeHTML(text)) throw new Stop("out");
      let json;
      try { json = JSON.parse(text); } catch { throw new Stop("decode"); }
      if (!Array.isArray(json)) throw new Stop("decode");
      for (const raw of json) {
        const e = decodeFileEntry(raw);
        if (e) entries.push(e);
      }
      try {
        next = nextPageURL(res.headers && typeof res.headers.get === "function" ? res.headers.get("Link") : null);
      } catch {
        throw new Stop("unsafe");
      }
    }
  } catch (e) {
    if (e instanceof Stop && (e.kind === "rateLimited" || e.kind === "out")) { result.stopped = e.kind; return result; }
    if (e instanceof Stop && e.kind === "forbidden") { counts.forbidden += 1; return result; } // Files tab hidden: skip quietly
    if (entries.length === 0) return result;
  }

  // ---- choose: newest first, unlocked, small, changed
  const seenIDs = new Set();
  const todo = [];
  for (const e of entries.sort((a, b) => b.updatedMs - a.updatedMs)) {
    if (seenIDs.has(e.id)) continue;
    seenIDs.add(e.id);
    counts.listed += 1;
    if (e.skip || e.size > maxBytes) { counts.skipped += 1; continue; }
    if (seen[e.id] !== undefined && seen[e.id] === e.updatedAt) { counts.unchanged += 1; continue; }
    todo.push(e);
  }
  // Forget files that are no longer listed.
  for (const id of Object.keys(result.seen)) if (!seenIDs.has(id)) delete result.seen[id];

  const displayCode = typeof course === "string" ? course : course?.code ?? "";
  for (const e of todo.slice(0, maxFiles)) {
    counts.attempted += 1;
    try {
      const res = await get(e.url, "application/pdf,*/*");
      const type = res.headers && typeof res.headers.get === "function" ? res.headers.get("Content-Type") : null;
      if (type && /text\/html/i.test(type)) throw new Stop("out");
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (bytes.byteLength === 0 || bytes.byteLength > maxBytes) { counts.skipped += 1; result.seen[e.id] = e.updatedAt; continue; }
      let text;
      try {
        text = cleanFileText(await extractText(bytes));
      } catch {
        counts.failed += 1; // unparseable PDF: retry next run only if it changes
        result.seen[e.id] = e.updatedAt;
        continue;
      }
      result.seen[e.id] = e.updatedAt;
      if (text === "") { counts.empty += 1; continue; } // scan: no text layer
      result.documents.push(fileDocument({
        courseID, course: displayCode, fileID: e.id, displayName: e.name,
        url: `${DEFAULT_BASE_URL}/courses/${courseID}/files/${e.id}`,
        updatedAt: e.updatedAt === "" ? undefined : e.updatedAt,
        text, fetchedAt,
      }));
      counts.extracted += 1;
    } catch (err) {
      if (err instanceof Stop && (err.kind === "rateLimited" || err.kind === "out")) { result.stopped = err.kind; break; }
      counts.failed += 1; // network / http / forbidden: not recorded in `seen`, so it is tried again next run
    }
  }
  return result;
}
