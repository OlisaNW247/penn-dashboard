// Proves the single-file build (scripts/build-sites.mjs) against the untouched
// original: every existing route answers identically, and the ambassador system
// works inside the edited file. Run: npm run test:sites with
//   SITES_ORIGINAL = the untouched worker/index.js
//   SITES_EDITED   = the edited repository's dist/server/index.js
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { Miniflare } from "miniflare";

const { SITES_ORIGINAL, SITES_EDITED } = process.env;
const skip = SITES_ORIGINAL && SITES_EDITED ? false : "set SITES_ORIGINAL and SITES_EDITED to run";
const FOUNDER = "test-founder-token-0123456789";
const ORIGIN = "https://example.test";
let orig, edited, fresh;

const make = (file, extra = {}) =>
  new Miniflare({
    modules: [{ type: "ESModule", path: "index.js", contents: readFileSync(file, "utf8") }],
    compatibilityDate: "2026-01-01",
    d1Databases: { DB: "db" },
    ...extra,
  });
const SCANS = "CREATE TABLE IF NOT EXISTS scans (poster TEXT PRIMARY KEY, total INTEGER NOT NULL)";

before(async () => {
  if (skip) return;
  orig = make(SITES_ORIGINAL);
  edited = make(SITES_EDITED, { bindings: { FOUNDER_TOKEN: FOUNDER } });
  fresh = make(SITES_EDITED, { bindings: { FOUNDER_TOKEN: FOUNDER } });
  for (const mf of [orig, edited]) {
    const db = await mf.getD1Database("DB");
    await db.prepare(SCANS).run();
    await db.prepare("INSERT INTO scans (poster, total) VALUES ('ib', 40), ('umiami/ib', 7), ('jester', 3)").run();
  }
});
after(async () => {
  await Promise.all([orig, edited, fresh].map((m) => m?.dispose()));
});

const req = (mf, path, init) => mf.dispatchFetch(ORIGIN + path, { redirect: "manual", ...init });
const total = async (mf, key) =>
  (await (await mf.getD1Database("DB")).prepare("SELECT total FROM scans WHERE poster = ?1").bind(key).first())?.total ?? null;
const HEADERS = ["content-type", "cache-control", "location", "allow"];
const sha = (buf) => createHash("sha256").update(Buffer.from(buf)).digest("hex");

async function snapshot(mf, path, init) {
  const r = await req(mf, path, init);
  const body = await r.arrayBuffer();
  return { status: r.status, headers: HEADERS.map((h) => [h, r.headers.get(h)]), body: sha(body) };
}

const cases = [
  ["GET", "/"],
  ["GET", "/?school=uva"],
  ["GET", "/api/stats"],
  ["GET", "/scan/ib"],
  ["GET", "/scan/uva/ib"],
  ["GET", "/scan/uva/jester"],
  ["GET", "/scan/nope"],
  ["GET", "/scan/a/b/c"],
  ["GET", "/posters/upenn/ib.jpg"],
  ["GET", "/posters/upenn/nope.jpg"],
  ["GET", "/nope"],
  ["POST", "/"],
  ["POST", "/scan/ib"],
  ["POST", "/api/stats"],
  ["OPTIONS", "/"],
];

test("parity: existing routes answer identically", { skip }, async () => {
  const statuses = {};
  for (const [method, path] of cases) {
    const a = await snapshot(orig, path, { method });
    const b = await snapshot(edited, path, { method });
    assert.deepEqual(b, a, `${method} ${path}`);
    statuses[`${method} ${path}`] = a.status;
  }
  // The cases really exercised what they claim.
  assert.equal(statuses["GET /scan/ib"], 302);
  assert.equal(statuses["GET /scan/uva/jester"], 404);
  assert.equal(statuses["GET /posters/upenn/ib.jpg"], 200);
  assert.equal(statuses["POST /"], 405);
});

test("parity: counters and stats after the scans", { skip }, async () => {
  // The loop above scanned /scan/ib and /scan/uva/ib once each on both instances.
  for (const mf of [orig, edited]) {
    assert.equal(await total(mf, "ib"), 41);
    assert.equal(await total(mf, "uva/ib"), 1);
  }
  assert.deepEqual(await snapshot(edited, "/api/stats"), await snapshot(orig, "/api/stats"));
});

test("parity: near-miss paths stay the host's plain 404", { skip }, async () => {
  for (const path of ["/api/leaderboard/", "/api//leaderboard", "/r", "/r/x"]) {
    const a = await req(orig, path);
    const b = await req(edited, path);
    assert.equal(b.status, a.status, path);
    assert.equal(a.status, 404, path);
    assert.equal(await b.text(), await a.text(), path);
  }
});

test("the original has no ambassador routes", { skip }, async () => {
  assert.equal((await req(orig, "/a/whatever/plan.json")).status, 404);
  assert.equal((await req(orig, "/a/whatever/plan.json", { method: "POST" })).status, 405);
});

