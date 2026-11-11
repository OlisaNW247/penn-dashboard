// End-to-end tests against the bundled Worker in Miniflare with a local D1.
// Run: npm test
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { ideaTests } from "./ideas-suite.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const FOUNDER = "test-founder-token-0123456789";
let mf;

before(async () => {
  mkdirSync(join(root, ".wrangler/test"), { recursive: true });
  const out = join(root, ".wrangler/test/worker.js");
  execFileSync(
    join(root, "node_modules/.bin/esbuild"),
    [join(root, "worker/index.js"), "--bundle", "--format=esm", "--platform=browser", "--loader:.woff2=base64", `--outfile=${out}`],
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
  const sql = ["0001_ambassadors.sql", "0002_poster_ideas.sql"].map((f) => readFileSync(join(root, "migrations", f), "utf8")).join("\n");
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
let ref;
test("founder adds an ambassador and gets a private link", async () => {
  const r = await post(`/f/${FOUNDER}/add`, { name: "Test Friend", school: "uva", contact: "(555) 010-2020", notes: "" });
  assert.equal(r.status, 303);
  token = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
  assert.ok(token && token.length >= 14);
  assert.match(token, /^uva-[a-z0-9]{14}$/, "a new code starts with its school");
  const page = await (await get(`/f/${FOUNDER}?created=${token}`)).text();
  assert.match(page, new RegExp(`/a/${token}`));
  assert.match(page, /sms:\+15550102020&body=/);
  assert.match(page, /Test Friend/);
  const ex = await (await get(`/f/${FOUNDER}/export.json`)).json();
  ref = ex.ambassadors[0].ref;
  assert.match(ref, /^[a-z2-9]{10}$/);
  assert.notEqual(ref, token.slice(0, 10));
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
  const r = await get(`/r/${ref}/s/gc`);
  assert.equal(r.status, 302);
  assert.match(r.headers.get("location"), /apps\.apple\.com/);
  const me = await (await get(`/a/${token}/me.json`)).json();
  assert.equal(me.linkOpens, 1);
  assert.equal(me.posterOpens, 0);
});

test("ambassador poster code counts for school AND ambassador", async () => {
  const before = await total("uva/ib");
  const r = await get(`/r/${ref}/p/ib`);
  assert.equal(r.status, 302);
  assert.equal(await total("uva/ib"), before + 1);
  const me = await (await get(`/a/${token}/me.json`)).json();
  assert.equal(me.posterOpens, 1);
  assert.equal((await get(`/r/${ref}/p/jester`)).status, 404);
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
  assert.equal((t.match(/<svg class="qr"/g) || []).length, 12);
  assert.doesNotMatch(t, new RegExp(token));
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
    assert.match(p.today.text, new RegExp(`https://example.test/r/${ref}/s/sidechat`));
  }
  if (p.today.channel) assert.match(p.today.text, /example\.test\/r\//);
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

// ---- the private code never appears in anything posted or printed

const count = async (table, where = "1=1") =>
  (await (await mf.getD1Database("DB")).prepare(`SELECT COUNT(*) n FROM ${table} WHERE ${where}`).first()).n;
const scanTotals = async () =>
  JSON.stringify((await (await mf.getD1Database("DB")).prepare("SELECT * FROM scans ORDER BY poster").all()).results);
const hits = () => count("amb_hits");

test("the token is nowhere in posts, messages or stickers; only the ref is", async () => {
  const plan = await (await get(`/a/${token}/plan.json?anon=fizz&tz=300`)).json();
  const texts = [plan.today.text, ...plan.messages.map((m) => m.text)];
  for (const t of texts) assert.ok(!t.includes(token), t);
  for (const t of texts)
    for (const m of t.match(/https?:\/\/\S*\/(?:a|r)\/\S+/g) || []) assert.match(m, new RegExp(`/r/${ref}/`), m);
  assert.ok(plan.messages.some((m) => m.text.includes(`/r/${ref}/s/`)));
  assert.match(plan.page, new RegExp(`/a/${token}$`));
  const stickers = await (await get(`/a/${token}/stickers`)).text();
  assert.ok(!stickers.includes(token), "stickers page");
  const page = await (await get(`/a/${token}`)).text();
  assert.doesNotMatch(page, new RegExp(`/a/${token}/(s|p)/`));
  assert.match(page, new RegExp(`/r/${ref}/s/`));
});

test("the old token share and poster routes are gone and count nothing", async () => {
  const [scansBefore, hitsBefore] = [await scanTotals(), await hits()];
  for (const p of [`/a/${token}/s/fizz`, `/a/${token}/p/ib`]) {
    assert.equal((await get(p)).status, 404, p);
    assert.equal((await post(p, { x: "1" })).status, 404, p);
  }
  assert.equal(await scanTotals(), scansBefore);
  assert.equal(await hits(), hitsBefore);
});

test("the public ref opens nothing private", async () => {
  assert.equal((await get(`/a/${ref}`)).status, 404);
  assert.equal((await get(`/a/${ref}/plan.json`)).status, 404);
  assert.equal((await post(`/a/${ref}/post`, { channel: "fizz" })).status, 404);
  assert.equal((await get(`/r/${ref}`)).status, 404);
  assert.equal((await get(`/r/${ref}/plan.json`)).status, 404);
  assert.equal((await get(`/r/${token}/s/fizz`)).status, 404); // the token is not a ref
  assert.equal((await get(`/r/aaaaaaaaaa/s/fizz`)).status, 404);
  assert.equal((await post(`/r/${ref}/s/fizz`, { a: "1" })).status, 405);
  assert.equal((await get(`/r/${ref}/s/fizz`)).status, 302);
});

test("a school poster scan counts for the school; a share link leaves scans alone", async () => {
  const before = await total("uva/soccer");
  assert.equal((await get(`/r/${ref}/p/soccer`)).status, 302);
  assert.equal(await total("uva/soccer"), before + 1);
  const snap = await scanTotals();
  assert.equal((await get(`/r/${ref}/s/fizz`)).status, 302);
  assert.equal(await scanTotals(), snap);
});

test("/r/{ref}/s/{weird channel} is recorded as other", async () => {
  const db = await mf.getD1Database("DB");
  const n = async (k) => (await db.prepare("SELECT COUNT(*) n FROM amb_hits WHERE kind='link' AND key=?1").bind(k).first()).n;
  const [o, c] = [await n("other"), await n("constructor")];
  assert.equal((await get(`/r/${ref}/s/constructor`)).status, 302);
  assert.equal(await n("other"), o + 1);
  assert.equal(await n("constructor"), c);
});

test("bad bodies are a clean 4xx and write nothing", async () => {
  const tables = ["activity", "checklist", "feedback"];
  const counts = async () => Promise.all(tables.map((t) => count(t)));
  const before = await counts();
  const send = (path, body, ct = "application/json", extra = {}) =>
    mf.dispatchFetch(`https://example.test${path}`, { method: "POST", redirect: "manual", headers: { "content-type": ct, accept: "application/json", ...extra }, body });
  const cases = [
    ["post", "{not json", 400],
    ["post", "", 400],
    ["post", "null", 400],
    ["post", "[1,2]", 400],
    ["post", "channel=fizz", 400, "text/plain"],
    ["feedback", JSON.stringify({ body: { a: 1 } }), 400],
    ["feedback", JSON.stringify({ body: "   " }), 400],
    ["feedback", JSON.stringify({ body: "x".repeat(20000) }), 413],
    ["post", JSON.stringify({ channel: "constructor" }), 400],
    ["post", JSON.stringify({ channel: "__proto__" }), 400],
    ["post", JSON.stringify({ channel: ["fizz"] }), 400],
    ["check", JSON.stringify({ step: "nope" }), 400],
    ["drop", JSON.stringify({ design: "toString" }), 400],
  ];
  for (const [action, body, want, ct] of cases) {
    const r = await send(`/a/${token}/${action}`, body, ct);
    assert.equal(r.status, want, `${action} ${body.slice(0, 30)}`);
    assert.ok(r.status < 500);
  }
  assert.deepEqual(await counts(), before);
  // Too large by header alone.
  const r = await send(`/a/${token}/feedback`, JSON.stringify({ body: "hi" }), "application/json", { "content-length": "99999" }).catch(() => null);
  if (r) assert.ok(r.status === 413 || r.status === 400);
  assert.deepEqual(await counts(), before);
});

test("pause clamps and plan.json shrugs off odd query values", async () => {
  const r = await mf.dispatchFetch(`https://example.test/a/${token}/pause`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ weeks: "99999999999999" }),
  });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).message, "paused for 12 weeks.");
  const p = await (await get(`/a/${token}/plan.json?anon=constructor&tz=abc`)).json();
  assert.equal(typeof p.today.platform, "string");
  assert.equal((await get(`/a/${token}/plan.json?tz=99999999999`)).status, 200);
});

