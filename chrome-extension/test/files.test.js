import { test } from "node:test";
import assert from "node:assert/strict";
import { collectFiles, cleanFileText, FILE_MAX_BYTES } from "../src/adapters/files.js";
import { collectCourseMaterial } from "../src/adapters/collector.js";
import { fileDocument } from "../src/core/canvasDocuments.js";

const NOW = new Date("2026-10-22T15:00:00Z");
const COURSE = { courseID: "111", code: "CIS 2400" };
const PDF = new TextEncoder().encode("%PDF-1.4 fake");

function entry(id, over = {}) {
  return { id, display_name: `f${id}.pdf`, url: `https://canvas.upenn.edu/files/${id}/download?verifier=v`, size: 1000, updated_at: `2026-09-${String(10 + id % 10).padStart(2, "0")}T10:00:00Z`, ...over };
}

function res(body, { status = 200, link = null, type = "application/pdf", bytes = null } = {}) {
  return {
    status, ok: status >= 200 && status < 300,
    headers: { get: (n) => (n.toLowerCase() === "link" ? link : n.toLowerCase() === "content-type" ? type : null) },
    text: async () => body,
    arrayBuffer: async () => (bytes ?? PDF).buffer.slice((bytes ?? PDF).byteOffset, (bytes ?? PDF).byteOffset + (bytes ?? PDF).byteLength),
  };
}
const list = (items, link) => res("while(1);" + JSON.stringify(items), { link, type: "application/json" });

// Fake Canvas: `pages` is an array of listing pages; downloads answer by id.
function fake({ pages, download = () => res("") } = {}) {
  const log = { urls: [], inits: [] };
  const fn = async (url, init) => {
    log.urls.push(url); log.inits.push(init);
    const u = new URL(url);
    if (u.pathname === "/api/v1/courses/111/files") {
      const p = Number(u.searchParams.get("page") ?? 1);
      const more = p < pages.length;
      return list(pages[p - 1], more ? `<https://canvas.upenn.edu/api/v1/courses/111/files?content_types%5B%5D=application/pdf&per_page=100&page=${p + 1}>; rel="next"` : null);
    }
    const m = /^\/files\/(\d+)\/download$/.exec(u.pathname);
    if (m) return download(m[1], url);
    throw new Error("unexpected " + url);
  };
  return { fn, log };
}

const noSleep = { sleep: async () => {} };
const extract = async (bytes) => "  Midterm   on\tMarch 3.\n\n\n\nBring a pencil.  ";

test("lists with the PDF filter, paginates, downloads with credentials, builds fileDocument", async () => {
  const { fn, log } = fake({ pages: [[entry(1)], [entry(2)]], download: () => res("") });
  const out = await collectFiles({ fetch: fn, courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep });
  assert.match(log.urls[0], /\/api\/v1\/courses\/111\/files\?content_types%5B%5D=application\/pdf&per_page=100$/);
  assert.equal(log.urls.filter((u) => u.includes("/files?")).length, 2);
  assert.ok(log.inits.every((i) => i.credentials === "include"));
  assert.equal(out.documents.length, 2);
  const d = out.documents.find((x) => x.sourceID === "2");
  assert.deepEqual(d, fileDocument({
    courseID: "111", course: "CIS 2400", fileID: "2", displayName: "f2.pdf",
    url: "https://canvas.upenn.edu/courses/111/files/2", updatedAt: "2026-09-12T10:00:00Z",
    text: "Midterm on March 3.\n\nBring a pencil.", fetchedAt: NOW,
  }));
  assert.equal(d.id, "file:111:2");
  assert.equal(d.kind, "file");
  assert.deepEqual(out.seen, { 1: "2026-09-11T10:00:00Z", 2: "2026-09-12T10:00:00Z" });
});

test("skips over-size, locked, hidden and locked_for_user files without downloading", async () => {
  const items = [
    entry(1, { size: FILE_MAX_BYTES + 1 }), entry(2, { locked: true }), entry(3, { hidden: true }),
    entry(4, { locked_for_user: true }), entry(5),
  ];
  const { fn, log } = fake({ pages: [items], download: () => res("") });
  const out = await collectFiles({ fetch: fn, courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep });
  assert.deepEqual(out.documents.map((d) => d.sourceID), ["5"]);
  assert.equal(log.urls.filter((u) => u.includes("/download")).length, 1);
  assert.equal(out.counts.skipped, 4);
});

test("a file unchanged since the last run is not downloaded; a changed one is", async () => {
  const { fn, log } = fake({ pages: [[entry(1), entry(2)]], download: () => res("") });
  const out = await collectFiles({
    fetch: fn, courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep,
    seen: { 1: "2026-09-11T10:00:00Z", 2: "2026-01-01T00:00:00Z", 99: "gone" },
  });
  assert.deepEqual(out.documents.map((d) => d.sourceID), ["2"]);
  assert.equal(out.counts.unchanged, 1);
  assert.deepEqual(out.seen, { 1: "2026-09-11T10:00:00Z", 2: "2026-09-12T10:00:00Z" }); // 99 forgotten
  assert.equal(log.urls.filter((u) => u.includes("/download")).length, 1);
});

test("at most maxFiles per run, newest updated_at first; unchanged ones do not use the budget", async () => {
  const items = [1, 2, 3, 4, 5].map((i) => entry(i, { updated_at: `2026-0${i}-01T00:00:00Z` }));
  const { fn, log } = fake({ pages: [items], download: () => res("") });
  const out = await collectFiles({
    fetch: fn, courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep,
    limits: { maxFiles: 2 }, seen: { 5: "2026-05-01T00:00:00Z" },
  });
  assert.deepEqual(out.documents.map((d) => d.sourceID), ["4", "3"]);
  assert.deepEqual(log.urls.filter((u) => u.includes("/download")).map((u) => /files\/(\d+)/.exec(u)[1]), ["4", "3"]);
});

