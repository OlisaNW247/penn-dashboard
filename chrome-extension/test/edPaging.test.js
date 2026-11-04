import { test } from "node:test";
import assert from "node:assert/strict";
import { threadsWithinWindow, MAX_WINDOW_PAGES, PAGE_LIMIT } from "../src/core/ed.js";

const NOW = new Date("2026-10-22T15:00:00Z");
const day = (n) => new Date(NOW.getTime() - n * 86_400_000);
const th = (id, ageDays, over = {}) => ({ id, updatedAt: day(ageDays), createdAt: day(ageDays), ...over });
const page = (from, ageDays) => Array.from({ length: PAGE_LIMIT }, (_, i) => th(from + i, ageDays));
const pager = (pages, usersByPage = []) => {
  const offsets = [];
  return { offsets, fetchPage: async (offset) => { offsets.push(offset); return { threads: pages[offset / PAGE_LIMIT] ?? [], users: usersByPage[offset / PAGE_LIMIT] ?? [] }; } };
};

test("paging: constants match the phone", () => {
  assert.equal(MAX_WINDOW_PAGES, 3);
  assert.equal(PAGE_LIMIT, 100);
});

test("paging: a short first page stops after one fetch", async () => {
  const p = pager([[th(1, 1)]]);
  const r = await threadsWithinWindow({ fetchPage: p.fetchPage, now: NOW });
  assert.deepEqual(p.offsets, [0]);
  assert.equal(r.threads.length, 1);
});

test("paging: an empty page stops too", async () => {
  const p = pager([[]]);
  const r = await threadsWithinWindow({ fetchPage: p.fetchPage, now: NOW });
  assert.deepEqual(p.offsets, [0]);
  assert.deepEqual(r, { threads: [], users: [] });
});

test("paging: three full recent pages read offsets 0, 100, 200 and stop at the cap", async () => {
  const p = pager([page(0, 1), page(1000, 1), page(2000, 1), page(3000, 1)]);
  const r = await threadsWithinWindow({ fetchPage: p.fetchPage, now: NOW });
  assert.deepEqual(p.offsets, [0, 100, 200]);
  assert.equal(r.threads.length, 300);
  const q = pager([page(0, 1), page(1000, 1)]);
  await threadsWithinWindow({ fetchPage: q.fetchPage, now: NOW, pageLimit: 1 });
  assert.deepEqual(q.offsets, [0]);
});

test("paging: a page whose oldest thread is older than the window stops paging", async () => {
  const p = pager([page(0, 1), page(1000, 200), page(2000, 1)]);
  const r = await threadsWithinWindow({ fetchPage: p.fetchPage, now: NOW });
  assert.deepEqual(p.offsets, [0, 100]);
  assert.equal(r.threads.length, 200);
});

test("paging: the window is judged by last activity, falling back to creation", async () => {
  const old = { id: 1, updatedAt: null, createdAt: day(200) };
  const first = [old, ...page(10, 1).slice(1)];
  const p = pager([first, page(1000, 1)]);
  await threadsWithinWindow({ fetchPage: p.fetchPage, now: NOW });
  assert.deepEqual(p.offsets, [0]);
});

test("paging: a repeated thread keeps its first copy; users merge by id", async () => {
  const a = page(0, 1);
  const b = page(0, 1);
  b[0] = { ...b[0], title: "second copy" };
  a[0] = { ...a[0], title: "first copy" };
  const p = pager([a, b], [[{ id: 1, courseRole: "admin" }], [{ id: 1, courseRole: "student" }, { id: 2, courseRole: "student" }]]);
  const r = await threadsWithinWindow({ fetchPage: p.fetchPage, now: NOW, pageLimit: 2 });
  assert.equal(r.threads.length, 100);
  assert.equal(r.threads[0].title, "first copy");
  assert.deepEqual(r.users, [{ id: 1, courseRole: "admin" }, { id: 2, courseRole: "student" }]);
});

test("paging: an error on page 2 rejects and returns nothing", async () => {
  const fetchPage = async (offset) => {
    if (offset === 100) throw new Error("boom");
    return { threads: page(0, 1), users: [] };
  };
  await assert.rejects(threadsWithinWindow({ fetchPage, now: NOW }), /boom/);
});