const json = (mf, path, method, data) =>
  req(mf, path, {
    method,
    headers: { "content-type": "application/json", accept: "application/json" },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
let token;
let ref;

test("unknown code and founder secret", { skip }, async () => {
  assert.equal((await req(edited, "/a/aaaaaaaaaaaaaa/plan.json")).status, 404);
  assert.equal((await json(edited, "/a/aaaaaaaaaaaaaa/post", "POST", { channel: "fizz" })).status, 404);
  assert.equal((await req(edited, "/f/wrong-secret-0123456789abcdef")).status, 404);
  const r = await req(edited, `/f/${FOUNDER}/add`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ name: "Test Friend", school: "uva", contact: "", notes: "" }).toString(),
  });
  assert.equal(r.status, 303);
  token = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
  assert.ok(token && token.length >= 14);
  const ex = await (await req(edited, `/f/${FOUNDER}/export.json`)).json();
  ref = ex.ambassadors.find((a) => a.token === token).ref;
  assert.match(ref, /^[a-z2-9]{10}$/);
});

test("the app's contract: plan.json and the five POSTs", { skip }, async () => {
  const plan = async () => {
    const r = await req(edited, `/a/${token}/plan.json?anon=sidechat&tz=300`, { headers: { accept: "application/json" } });
    assert.equal(r.status, 200);
    return r.json();
  };
  const p = await plan();
  assert.equal(typeof p.name, "string");
  assert.equal(p.school, "uva");
  assert.equal(typeof p.numbers, "object");
  assert.equal(typeof p.today.kind, "string");
  assert.equal(typeof p.today.text, "string");
  assert.ok(Array.isArray(p.messages));
  assert.ok(Array.isArray(p.checklist));
  const step = p.checklist[0].key;
  const calls = [
    ["post", { channel: p.today.channel || "sidechat", place: "daily" }],
    ["check", { step, done: "1" }],
    ["feedback", { body: "hello" }],
    ["pause", { weeks: "4" }],
    ["pause", { weeks: "0" }],
  ];
  for (const [action, data] of calls) {
    const r = await json(edited, `/a/${token}/${action}`, "POST", data);
    assert.ok(r.status >= 200 && r.status < 300, `${action} ${r.status}`);
    assert.equal((await r.json()).ok, true, action);
  }
  const after = await plan();
  assert.ok(after.numbers.posts >= 1);
  assert.equal(after.checklist.find((c) => c.key === step).done, true);
});

test("ambassador poster link counts once and matches /scan", { skip }, async () => {
  const plain = await req(edited, "/scan/uva/ib");
  const before = await total(edited, "uva/ib");
  const r = await req(edited, `/r/${ref}/p/ib`);
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), plain.headers.get("location"));
  assert.equal(r.headers.get("cache-control"), plain.headers.get("cache-control"));
  assert.equal(await total(edited, "uva/ib"), before + 1);
  const all = async () => JSON.stringify((await (await edited.getD1Database("DB")).prepare("SELECT * FROM scans ORDER BY poster").all()).results);
  const snap = await all();
  assert.equal((await req(edited, `/r/${ref}/p/jester`)).status, 404);
  assert.equal(await all(), snap);
});

test("share link redirects to the App Store and leaves scans alone", { skip }, async () => {
  const db = await edited.getD1Database("DB");
  const snap = JSON.stringify((await db.prepare("SELECT * FROM scans ORDER BY poster").all()).results);
  const r = await req(edited, `/r/${ref}/s/sidechat`);
  assert.equal(r.status, 302);
  assert.match(r.headers.get("location"), /^https:\/\/apps\.apple\.com\/us\/app\/smooth-for-students\/id6783911002/);
  assert.equal(JSON.stringify((await db.prepare("SELECT * FROM scans ORDER BY poster").all()).results), snap);
});

test("a plain scan is also logged with a timestamp", { skip }, async () => {
  const db = await edited.getD1Database("DB");
  const count = async () =>
    (await db.prepare("SELECT COUNT(*) AS n FROM scan_events WHERE poster = 'uva/ib' AND ambassador_id IS NULL").first()).n;
  const before = await count();
  assert.equal((await req(edited, "/scan/uva/ib")).status, 302);
  let n = before;
  for (let i = 0; i < 50 && n === before; i++) {
    await new Promise((r) => setTimeout(r, 50));
    n = await count();
  }
  assert.equal(n, before + 1);
});

test("an empty database: tables are created lazily", { skip }, async () => {
  const stats = await req(fresh, "/api/stats");
  assert.equal(stats.status, 200);
  assert.equal((await stats.json()).rows.length, 62);
  assert.equal((await req(fresh, "/a/aaaaaaaaaaaaaa/plan.json")).status, 404);
});

// ---- the private code never appears in anything posted or printed

