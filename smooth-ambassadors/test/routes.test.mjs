// End-to-end tests against the bundled Worker in Miniflare with a local D1.
// Run: npm test
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const FOUNDER = "test-founder-token-0123456789";
let mf;

before(async () => {
  mkdirSync(join(root, ".wrangler/test"), { recursive: true });
  const out = join(root, ".wrangler/test/worker.js");
  execFileSync(
    join(root, "node_modules/.bin/esbuild"),
    [join(root, "worker/index.js"), "--bundle", "--format=esm", "--platform=browser", `--outfile=${out}`],
    { stdio: "pipe" },
  );
  mf = new Miniflare({
    modules: true,
    scriptPath: out,
    rootPath: root,
    compatibilityDate: "2026-01-01",
    d1Databases: { DB: "test-db" },
    bindings: { FOUNDER_TOKEN: FOUNDER, PUBLIC_ORIGIN: "https://example.test" },
    // Stands in for the static-assets binding: one poster file exists.
    serviceBindings: {
      POSTERS(request) {
        return new URL(request.url).pathname === "/posters/uva/ib.jpg"
          ? new Response(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]), { headers: { "content-type": "image/jpeg" } })
          : new Response("nope", { status: 404 });
      },
    },
  });
  const db = await mf.getD1Database("DB");
  const sql = readFileSync(join(root, "migrations/0001_ambassadors.sql"), "utf8");
  const clean = sql.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n");
  for (const stmt of clean.split(";").map((s) => s.trim()).filter(Boolean)) {
    await db.prepare(stmt).run();
  }
  // Pretend some history exists before the ambassador system.
  await db.prepare("INSERT INTO scans (poster, total) VALUES ('ib', 40), ('umiami/ib', 7), ('jester', 3)").run();
});
after(async () => mf?.dispose());

const get = (p, init) => mf.dispatchFetch("https://example.test" + p, { redirect: "manual", ...init });
const post = (p, data) =>
  mf.dispatchFetch("https://example.test" + p, {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(data).toString(),
  });
const total = async (key) => (await (await mf.getD1Database("DB")).prepare("SELECT total FROM scans WHERE poster = ?1").bind(key).first())?.total ?? 0;

test("existing routes: the dashboard is the live page", async () => {
  const r = await get("/");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "text/html; charset=utf-8");
  assert.equal(r.headers.get("cache-control"), "no-store");
  const page = await r.text();
  assert.match(page, /<title>Smooth Poster Scans<\/title>/);
  assert.match(page, /Poster scan performance/);
  assert.match(page, /fetch\('\/api\/stats'/);
  assert.doesNotMatch(page, /cdn-cgi|__CF\$cv/);
});

test("existing routes: /api/stats lists exactly the live rows, in the live order", async () => {
  const r = await get("/api/stats");
  assert.equal(r.headers.get("content-type"), "application/json");
  assert.equal(r.headers.get("cache-control"), "no-store");
  const s = await r.json();
  assert.deepEqual(Object.keys(s), ["rows"]);
  const live = JSON.parse(readFileSync(join(root, "test/fixtures/live-stats-shape.json"), "utf8")).rows;
  assert.equal(s.rows.length, 62);
  assert.deepEqual(s.rows.map(({ total, ...rest }) => rest), live);
  assert.deepEqual(Object.keys(s.rows[0]), ["school", "schoolName", "poster", "name", "total"]);
  const total = (school, poster) => s.rows.find((x) => x.school === school && x.poster === poster).total;
  assert.equal(total("upenn", "ib"), 40);
  assert.equal(total("umiami", "ib"), 7);
  assert.equal(total("upenn", "jester"), 3);
  assert.equal(total("clark", "venture"), 0);
});

test("unknown routes answer like the live site", async () => {
  for (const p of ["/nope", "/api/nope", "/scan", "/scan/", "/posters/uva/ib.png", "/a/abcdefghijklmn"]) {
    const r = await get(p);
    assert.equal(r.status, 404, p);
    assert.equal(await r.text(), "Not found", p);
    assert.equal(r.headers.get("content-type"), "text/plain;charset=UTF-8", p);
  }
});

