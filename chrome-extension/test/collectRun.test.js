import { test } from "node:test";
import assert from "node:assert/strict";
import { collectRun, KEYS, INTERVAL_MS, RATE_LIMIT_BACKOFF_MS } from "../src/collectRun.js";

const T0 = new Date(2026, 9, 22, 15, 0, 0).getTime(); // local 15:00
const MIDNIGHT = new Date(2026, 9, 23, 0, 0, 0).getTime();
const noSleep = async () => {};

function fakeStorage(init = {}) {
  const data = { ...init };
  return {
    data,
    async get(k) { return typeof k === "string" ? (k in data ? { [k]: data[k] } : {}) : { ...data }; },
    async set(o) { Object.assign(data, o); },
    async remove(k) { for (const x of [].concat(k)) delete data[x]; },
  };
}

const reply = (body, status = 200) => ({
  status, ok: status >= 200 && status < 300, url: "",
  headers: { get: () => null }, text: async () => "while(1);" + JSON.stringify(body),
});

// Canvas with two courses; `limit` makes every course-level request 429.
function canvas({ limit = false, gate } = {}) {
  const log = { urls: [] };
  const fetch = async (url) => {
    log.urls.push(url);
    if (gate) await gate;
    const u = new URL(url);
    if (limit && u.pathname !== "/api/v1/courses") return reply("", 429);
    if (u.pathname === "/api/v1/courses") return reply([{ id: 111, name: "CIS 2400-001 X 202630", course_code: "CIS 2400" }]);
    if (/\/courses\/111$/.test(u.pathname)) return reply({ id: 111, syllabus_body: "<p>syllabus</p>" });
    return reply([]);
  };
  return { fetch, log };
}

function backend({ answer = {}, fail = {}, followUp } = {}) {
  const calls = [];
  const callFunction = async (name, body) => {
    calls.push({ name, body: structuredClone(body) });
    if (name === "extract-profile" || name === "discover-websites") {
      if (followUp) return followUp(name);
      return {};
    }
    const err = fail[body.action];
    if (err) throw Object.assign(new Error(err), { kind: err });
    if (body.action === "manifest") return { serverManifest: [], download: [] };
    return { accepted: body.documents.length, profileStale: [], websitesPending: [], ...answer };
  };
  return { callFunction, calls };
}

const paired = (extra = {}) => fakeStorage({ [KEYS.pairingKey]: "k", ...extra });
const run = (o) => collectRun({ sessionStorage: fakeStorage(), now: () => T0, sleep: noSleep, ...o });
const names = (b) => b.calls.map((c) => c.name);

test("unpaired: no-op, nothing fetched or stored", async () => {
  const storage = fakeStorage(), c = canvas(), b = backend();
  const r = await run({ fetch: c.fetch, callFunction: b.callFunction, storage });
  assert.equal(r.status, "unpaired");
  assert.equal(c.log.urls.length, 0);
  assert.deepEqual(storage.data, {});
});

test("hourly throttle", async () => {
  const storage = paired(), c = canvas(), b = backend();
  assert.equal((await run({ fetch: c.fetch, callFunction: b.callFunction, storage })).status, "ok");
  assert.equal(storage.data[KEYS.lastRun], T0);
  const n = c.log.urls.length;
  const r = await run({ fetch: c.fetch, callFunction: b.callFunction, storage, now: () => T0 + INTERVAL_MS - 1 });
  assert.equal(r.status, "throttled");
  assert.equal(c.log.urls.length, n);
  const r2 = await run({ fetch: c.fetch, callFunction: b.callFunction, storage, now: () => T0 + INTERVAL_MS });
  assert.equal(r2.status, "ok");
});

test("rate limit: 6 hour backoff, then runs again", async () => {
  const storage = paired(), b = backend();
  const r = await run({ fetch: canvas({ limit: true }).fetch, callFunction: b.callFunction, storage });
  assert.equal(r.summary.rateLimited, true);
  assert.equal(storage.data[KEYS.backoffUntil], T0 + RATE_LIMIT_BACKOFF_MS);
  const c = canvas();
  const during = await run({ fetch: c.fetch, callFunction: b.callFunction, storage, now: () => T0 + RATE_LIMIT_BACKOFF_MS - 1 });
  assert.equal(during.status, "backoff");
  assert.equal(c.log.urls.length, 0);
  const after = await run({ fetch: c.fetch, callFunction: b.callFunction, storage, now: () => T0 + RATE_LIMIT_BACKOFF_MS });
  assert.equal(after.status, "ok");
});