const dbCount = async (table) => (await (await edited.getD1Database("DB")).prepare(`SELECT COUNT(*) n FROM ${table}`).first()).n;
const scansSnap = async () => JSON.stringify((await (await edited.getD1Database("DB")).prepare("SELECT * FROM scans ORDER BY poster").all()).results);

test("the token is nowhere in posts or stickers, and the old routes are gone", { skip }, async () => {
  const plan = await (await req(edited, `/a/${token}/plan.json?anon=fizz&tz=300`)).json();
  const texts = [plan.today.text, ...plan.messages.map((m) => m.text)];
  for (const t of texts) assert.ok(!t.includes(token), t);
  for (const t of texts)
    for (const m of t.match(/https?:\/\/\S*\/(?:a|r)\/\S+/g) || []) assert.match(m, new RegExp(`/r/${ref}/`), m);
  assert.ok(plan.messages.some((m) => m.text.includes(`/r/${ref}/s/`)));
  assert.match(plan.page, new RegExp(`/a/${token}$`));
  assert.ok(!(await (await req(edited, `/a/${token}/stickers`)).text()).includes(token));
  const page = await (await req(edited, `/a/${token}`)).text();
  assert.doesNotMatch(page, new RegExp(`/a/${token}/(s|p)/`));
  assert.match(page, new RegExp(`/r/${ref}/s/`));

  const [scans, hits] = [await scansSnap(), await dbCount("amb_hits")];
  for (const p of [`/a/${token}/s/fizz`, `/a/${token}/p/ib`]) assert.equal((await req(edited, p)).status, 404, p);
  assert.equal(await scansSnap(), scans);
  assert.equal(await dbCount("amb_hits"), hits);

  assert.equal((await req(edited, `/a/${ref}`)).status, 404);
  assert.equal((await req(edited, `/a/${ref}/plan.json`)).status, 404);
  assert.equal((await req(edited, `/r/${ref}/s/fizz`, { method: "POST" })).status, 405);
  assert.equal((await req(edited, `/r/aaaaaaaaaa/s/fizz`)).status, 404);
});

test("school scan through the ref counts once; a share link does not touch scans", { skip }, async () => {
  const before = await total(edited, "uva/soccer");
  assert.equal((await req(edited, `/r/${ref}/p/soccer`)).status, 302);
  assert.equal(await total(edited, "uva/soccer"), (before ?? 0) + 1);
  const snap = await scansSnap();
  assert.equal((await req(edited, `/r/${ref}/s/fizz`)).status, 302);
  assert.equal(await scansSnap(), snap);
  const db = await edited.getD1Database("DB");
  const n = async () => (await db.prepare("SELECT COUNT(*) n FROM amb_hits WHERE key = 'other'").first()).n;
  const o = await n();
  assert.equal((await req(edited, `/r/${ref}/s/constructor`)).status, 302);
  assert.equal(await n(), o + 1);
});

test("bad bodies are a clean 4xx and write nothing", { skip }, async () => {
  const tables = ["activity", "checklist", "feedback"];
  const counts = () => Promise.all(tables.map(dbCount));
  const before = await counts();
  const send = (action, body, ct = "application/json") =>
    req(edited, `/a/${token}/${action}`, { method: "POST", headers: { "content-type": ct, accept: "application/json" }, body });
  const cases = [
    ["post", "{not json", 400],
    ["post", "", 400],
    ["post", "null", 400],
    ["post", "channel=fizz", 400, "text/plain"],
    ["feedback", JSON.stringify({ body: { a: 1 } }), 400],
    ["feedback", JSON.stringify({ body: "x".repeat(20000) }), 413],
    ["post", JSON.stringify({ channel: "constructor" }), 400],
    ["check", JSON.stringify({ step: "nope" }), 400],
  ];
  for (const [action, body, want, ct] of cases) {
    const r = await send(action, body, ct);
    assert.equal(r.status, want, `${action} ${body.slice(0, 30)}`);
  }
  assert.deepEqual(await counts(), before);
  const p = await send("pause", JSON.stringify({ weeks: "99999999999999" }));
  assert.equal(p.status, 200);
  const plan = await (await req(edited, `/a/${token}/plan.json?anon=constructor&tz=abc`)).json();
  assert.equal(typeof plan.today.platform, "string");
});

test("a left ambassador's code stops working, their stickers still count the school", { skip }, async () => {
  const ex = await (await req(edited, `/f/${FOUNDER}/export.json`)).json();
  const id = ex.ambassadors.find((a) => a.token === token).id;
  const r = await req(edited, `/f/${FOUNDER}/update`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ id, status: "left" }).toString(),
  });
  assert.equal(r.status, 303);
  assert.equal((await req(edited, `/a/${token}/plan.json`)).status, 404);
  const [school, hits] = [await total(edited, "uva/ib"), await dbCount("amb_hits")];
  assert.equal((await req(edited, `/r/${ref}/p/ib`)).status, 302);
  assert.equal(await total(edited, "uva/ib"), school + 1);
  assert.equal(await dbCount("amb_hits"), hits);
});