test("existing routes: legacy UPenn scan increments bare key and redirects", async () => {
  const r = await get("/scan/ib");
  assert.equal(r.status, 302);
  assert.match(r.headers.get("location"), /apps\.apple\.com.*id6783911002/);
  assert.equal(await total("ib"), 41);
});

test("existing routes: other-school scan increments prefixed key", async () => {
  assert.equal((await get("/scan/uva/soccer")).status, 302);
  assert.equal(await total("uva/soccer"), 1);
  assert.equal((await get("/scan/umiami/ib")).status, 302);
  assert.equal(await total("umiami/ib"), 8);
});

test("existing routes: UPenn-only designs are restricted elsewhere", async () => {
  assert.equal((await get("/scan/jester")).status, 302);
  assert.equal((await get("/scan/uva/jester")).status, 404);
  assert.equal((await get("/scan/clark/regista")).status, 404);
  assert.equal((await get("/scan/nowhere/ib")).status, 404);
  assert.equal((await get("/scan/upenn/nothing")).status, 404);
  assert.equal(await total("uva/jester"), 0);
});

test("poster previews come from the assets binding, and restricted designs never do", async () => {
  const r = await get("/posters/uva/ib.jpg");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "image/jpeg");
  assert.equal((await r.arrayBuffer()).byteLength, 4);
  assert.equal((await get("/posters/uva/jester.jpg")).status, 404); // UPenn-only
  assert.equal((await get("/posters/uva/kylie.jpg")).status, 404); // valid, file missing
  assert.equal((await get("/posters/nowhere/ib.jpg")).status, 404);
});

test("founder view needs the secret", async () => {
  assert.equal((await get("/f/wrong-token-0000000000000")).status, 404);
  assert.equal((await get("/f/" + FOUNDER)).status, 200);
});

let token;
test("founder adds an ambassador and gets a private link", async () => {
  const r = await post(`/f/${FOUNDER}/add`, { name: "Test Friend", school: "uva", contact: "(555) 010-2020", notes: "" });
  assert.equal(r.status, 303);
  token = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
  assert.ok(token && token.length >= 14);
  const page = await (await get(`/f/${FOUNDER}?created=${token}`)).text();
  assert.match(page, new RegExp(`/a/${token}`));
  assert.match(page, /sms:\+15550102020&body=/);
  assert.match(page, /Test Friend/);
});

test("ambassador page shows own data only, never contacts of others", async () => {
  const r = await get(`/a/${token}`);
  assert.equal(r.status, 200);
  const t = await r.text();
  assert.match(t, /hey Test/);
  assert.match(t, /uva posters/);
  assert.doesNotMatch(t, /555/); // their own phone is not echoed either
  assert.doesNotMatch(t, /jester/); // UPenn-only design hidden for UVA
  assert.equal((await get(`/a/notatoken12345`)).status, 404);
});

test("share link counts for the ambassador and redirects", async () => {
  const r = await get(`/a/${token}/s/gc`);
  assert.equal(r.status, 302);
  assert.match(r.headers.get("location"), /apps\.apple\.com/);
  const me = await (await get(`/a/${token}/me.json`)).json();
  assert.equal(me.linkOpens, 1);
  assert.equal(me.posterOpens, 0);
});

test("ambassador poster code counts for school AND ambassador", async () => {
  const before = await total("uva/ib");
  const r = await get(`/a/${token}/p/ib`);
  assert.equal(r.status, 302);
  assert.equal(await total("uva/ib"), before + 1);
  const me = await (await get(`/a/${token}/me.json`)).json();
  assert.equal(me.posterOpens, 1);
  assert.equal((await get(`/a/${token}/p/jester`)).status, 404);
});

test("two-tap drop log, post log, checklist, feedback, pause", async () => {
  assert.equal((await post(`/a/${token}/drop`, { design: "soccer", copies: "3", place: "clemons" })).status, 303);
  assert.equal((await post(`/a/${token}/drop`, { design: "jester", copies: "1" })).status, 400);
  assert.equal((await post(`/a/${token}/post`, { channel: "fizz", place: "" })).status, 303);
  assert.equal((await post(`/a/${token}/check`, { step: "download", done: "1" })).status, 303);
  assert.equal((await post(`/a/${token}/feedback`, { body: "the reconnect canvas button is hard to find" })).status, 303);
  assert.equal((await post(`/a/${token}/pause`, { weeks: "4" })).status, 303);
  const me = await (await get(`/a/${token}/me.json`)).json();
  assert.equal(me.drops, 3);
  assert.equal(me.posts, 1);
  assert.deepEqual(me.checked, ["download"]);
  const page = await (await get(`/a/${token}`)).text();
  assert.match(page, /paused until/);
});