test("default cap is 60 files", async () => {
  const items = Array.from({ length: 70 }, (_, i) => entry(i + 1, { updated_at: new Date(2026, 0, 1, 0, i).toISOString() }));
  const { fn } = fake({ pages: [items], download: () => res("") });
  const out = await collectFiles({ fetch: fn, courseID: "111", course: COURSE, extractText: async () => "x", now: NOW, ...noSleep });
  assert.equal(out.documents.length, 60);
});

test("text is capped at 60,000 characters without splitting a surrogate pair", async () => {
  const { fn } = fake({ pages: [[entry(1)]], download: () => res("") });
  const out = await collectFiles({ fetch: fn, courseID: "111", course: COURSE, extractText: async () => "a".repeat(59_999) + "😀tail", now: NOW, ...noSleep });
  assert.equal(out.documents[0].text, "a".repeat(59_999));
});

test("a failed download, an http error and a throwing extractor are non-fatal", async () => {
  const items = [1, 2, 3, 4].map((i) => entry(i, { updated_at: `2026-0${i}-01T00:00:00Z` }));
  const { fn } = fake({
    pages: [items],
    download: (id) => {
      if (id === "4") throw new TypeError("Failed to fetch");
      if (id === "3") return res("", { status: 404 });
      return res("");
    },
  });
  let extractions = 0;
  const out = await collectFiles({
    fetch: fn, courseID: "111", course: COURSE, now: NOW, ...noSleep,
    extractText: async () => { if (extractions++ === 0) throw new Error("corrupt"); return "ok text"; },
  });
  assert.deepEqual(out.documents.map((d) => d.sourceID), ["1"]);
  assert.equal(out.stopped, null);
  assert.equal(out.counts.failed, 3);
  assert.deepEqual(Object.keys(out.seen).sort(), ["1", "2"]); // 3 and 4 retry next run
});

test("a scan (no text layer) yields no document but is remembered", async () => {
  const { fn } = fake({ pages: [[entry(1)]], download: () => res("") });
  const out = await collectFiles({ fetch: fn, courseID: "111", course: COURSE, extractText: async () => " \n\t ", now: NOW, ...noSleep });
  assert.equal(out.documents.length, 0);
  assert.equal(out.counts.empty, 1);
  assert.deepEqual(out.seen, { 1: "2026-09-11T10:00:00Z" });
});

test("requests are sequential and spaced by 250 ms", async () => {
  const events = [];
  const { fn } = fake({ pages: [[entry(1), entry(2)]], download: () => res("") });
  const traced = async (u, i) => { events.push("fetch"); return fn(u, i); };
  await collectFiles({ fetch: traced, courseID: "111", course: COURSE, extractText: extract, now: NOW, sleep: async (ms) => { events.push(ms); } });
  assert.deepEqual(events, [250, "fetch", 250, "fetch", 250, "fetch"]);
});

test("a rate-limited or signed-out answer stops the pass; a failed listing is non-fatal", async () => {
  const limited = await collectFiles({
    fetch: async () => res("", { status: 429 }), courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep,
  });
  assert.equal(limited.stopped, "rateLimited");
  const html = await collectFiles({
    fetch: async () => res("<html>Sign in</html>", { type: "text/html" }), courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep,
  });
  assert.equal(html.stopped, "out");
  const down = await collectFiles({
    fetch: async () => { throw new TypeError("offline"); }, courseID: "111", course: COURSE, extractText: extract, now: NOW, ...noSleep,
  });
  assert.equal(down.stopped, null);
  assert.deepEqual(down.documents, []);
});

test("cleanFileText collapses whitespace", () => {
  assert.equal(cleanFileText("a  b\r\n \r\n\r\n\r\n c  d \n"), "a b\n\nc d");
});

// ------------------------------------------------------------ collector

test("collector: files pass adds documents, never touches failures, returns filesSeen", async () => {
  const { fn } = fake({ pages: [[entry(7)]], download: () => res("") });
  const wrapped = async (url, init) => {
    const u = new URL(url);
    if (u.pathname.startsWith("/api/v1/courses/111/files") || u.pathname.startsWith("/files/")) return fn(url, init);
    return { ...list([]), url };
  };
  const got = await collectCourseMaterial({
    fetch: wrapped, now: NOW, courses: [{ ...COURSE, name: "CIS 2400" }], limits: { delayMs: 0 },
    files: { extractText: extract, seen: {} },
  });
  const f = got.documents.filter((d) => d.kind === "file");
  assert.deepEqual(f.map((d) => d.id), ["file:111:7"]);
  assert.equal(got.summary.files.extracted, 1);
  assert.deepEqual(got.filesSeen, { 111: { 7: "2026-09-17T10:00:00Z" } });
  assert.deepEqual(got.failures["111"].filter((e) => e === "files"), []);
});

test("collector: without `files` nothing changes (no files requests)", async () => {
  const urls = [];
  const got = await collectCourseMaterial({
    fetch: async (url) => { urls.push(url); return { ...list([]), url }; }, now: NOW, courses: [{ ...COURSE, name: "CIS 2400" }], limits: { delayMs: 0 },
  });
  assert.ok(!urls.some((u) => u.includes("/files")));
  assert.equal(got.summary.files, undefined);
});