test("quota: backs off until next local midnight; holdings and filesSeen persisted on the stop", async () => {
  const storage = paired({ [KEYS.holdings]: { 111: [{ id: "page:old", contentHash: "h" }] } });
  const b = backend({ fail: { upload: "quota" } });
  const c = canvas();
  const r = await run({ fetch: c.fetch, callFunction: b.callFunction, storage, extractText: async () => "" });
  assert.equal(r.summary.stopped, "quota");
  assert.equal(storage.data[KEYS.backoffUntil], MIDNIGHT);
  assert.ok(Array.isArray(storage.data[KEYS.holdings]["111"]));
  assert.ok(storage.data[KEYS.holdings]["111"].some((h) => h.id.startsWith("syllabus")));
  assert.ok(KEYS.filesSeen in storage.data);
  assert.ok(KEYS.summary in storage.data);
  assert.equal(storage.data[KEYS.summary].stopped, "quota");
});

test("quota on the manifest step still persists holdings and summary", async () => {
  const held = { 111: [{ id: "page:old", contentHash: "h" }] };
  const storage = paired({ [KEYS.holdings]: held });
  const b = backend({ fail: { manifest: "quota" } });
  await run({ fetch: canvas().fetch, callFunction: b.callFunction, storage });
  assert.deepEqual(storage.data[KEYS.holdings], held);
  assert.equal(storage.data[KEYS.backoffUntil], MIDNIGHT);
});

test("follow-ups: extract-profile once, discover-websites in groups of 3, errors swallowed", async () => {
  const storage = paired();
  const b = backend({
    answer: { profileStale: ["111"], websitesPending: ["1", "2", "3", "4", "5", "6", "7"] },
    followUp: () => { throw Object.assign(new Error("boom"), { kind: "server" }); },
  });
  const r = await run({ fetch: canvas().fetch, callFunction: b.callFunction, storage });
  assert.equal(r.status, "ok");
  const ex = b.calls.filter((c) => c.name === "extract-profile");
  const dw = b.calls.filter((c) => c.name === "discover-websites");
  assert.deepEqual(ex.map((c) => c.body), [{ courseIDs: ["111"] }]);
  assert.deepEqual(dw.map((c) => c.body.courseIDs), [["1", "2", "3"], ["4", "5", "6"], ["7"]]);
  assert.equal(storage.data[KEYS.summary].profileStale, 1);
  assert.equal(storage.data[KEYS.summary].websitesPending, 7);
});

test("follow-ups are not awaited and rejections do not surface", async () => {
  const storage = paired();
  const b = backend({ answer: { profileStale: ["111"] }, followUp: () => new Promise((_, rej) => setTimeout(() => rej(new Error("late")), 20)) });
  const r = await run({ fetch: canvas().fetch, callFunction: b.callFunction, storage });
  assert.equal(r.status, "ok");
  await new Promise((res) => setTimeout(res, 40)); // an unhandled rejection would fail the run
});

test("summary holds counts and words only", async () => {
  const storage = paired(), b = backend();
  await run({ fetch: canvas().fetch, callFunction: b.callFunction, storage });
  const s = storage.data[KEYS.summary];
  assert.equal(s.canvas, "in");
  assert.equal(s.courses, 1);
  assert.ok(!JSON.stringify(s).includes("syllabus</"));
});

test("never throws and never runs concurrently", async () => {
  const storage = paired(), b = backend();
  let release;
  const gate = new Promise((r) => { release = r; });
  const c = canvas({ gate });
  const p1 = run({ fetch: c.fetch, callFunction: b.callFunction, storage });
  const p2 = run({ fetch: c.fetch, callFunction: b.callFunction, storage });
  assert.equal(p1, p2);
  release();
  await p1;
  assert.equal(c.log.urls.filter((u) => u.endsWith("/api/v1/courses?enrollment_state=active&per_page=100")).length <= 1, true);
  const bad = await collectRun({ storage: { get: async () => { throw new Error("x"); } } });
  assert.equal(bad.status, "error");
  assert.deepEqual((await collectRun()).status, "error");
});