test("a name with </script> cannot break the founder page", async () => {
  const r = await post(`/f/${FOUNDER}/add`, { name: "</script><b>x", school: "uva", contact: "", notes: "" });
  assert.equal(r.status, 303);
  const t = await (await get(`/f/${FOUNDER}`)).text();
  const scripts = t.split("<script>")[1].split("</script>")[0];
  assert.ok(scripts.includes("MOMENTS"));
  assert.ok(!scripts.includes("</script"));
});

test("a left ambassador's code stops working, their stickers still count the school", async () => {
  const ex = await (await get(`/f/${FOUNDER}/export.json`)).json();
  const id = ex.ambassadors.find((a) => a.token === token).id;
  assert.equal((await post(`/f/${FOUNDER}/update`, { id, status: "left" })).status, 303);
  assert.equal((await get(`/a/${token}/plan.json`)).status, 404);
  assert.equal((await get(`/a/${token}`)).status, 404);
  assert.equal((await post(`/a/${token}/post`, { channel: "fizz" })).status, 404);
  const [school, h] = [await total("uva/ib"), await hits()];
  const r = await get(`/r/${ref}/p/ib`);
  assert.equal(r.status, 302);
  assert.equal(await total("uva/ib"), school + 1);
  assert.equal((await get(`/r/${ref}/s/fizz`)).status, 302);
  assert.equal(await hits(), h); // no ambassador credit
  const after = (await (await get(`/f/${FOUNDER}/export.json`)).json()).ambassadors.find((a) => a.token === token);
  assert.equal(after.status, "left");
});

