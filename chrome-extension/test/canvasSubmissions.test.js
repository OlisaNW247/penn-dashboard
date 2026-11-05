import { test } from "node:test";
import assert from "node:assert/strict";
import { isSubmitted, readCanvasSubmissions } from "../src/adapters/canvasSubmissions.js";

const noSleep = async () => {};
const NOW = new Date("2026-11-05T15:00:00Z");

test("isSubmitted: the phone's rule", () => {
  assert.equal(isSubmitted({ missing: true, submitted_at: "2026-11-01T00:00:00Z" }), false);
  assert.equal(isSubmitted({ missing: true, workflow_state: "submitted" }), false);
  assert.equal(isSubmitted({ submitted_at: "2026-11-01T00:00:00Z" }), true);
  assert.equal(isSubmitted({ submitted_at: null, workflow_state: "submitted" }), true);
  assert.equal(isSubmitted({ workflow_state: "pending_review" }), true);
  assert.equal(isSubmitted({ workflow_state: "unsubmitted" }), false);
  assert.equal(isSubmitted({ workflow_state: "graded", submitted_at: null }), false);
  assert.equal(isSubmitted({ workflow_state: "graded", submitted_at: "2026-11-01T00:00:00Z" }), true);
  assert.equal(isSubmitted(null), false);
  assert.equal(isSubmitted(undefined), false);
});

const reply = (body, { status = 200, link = null, url = "", html = false } = {}) => ({
  status, ok: status >= 200 && status < 300, url,
  headers: { get: (k) => (k === "Link" ? link : null) },
  text: async () => (html ? body : "while(1);" + JSON.stringify(body)),
});

function canvas({ coursesHTML = false, forbidden = [] } = {}) {
  const urls = [];
  const fetch = async (url) => {
    urls.push(url);
    const u = new URL(url);
    if (u.pathname === "/api/v1/courses") {
      return coursesHTML ? reply("<html>sign in</html>", { html: true }) : reply([{ id: 1, name: "CIS 1200-001 X 202630" }, { id: 2, name: "PHYS 0151-001 X 202630" }, { id: 3, name: "ACCT 1010-001 X 202630" }]);
    }
    if (u.pathname === "/api/v1/users/self") return reply({ id: 9 });
    const m = /\/courses\/(\d+)\/assignments/.exec(u.pathname);
    if (m && forbidden.includes(m[1])) return reply({ status: "unauthorized" }, { status: 401 });
    if (m && m[1] === "1") {
      if (u.searchParams.get("page") === "2") return reply([{ id: 12, submission: { workflow_state: "submitted" } }]);
      return reply([{ id: 11, submission: { submitted_at: "2026-11-01T00:00:00Z" } }, { id: 13, submission: { workflow_state: "unsubmitted" } }],
        { link: '<https://canvas.upenn.edu/api/v1/courses/1/assignments?page=2&per_page=100>; rel="next"' });
    }
    if (m && m[1] === "2") return reply([{ id: 21, submission: { missing: true, submitted_at: "x" } }, { id: 22, submission: { workflow_state: "pending_review" } }, { id: 23 }]);
    if (m && m[1] === "3") return reply([{ id: 31, submission: { submitted_at: "2026-11-02T00:00:00Z" } }]);
    return reply([]);
  };
  return { fetch, urls };
}

test("readCanvasSubmissions: paged courses, exactly the submitted ids", async () => {
  const c = canvas();
  const r = await readCanvasSubmissions({ fetchFn: c.fetch, now: NOW, sleep: noSleep });
  assert.equal(r.status, "in");
  assert.equal(r.at, NOW.toISOString());
  assert.deepEqual(r.submitted, { 11: { submittedAt: "2026-11-01T00:00:00Z" }, 12: { submittedAt: null }, 22: { submittedAt: null }, 31: { submittedAt: "2026-11-02T00:00:00Z" } });
  assert.ok(c.urls.every((u) => u.startsWith("https://canvas.upenn.edu/")));
});

test("readCanvasSubmissions: a 401 on one course skips only that course", async () => {
  const c = canvas({ forbidden: ["2"] });
  const r = await readCanvasSubmissions({ fetchFn: c.fetch, now: NOW, sleep: noSleep });
  assert.equal(r.status, "in");
  assert.deepEqual(r.submitted, { 11: { submittedAt: "2026-11-01T00:00:00Z" }, 12: { submittedAt: null }, 31: { submittedAt: "2026-11-02T00:00:00Z" } });
});

test("readCanvasSubmissions: an HTML courses listing is out and keeps the prior map", async () => {
  const prior = { at: "2026-11-01T00:00:00.000Z", submitted: { 99: { submittedAt: null } } };
  const r = await readCanvasSubmissions({ fetchFn: canvas({ coursesHTML: true }).fetch, now: NOW, prior, sleep: noSleep });
  assert.equal(r.status, "out");
  assert.deepEqual(r.submitted, { 99: { submittedAt: null } });
  assert.equal(r.at, prior.at);
});

test("readCanvasSubmissions: a network failure is error and keeps the prior map", async () => {
  const prior = { at: "2026-11-01T00:00:00.000Z", submitted: { 99: { submittedAt: null } } };
  const r = await readCanvasSubmissions({ fetchFn: async () => { throw new TypeError("x"); }, now: NOW, prior, sleep: noSleep });
  assert.equal(r.status, "error");
  assert.deepEqual(r.submitted, { 99: { submittedAt: null } });
});

test("readCanvasSubmissions: inside 5 minutes is throttled with no request", async () => {
  const prior = { at: new Date(NOW.getTime() - 4 * 60_000).toISOString(), submitted: { 5: { submittedAt: null } } };
  const c = canvas();
  const r = await readCanvasSubmissions({ fetchFn: c.fetch, now: NOW, prior, sleep: noSleep });
  assert.equal(r.status, "throttled");
  assert.deepEqual(r.submitted, { 5: { submittedAt: null } });
  assert.equal(c.urls.length, 0);
  const old = { at: new Date(NOW.getTime() - 6 * 60_000).toISOString(), submitted: {} };
  assert.equal((await readCanvasSubmissions({ fetchFn: c.fetch, now: NOW, prior: old, sleep: noSleep })).status, "in");
});