test("stickers page renders a QR per design", async () => {
  const t = await (await get(`/a/${token}/stickers`)).text();
  assert.equal((t.match(/<svg /g) || []).length, 12);
  assert.match(t, new RegExp(`/a/${token}/p/`) ? /qr/ : /x/);
});

test("founder view reflects everything and digest skips paused", async () => {
  const t = await (await get(`/f/${FOUNDER}`)).text();
  assert.match(t, /the reconnect canvas button/);
  assert.match(t, /3 × soccer/);
  assert.match(t, /paused, skip/);
  const ex = await (await get(`/f/${FOUNDER}/export.json`)).json();
  assert.equal(ex.ambassadors.length, 1);
  assert.equal(ex.ambassadors[0].contact, "(555) 010-2020");
  // reminders bookkeeping
  const id = ex.ambassadors[0].id;
  assert.equal((await post(`/f/${FOUNDER}/reminder`, { id, kind: "digest" })).status, 303);
  assert.equal((await post(`/f/${FOUNDER}/replied`, { id })).status, 303);
  assert.equal((await post(`/f/${FOUNDER}/update`, { id, status: "active", title: "campus lead", contact: "(555) 010-2020", notes: "" })).status, 303);
  const ex2 = await (await get(`/f/${FOUNDER}/export.json`)).json();
  assert.equal(ex2.ambassadors[0].title, "campus lead");
  assert.equal(ex2.ambassadors[0].lastReminder.replied, 1);
});

test("public leaderboard has schools only, no people", async () => {
  const lb = await (await get("/api/leaderboard")).json();
  assert.equal(lb.schools.length, 5);
  const text = JSON.stringify(lb);
  assert.doesNotMatch(text, /Test Friend|555|token/);
  const uva = lb.schools.find((s) => s.school === "uva");
  assert.equal(uva.linkOpensRecent, 1);
  assert.ok(uva.recent >= 2);
});

test("plan.json: today's post carries the ambassador's link and their anon app", async () => {
  const r = await get(`/a/${token}/plan.json?anon=sidechat&tz=300`);
  assert.equal(r.status, 200);
  const p = await r.json();
  assert.equal(p.school, "uva");
  assert.equal(p.schoolName, "UVA");
  assert.ok(p.today && typeof p.today.text === "string");
  if (p.today.kind === "anon") {
    assert.equal(p.today.channel, "sidechat");
    assert.match(p.today.text, new RegExp(`https://example.test/a/${token}/s/sidechat`));
  }
  if (p.today.channel) assert.match(p.today.text, /example\.test\/a\//);
  assert.equal(p.checklist.find((c) => c.key === "download").done, true);
  assert.equal(p.messages.length, 6);
  assert.ok(p.numbers.linkOpens >= 1);
  assert.doesNotMatch(JSON.stringify(p), /555/);
  // The same day gives the same post; the next day moves on.
  const again = await (await get(`/a/${token}/plan.json?anon=sidechat&tz=300`)).json();
  assert.equal(again.today.dayIndex, p.today.dayIndex);
});

test("the app's posts get JSON instead of a redirect", async () => {
  const r = await mf.dispatchFetch(`https://example.test/a/${token}/post`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ channel: "sidechat", place: "daily" }),
  });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true, message: "logged. thank you." });
  const me = await (await get(`/a/${token}/me.json`)).json();
  assert.equal(me.posts, 2);
});

test("every daily entry has a kind the plan understands", async () => {
  const m = JSON.parse(readFileSync(join(root, "worker/templates/messages.json"), "utf8"));
  assert.ok(m.daily.length >= 10);
  for (const d of m.daily) assert.ok(["anon", "gc", "ig", "dm", "rest"].includes(d.kind), d.kind);
  assert.ok(m.daily.filter((d) => d.kind === "anon").length >= 7);
});