// Codes carry their school as a readable prefix (2026-11-11). The prefix is a
// label: every school gets its own, the random part is still the secret, and a
// code handed out before the prefix existed is looked up whole and still works.
test("a code starts with its school, at every school, and old bare codes still sign in", async () => {
  const db = await mf.getD1Database("DB");
  const seen = new Set();
  for (const school of ["upenn", "umiami", "uva", "case-western", "clark"]) {
    const r = await post(`/f/${FOUNDER}/add`, { name: `Prefix ${school}`, school, contact: "", notes: "" });
    assert.equal(r.status, 303);
    const code = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
    assert.match(code, new RegExp(`^${school}-[a-z0-9]{14}$`));
    assert.ok(code.length <= 40, "fits the app's 40-character limit");
    const plan = await (await get(`/a/${code}/plan.json`)).json();
    assert.equal(plan.school, school);
    // The public id in posted links stays short and bare, and is not the code.
    const row = await db.prepare("SELECT ref FROM ambassadors WHERE token = ?1").bind(code).first();
    assert.match(row.ref, /^[a-z0-9]{10}$/);
    assert.ok(!code.includes(row.ref));
    seen.add(code.slice(school.length + 1));
    // The prefix alone, or the random part alone, opens nothing.
    assert.equal((await get(`/a/${code.slice(school.length + 1)}/plan.json`)).status, 404);
    assert.equal((await get(`/a/${school}-aaaaaaaaaaaaaa/plan.json`)).status, 404);
  }
  assert.equal(seen.size, 5, "the random part is drawn afresh for each code");

  await db
    .prepare("INSERT INTO ambassadors (token, ref, name, school) VALUES ('oldbarecode1234', 'oldref1234', 'Old Code', 'umiami')")
    .run();
  const old = await get("/a/oldbarecode1234/plan.json");
  assert.equal(old.status, 200);
  assert.equal((await old.json()).school, "umiami");
});

// Poster ideas, the extended plan.json, the restyled pages and the font route.
ideaTests({
  test,
  skip: false,
  founder: FOUNDER,
  db: () => mf.getD1Database("DB"),
  req: (path, init) => mf.dispatchFetch("https://example.test" + path, { redirect: "manual", ...init }),
});
