// Poster-idea, plan.json and page tests shared by test/routes.test.mjs (the
// source Worker) and test/sites.test.mjs (the built single file), so both prove
// the same thing. Not a test file itself: node --test only picks up *.test.mjs.
import assert from "node:assert/strict";
import { readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// Smallest files that carry each format's real signature.
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xd9]);
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
const WEBP = Buffer.from("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==", "base64");
const SVG = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
const HTML = Buffer.from("<!doctype html><script>alert(1)</script>");
const padded = (head, total) => Buffer.concat([head, Buffer.alloc(total - head.length, 7)]);

export function ideaTests({ test, skip, req, founder, db, label = "" }) {
  const t = (name, fn) => test(`${label}${name}`, { skip }, fn);
  const F = `/f/${founder}`;
  const asJSON = (path, data, extra = {}) =>
    req(path, { method: "POST", headers: { "content-type": "application/json", accept: "application/json", ...extra }, body: JSON.stringify(data) });
  const asForm = (path, data) =>
    req(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(data).toString() });
  const amb = {};
  async function add(key, name, school) {
    const r = await asForm(`${F}/add`, { name, school, contact: "", notes: "" });
    assert.equal(r.status, 303);
    const token = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
    const ex = await (await req(`${F}/export.json`)).json();
    amb[key] = { token, ref: ex.ambassadors.find((a) => a.token === token).ref, id: ex.ambassadors.find((a) => a.token === token).id };
  }
  const ideasOf = async () => (await (await req(`${F}/export.json`)).json()).ideas;
  const plan = async (key) => (await req(`/a/${amb[key].token}/plan.json`)).json();
  const b64 = (buf) => buf.toString("base64");

  t("ideas: set up two ambassadors", async () => {
    await add("a", "Idea Aaa", "uva");
    await add("b", "Idea Bbb", "upenn");
  });

  t("ideas: a JPEG, a PNG and a WebP are kept, typed by their bytes, and served back identical to the founder", async () => {
    const cases = [
      [JPEG, "image/jpeg", "image/gif"], // a lying client type is ignored
      [PNG, "image/png", "application/octet-stream"],
      [WEBP, "image/webp", "image/jpeg"],
    ];
    for (const [buf, mime, claimed] of cases) {
      const r = await asJSON(`/a/${amb.a.token}/idea`, { image: b64(buf), type: claimed, note: `n-${mime}` });
      assert.equal(r.status, 200, mime);
      assert.deepEqual(await r.json(), { ok: true, message: "sent. thank you." });
    }
    const ideas = (await ideasOf()).filter((i) => i.ambassadorId === amb.a.id).sort((x, y) => x.id - y.id);
    assert.deepEqual(ideas.map((i) => i.mime), ["image/jpeg", "image/png", "image/webp"]);
    assert.ok(ideas.every((i) => i.hasImage && !("image" in i)), "export carries no image data");
    for (const [k, [buf, mime]] of cases.entries()) {
      const img = await req(`${F}/idea/${ideas[k].id}`);
      assert.equal(img.status, 200);
      assert.equal(img.headers.get("content-type"), mime);
      assert.equal(img.headers.get("x-content-type-options"), "nosniff");
      assert.equal(img.headers.get("cache-control"), "private, no-store");
      assert.equal(img.headers.get("content-security-policy"), "default-src 'none'; sandbox");
      assert.equal(img.headers.get("content-disposition"), "inline");
      assert.ok(Buffer.from(await img.arrayBuffer()).equals(buf), "byte-identical");
    }
  });

  t("ideas: a note alone works, a data: prefix and line breaks are tolerated, the form post redirects", async () => {
    const n = await asJSON(`/a/${amb.a.token}/idea`, { note: "  just words  " });
    assert.equal(n.status, 200);
    const mine = (await ideasOf()).filter((i) => i.ambassadorId === amb.a.id);
    const note = mine.find((i) => i.note === "just words");
    assert.ok(note && note.hasImage === false && note.mime === null);
    assert.equal((await req(`${F}/idea/${note.id}`)).status, 404, "no image, no bytes");
    const spaced = `data:image/png;base64,${b64(PNG).replace(/(.{20})/g, "$1\n")}`;
    assert.equal((await asJSON(`/a/${amb.b.token}/idea`, { image: spaced, note: "x".repeat(900) })).status, 200);
    const bi = (await ideasOf()).find((i) => i.ambassadorId === amb.b.id);
    assert.equal(bi.mime, "image/png");
    assert.equal(bi.note.length, 500, "note is cut at 500");
    const f = await asForm(`/a/${amb.b.token}/idea`, { note: "from the web form" });
    assert.equal(f.status, 303);
    assert.match(f.headers.get("location"), /^\/a\/[^?#]+\?ok=/);
  });

  t("ideas: nothing, garbage, SVG and HTML are refused with the right JSON or plain text", async () => {
    const before = (await ideasOf()).length;
    const empty = await asJSON(`/a/${amb.b.token}/idea`, {});
    assert.equal(empty.status, 400);
    assert.equal((await empty.json()).ok, false);
    assert.equal((await asJSON(`/a/${amb.b.token}/idea`, { note: "   " })).status, 400);
    for (const bad of [SVG, HTML, Buffer.from("GIF89a" + "x".repeat(40)), Buffer.from("not an image at all")]) {
      const r = await asJSON(`/a/${amb.b.token}/idea`, { image: b64(bad), type: "image/jpeg" });
      assert.equal(r.status, 400, bad.toString().slice(0, 12));
      assert.equal((await r.json()).ok, false);
    }
    assert.equal((await asJSON(`/a/${amb.b.token}/idea`, { image: "@@@not base64@@@" })).status, 400);
    assert.equal((await asJSON(`/a/${amb.b.token}/idea`, { image: { a: 1 } })).status, 400);
    const plain = await req(`/a/${amb.b.token}/idea`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "note=" });
    assert.equal(plain.status, 400);
    assert.equal(plain.headers.get("content-type"), "text/plain;charset=UTF-8");
    assert.equal((await ideasOf()).length, before, "nothing stored");
  });

  t("ideas: a 700 KB image is a 413, and so is one a single byte over 600,000", async () => {
    const before = (await ideasOf()).length;
    const big = await asJSON(`/a/${amb.b.token}/idea`, { image: b64(padded(JPEG, 700000)) });
    assert.equal(big.status, 413);
    assert.equal((await big.json()).ok, false);
    const over = await asJSON(`/a/${amb.b.token}/idea`, { image: b64(padded(JPEG, 600001)) });
    assert.equal(over.status, 413);
    // The global 16 KB cap still holds for every other route.
    assert.equal((await asJSON(`/a/${amb.b.token}/feedback`, { body: "x".repeat(20000) })).status, 413);
    assert.equal((await ideasOf()).length, before);
  });

  t("ideas: exactly 600,000 bytes is kept; the 6th idea in a UTC day is a 429", async () => {
    // a has 4 today (three images and a note).
    assert.equal((await asJSON(`/a/${amb.a.token}/idea`, { image: b64(padded(PNG, 600000)) })).status, 200);
    const sixth = await asJSON(`/a/${amb.a.token}/idea`, { note: "one too many" });
    assert.equal(sixth.status, 429);
    assert.equal((await sixth.json()).ok, false);
    assert.equal((await plan("a")).ideas.sent, 5);
  });

  t("ideas: 30 stored in total is a 429 even on a fresh day", async () => {
    await add("c", "Idea Ccc", "clark");
    const d = await db();
    for (let i = 0; i < 30; i++) {
      await d.prepare("INSERT INTO poster_ideas (ambassador_id, ts, note) VALUES (?1, ?2, 'old')").bind(amb.c.id, "2020-01-01T00:00:00.000Z").run();
    }
    assert.equal((await plan("c")).ideas.sent, 30);
    assert.equal((await asJSON(`/a/${amb.c.token}/idea`, { note: "thirty-first" })).status, 429);
  });

  t("ideas: nobody else can reach them, and no public route mentions them", async () => {
    const mine = (await ideasOf()).find((i) => i.ambassadorId === amb.a.id && i.hasImage);
    for (const key of ["a", "b"]) {
      for (const p of [`/a/${amb[key].token}/idea/${mine.id}`, `/a/${amb[key].token}/idea`, `/a/${amb[key].token}/ideas`]) {
        assert.equal((await req(p)).status, 404, p);
      }
    }
    assert.equal((await req(`/f/wrong-token-0123456789abcdef/idea/${mine.id}`)).status, 404);
    assert.equal((await req(`${F}/idea/999999`)).status, 404);
    assert.equal((await req(`${F}/idea/abc`)).status, 404);
    assert.equal((await req(`${F}/idea/${mine.id}/extra`)).status, 404);
    const img = await req(`${F}/idea/${mine.id}`);
    for (const [, v] of img.headers) assert.ok(!v.includes(amb.a.token), "the private code is not in the image response headers");
    // b's own page and plan know only b's count.
    const pageB = await (await req(`/a/${amb.b.token}`)).text();
    assert.ok(!pageB.includes("n-image/png"), "a's note is not on b's page");
    const pb = await plan("b");
    assert.equal(pb.ideas.sent, (await ideasOf()).filter((i) => i.ambassadorId === amb.b.id).length);
    for (const p of ["/api/stats", "/api/leaderboard", `/r/${amb.a.ref}/s/gc`, `/r/${amb.a.ref}/p/ib`]) {
      const r = await req(p);
      const text = (await r.text()) + [...r.headers].join("\n");
      assert.ok(!/idea/i.test(text), p);
      assert.ok(!text.includes(amb.a.token), p);
    }
    assert.ok(!/poster idea/i.test(await (await req("/")).text()), "the public dashboard is untouched");
  });

  t("ideas: plan.json gains posters, dashboard and ideas, and keeps its old keys", async () => {
    const pa = await plan("a");
    for (const k of ["name", "school", "schoolName", "title", "status", "pausedUntil", "page", "appStore", "numbers", "today", "messages", "checklist", "tips", "channels", "generatedAt"]) {
      assert.ok(k in pa, k);
    }
    assert.equal(pa.posters.length, 12);
    assert.equal((await plan("b")).posters.length, 14);
    const stats = (await (await req("/api/stats")).json()).rows;
    for (const p of pa.posters) {
      assert.deepEqual(Object.keys(p), ["key", "name", "image", "scans"]);
      assert.equal(p.image, `https://example.test/posters/uva/${p.key}.jpg`);
      const row = stats.find((r) => r.school === "uva" && r.poster === p.key);
      assert.equal(p.scans, row.total, p.key);
      assert.equal(p.name, row.name);
    }
    for (const p of (await plan("b")).posters) {
      assert.equal(p.scans, stats.find((r) => r.school === "upenn" && r.poster === p.key).total, p.key);
    }
    assert.equal(pa.dashboard, "https://example.test/?school=uva");
    assert.deepEqual(pa.ideas, { sent: 5, limit: 30, dailyLimit: 5 });
    assert.deepEqual(Object.keys(pa.ideas), ["sent", "limit", "dailyLimit"]);
  });

  t("ideas: the founder can mark one seen and delete one; a wrong id or token does nothing", async () => {
    const page = await (await req(F)).text();
    assert.match(page, /poster ideas/);
    assert.match(page, /\d+ new/);
    assert.ok(page.includes("loading=\"lazy\" src=\"" + F + "/idea/"), "thumbnail");
    const ideas = await ideasOf();
    const one = ideas.find((i) => i.hasImage);
    assert.equal((await asForm(`${F}/idea-seen`, { id: String(one.id) })).status, 303);
    assert.ok((await ideasOf()).find((i) => i.id === one.id).seenAt, "seen is stamped");
    assert.equal((await asForm(`/f/wrong-token-0123456789abcdef/idea-delete`, { id: String(one.id) })).status, 404);
    assert.equal((await asForm(`${F}/idea-delete`, {})).status, 400);
    assert.equal((await asForm(`${F}/idea-delete`, { id: String(one.id) })).status, 303);
    assert.ok(!(await ideasOf()).some((i) => i.id === one.id));
    assert.equal((await req(`${F}/idea/${one.id}`)).status, 404);
    assert.equal((await plan(Object.keys(amb).find((k) => amb[k].id === one.ambassadorId))).ideas.sent, (await ideasOf()).filter((i) => i.ambassadorId === one.ambassadorId).length);
  });

  t("ideas: a note with markup is escaped on the founder page", async () => {
    assert.ok([200, 429].includes((await asJSON(`/a/${amb.b.token}/idea`, { note: `<img src=x onerror=alert(1)>` })).status));
    const page = await (await req(F)).text();
    assert.ok(!page.includes("<img src=x onerror"), "raw markup");
  });

  t("pages: the three pages are noindex, no-referrer, load no third-party host, and the door buttons are there", async () => {
    const pages = {
      ambassador: await (await req(`/a/${amb.a.token}`)).text(),
      stickers: await (await req(`/a/${amb.a.token}/stickers`)).text(),
      founder: await (await req(F)).text(),
    };
    for (const [name, html] of Object.entries(pages)) {
      assert.match(html, /<meta name="robots" content="noindex,nofollow">/, name);
      assert.match(html, /<meta name="referrer" content="no-referrer">/, name);
      assert.ok(!/(?:src|href)="https?:\/\/(?!example\.test)/.test(html), `${name}: no third-party src or href`);
      assert.ok(!/url\(\s*["']?https?:/.test(html), `${name}: no remote css url`);
      assert.match(html, /\/a\/_fonts\/inter\.woff2/, name);
    }
    const a = pages.ambassador;
    assert.match(a, /href="#posters"/);
    assert.match(a, /href="#idea"/);
    assert.match(a, /href="\/\?school=uva"[^>]*target="_blank"/);
    assert.match(a, /id="posters"/);
    assert.match(a, /id="idea"/);
    const nA = (await ideasOf()).filter((i) => i.ambassadorId === amb.a.id).length;
    assert.ok(a.includes(`${nA} of 30 sent`), "idea count on the page");
    assert.equal((a.match(/class="pcard"/g) || []).length, 12);
    assert.equal((a.match(/loading="lazy" src="\/posters\/uva\//g) || []).length, 12);
    assert.match(a, /open full size/);
    assert.ok(a.includes(`data-copy="https://example.test/r/${amb.a.ref}/p/ib"`), "tracked poster link");
    assert.ok(!pages.stickers.includes(amb.a.token), "stickers carry no private code");
    assert.equal((pages.stickers.match(/<svg class="qr"/g) || []).length, 12);
    assert.match(pages.stickers, /@media print/);
  });

  t("fonts: served by the worker, immutable, only the four known names, under budget", async () => {
    let total = 0;
    for (const n of ["familjen-grotesk", "inter", "space-mono", "space-mono-bold"]) {
      const r = await req(`/a/_fonts/${n}.woff2`);
      assert.equal(r.status, 200, n);
      assert.equal(r.headers.get("content-type"), "font/woff2");
      assert.equal(r.headers.get("cache-control"), "public, max-age=31536000, immutable");
      const buf = Buffer.from(await r.arrayBuffer());
      assert.equal(buf.subarray(0, 4).toString("latin1"), "wOF2", n);
      total += buf.length;
    }
    assert.ok(total < 120 * 1024, `woff2 total ${total}`);
    for (const p of ["/a/_fonts/nope.woff2", "/a/_fonts/inter.ttf", "/a/_fonts/", "/a/_fonts/inter.woff2/x", "/a/_fonts/..%2fx.woff2"]) {
      const r = await req(p);
      assert.equal(r.status, 404, p);
      assert.equal(await r.text(), "Not found", p);
    }
    assert.equal((await req("/a/_fonts/inter.woff2", { method: "POST" })).status, 405);
    const onDisk = readdirSync(join(root, "worker/fonts")).filter((f) => f.endsWith(".woff2")).reduce((s, f) => s + statSync(join(root, "worker/fonts", f)).size, 0);
    assert.equal(onDisk, total);
  });
}
