// Playbook, capture and suggestion tests shared by test/routes.test.mjs (the
// source Worker) and test/sites.test.mjs (the built single file). Not a test
// file itself: node --test only picks up *.test.mjs.
import assert from "node:assert/strict";

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xd9]);
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
const HTML = Buffer.from("<!doctype html><script>alert(1)</script>");
const padded = (head, total) => Buffer.concat([head, Buffer.alloc(total - head.length, 7)]);

let counter = 0;
const batchId = () => `b${Date.now().toString(36)}${(counter++).toString(36)}xxxxxxxx`.slice(0, 16).replace(/[^a-z0-9]/g, "a");

export function captureTests({ test, skip, req, founder, db, label = "" }) {
  const t = (name, fn) => test(`${label}${name}`, { skip }, fn);
  const F = `/f/${founder}`;
  const asJSON = (path, data) =>
    req(path, { method: "POST", headers: { "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(data) });
  const asForm = (path, data) =>
    req(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(data).toString() });
  const amb = {};
  async function add(key, name, school) {
    const r = await asForm(`${F}/add`, { name, school, contact: "", notes: "" });
    assert.equal(r.status, 303);
    const token = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
    const ex = await (await req(`${F}/export.json`)).json();
    const a = ex.ambassadors.find((x) => x.token === token);
    amb[key] = { token, ref: a.ref, id: a.id };
  }
  const exportJSON = async () => (await req(`${F}/export.json`)).json();
  const capsOf = async (key) => (await exportJSON()).captures.filter((c) => c.ambassadorId === amb[key].id);
  const plan = async (key) => (await req(`/a/${amb[key].token}/plan.json`)).json();
  const b64 = (buf) => buf.toString("base64");
  const frame = (key, data) => asJSON(`/a/${amb[key].token}/capture`, { kind: "feed", image: b64(JPEG), ...data });
  const result = (key, data) => asJSON(`/a/${amb[key].token}/capture`, { kind: "result", image: b64(PNG), ...data });

  t("captures: set up ambassadors", async () => {
    for (const k of ["a", "b", "c", "d", "e", "f", "g", "h"]) await add(k, `Cap ${k}`, k === "b" ? "upenn" : "uva");
  });

  t("captures: plan.json carries the playbook, suggested and the capture limits", async () => {
    const p = await plan("a");
    assert.equal(p.playbook.lead, "the posts that work don't look like ads.");
    assert.equal(p.playbook.steps.length, 5);
    assert.equal(p.playbook.examples.length, 2);
    assert.deepEqual(p.playbook.examples.map((e) => e.key), ["question", "list"]);
    assert.deepEqual(p.suggested, []);
    assert.deepEqual(p.captures, {
      feed: { framesPerRecording: 16, frameBytes: 200000, sentToday: 0, dailyLimit: 32, stored: 0, limit: 96 },
      results: { imageBytes: 300000, sentToday: 0, dailyLimit: 8, stored: 0, limit: 60 },
      styles: [
        { key: "question", label: "question" },
        { key: "list", label: "slipped into a list" },
        { key: "pitch", label: "straight pitch" },
        { key: "other", label: "something else" },
      ],
    });
    assert.ok(p.ideas && p.posters, "existing keys are still there");
  });

  t("captures: a feed frame and a result are stored, counted and typed by their bytes", async () => {
    const batch = batchId();
    const r = await frame("a", { batch, seq: "0" });
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { ok: true, message: "sent." });
    const r2 = await result("a", { platform: "yikyak", style: "list", upvotes: "65", views: "1200", note: `  ${"n".repeat(400)}  `, type: "image/gif" });
    assert.equal(r2.status, 200);
    const mine = await capsOf("a");
    const feed = mine.find((c) => c.kind === "feed");
    const res = mine.find((c) => c.kind === "result");
    assert.equal(feed.mime, "image/jpeg");
    assert.equal(feed.batch, batch);
    assert.equal(res.mime, "image/png");
    assert.deepEqual([res.platform, res.style, res.upvotes, res.views], ["yikyak", "list", 65, 1200]);
    assert.equal(res.note.length, 300);
    assert.ok(mine.every((c) => !("image" in c)), "export carries no image data");
    const p = await plan("a");
    assert.equal(p.captures.feed.sentToday, 1);
    assert.equal(p.captures.feed.stored, 1);
    assert.equal(p.captures.results.sentToday, 1);
  });

  t("captures: junk numbers store NULL, unknown platform and style become other", async () => {
    for (const bad of ["abc", "-5", "1e3", "10000001", "", "12.5"]) {
      assert.equal((await result("b", { upvotes: bad, views: bad, platform: "myspace", style: "weird" })).status, 200, bad);
    }
    const rows = (await capsOf("b")).filter((c) => c.kind === "result");
    assert.equal(rows.length, 6);
    assert.ok(rows.every((c) => c.upvotes === null && c.views === null && c.platform === "other" && c.style === "other"));
    assert.equal((await result("c", { upvotes: "10000000", views: "0" })).status, 200);
    const ok = (await capsOf("c"))[0];
    assert.deepEqual([ok.upvotes, ok.views], [10000000, 0]);
  });

  t("captures: wrong kind, bad batch, bad seq, missing image and non-images are 400", async () => {
    const before = (await exportJSON()).captures.length;
    const url = `/a/${amb.d.token}/capture`;
    const cases = [
      asJSON(url, { kind: "other", image: b64(JPEG) }),
      asJSON(url, { image: b64(JPEG) }),
      frame("d", { batch: "short", seq: "0" }),
      frame("d", { batch: "UPPERCASE12345", seq: "0" }),
      frame("d", { batch: "has-dash-123456", seq: "0" }),
      frame("d", { batch: batchId() + "z".repeat(30), seq: "0" }),
      frame("d", { seq: "0" }),
      frame("d", { batch: batchId(), seq: "16" }),
      frame("d", { batch: batchId(), seq: "-1" }),
      frame("d", { batch: batchId(), seq: "1e1" }),
      frame("d", { batch: batchId() }),
      asJSON(url, { kind: "feed", batch: batchId(), seq: "0" }),
      asJSON(url, { kind: "result" }),
      asJSON(url, { kind: "feed", batch: batchId(), seq: "0", image: b64(HTML) }),
      asJSON(url, { kind: "result", image: b64(HTML) }),
      asJSON(url, { kind: "result", image: "@@@not base64@@@" }),
      asJSON(url, { kind: "result", image: { a: 1 } }),
    ];
    for (const [i, p] of cases.entries()) {
      const r = await p;
      assert.equal(r.status, 400, `case ${i}`);
      assert.equal((await r.json()).ok, false);
    }
    assert.equal((await exportJSON()).captures.length, before, "nothing stored");
  });

  t("captures: 200,000 bytes is the feed cap and 300,000 the result cap, over is 413", async () => {
    const before = (await exportJSON()).captures.length;
    const batch = batchId();
    assert.equal((await frame("e", { batch, seq: "0", image: b64(padded(JPEG, 200001)) })).status, 413);
    assert.equal((await result("e", { image: b64(padded(PNG, 300001)) })).status, 413);
    assert.equal((await frame("e", { batch, seq: "0", image: b64(padded(JPEG, 200000)) })).status, 200);
    assert.equal((await result("e", { image: b64(padded(PNG, 300000)) })).status, 200);
    assert.equal((await frame("e", { batch, seq: "1", image: b64(padded(JPEG, 250000)) })).status, 413, "a result-sized image is too big for a frame");
    assert.equal((await exportJSON()).captures.length, before + 2);
  });

  t("captures: the same (batch, seq) twice answers 200 and stores one row; a form post redirects", async () => {
    const batch = batchId();
    for (let i = 0; i < 3; i++) assert.equal((await frame("f", { batch, seq: "3" })).status, 200);
    assert.equal((await capsOf("f")).filter((c) => c.batch === batch).length, 1);
    const f = await asForm(`/a/${amb.f.token}/capture`, { kind: "feed", batch: batchId(), seq: "0", image: b64(JPEG) });
    assert.equal(f.status, 303);
    assert.match(f.headers.get("location"), /^\/a\/[^?#]+\?ok=/);
  });

  t("captures: 40 feed frames sent at once from one code never pass 32 for the day or 16 a batch", async () => {
    const batches = [batchId(), batchId(), batchId(), batchId()];
    const sends = [];
    for (let i = 0; i < 10; i++) for (const b of batches) sends.push(frame("g", { batch: b, seq: String(i) }));
    // plus a 17th-frame attempt that the seq rule already refuses
    const out = await Promise.all(sends);
    const statuses = out.map((r) => r.status);
    assert.ok(statuses.every((s) => s === 200 || s === 429), statuses.join());
    for (const r of out) await r.arrayBuffer();
    const rows = (await capsOf("g")).filter((c) => c.kind === "feed");
    assert.equal(rows.length, 32, "exactly the daily limit");
    for (const b of batches) assert.ok(rows.filter((c) => c.batch === b).length <= 16);
    assert.equal(statuses.filter((s) => s === 200).length, 32);
  });

  t("captures: 20 results sent at once store at most 8", async () => {
    const out = await Promise.all(Array.from({ length: 20 }, () => result("h", { upvotes: "1" })));
    const statuses = out.map((r) => r.status);
    for (const r of out) await r.arrayBuffer();
    assert.ok(statuses.every((s) => s === 200 || s === 429));
    assert.equal(statuses.filter((s) => s === 200).length, 8);
    assert.equal((await capsOf("h")).filter((c) => c.kind === "result").length, 8);
    assert.equal((await result("h", {})).status, 429);
  });

  t("captures: the stored limits hold across days (96 frames, 60 results)", async () => {
    await add("old", "Cap old", "clark");
    const d = await db();
    const yesterday = new Date(Date.now() - 86400000 * 2).toISOString();
    const stmts = [];
    for (let i = 0; i < 95; i++) {
      stmts.push(
        d.prepare("INSERT INTO captures (ambassador_id, ts, kind, batch, seq, mime, image) VALUES (?1, ?2, 'feed', ?3, ?4, 'image/jpeg', 'AAAA')").bind(amb.old.id, yesterday, `old${Math.floor(i / 16)}xxxxxxxx`, i % 16),
      );
    }
    for (let i = 0; i < 59; i++) {
      stmts.push(d.prepare("INSERT INTO captures (ambassador_id, ts, kind, mime, image) VALUES (?1, ?2, 'result', 'image/png', 'AAAA')").bind(amb.old.id, yesterday));
    }
    await d.batch(stmts);
    assert.equal((await frame("old", { batch: batchId(), seq: "0" })).status, 200);
    assert.equal((await frame("old", { batch: batchId(), seq: "0" })).status, 429, "96 stored");
    assert.equal((await result("old", {})).status, 200);
    assert.equal((await result("old", {})).status, 429, "60 stored");
  });

  t("captures: founders get the image with the idea route's headers; ambassador codes never reach it", async () => {
    const c = (await capsOf("a")).find((x) => x.kind === "feed");
    const img = await req(`${F}/capture/${c.id}`);
    assert.equal(img.status, 200);
    assert.equal(img.headers.get("content-type"), "image/jpeg");
    assert.equal(img.headers.get("x-content-type-options"), "nosniff");
    assert.equal(img.headers.get("cache-control"), "private, no-store");
    assert.equal(img.headers.get("content-security-policy"), "default-src 'none'; sandbox");
    assert.equal(img.headers.get("content-disposition"), "inline");
    assert.ok(Buffer.from(await img.arrayBuffer()).equals(JPEG));
    assert.equal((await req(`${F}/capture/99999999`)).status, 404);
    assert.equal((await req(`${F}/capture/abc`)).status, 404);
    assert.equal((await req(`/f/${amb.a.token}/capture/${c.id}`)).status, 404, "an ambassador code is not the founder secret");
    assert.equal((await req(`/a/${amb.a.token}/capture/${c.id}`)).status, 404);
    assert.equal((await req(`/a/${amb.a.token}/capture`)).status, 404, "GET on the upload route");
  });

  t("captures: suggestions reach only their ambassador's plan and page, the 21st is refused, delete works", async () => {
    const s1 = await asForm(`${F}/suggest`, { id: String(amb.a.id), text: "  What do you use for deadlines?  ", reply: "Smooth for Students on the App Store" });
    assert.equal(s1.status, 303);
    assert.equal((await asForm(`${F}/suggest`, { id: String(amb.a.id), text: "<script>alert(1)</script>" })).status, 303);
    const pa = await plan("a");
    assert.equal(pa.suggested.length, 2);
    assert.deepEqual(Object.keys(pa.suggested[0]).sort(), ["id", "reply", "text", "ts"]);
    assert.equal(pa.suggested[0].text, "<script>alert(1)</script>", "newest first");
    assert.equal(pa.suggested[1].text, "What do you use for deadlines?");
    assert.equal(pa.suggested[1].reply, "Smooth for Students on the App Store");
    assert.deepEqual((await plan("b")).suggested, [], "another ambassador sees none");

    const page = await (await req(`/a/${amb.a.token}`)).text();
    assert.match(page, /posts to try, from olisa and marco/);
    assert.match(page, /What do you use for deadlines\?/);
    assert.ok(!page.includes("<script>alert(1)</script>"), "suggestion text is escaped");
    assert.match(page, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    assert.doesNotMatch(await (await req(`/a/${amb.b.token}`)).text(), /posts to try, from olisa and marco/);

    for (let i = 0; i < 18; i++) assert.equal((await asForm(`${F}/suggest`, { id: String(amb.a.id), text: `post ${i}` })).status, 303);
    const over = await asForm(`${F}/suggest`, { id: String(amb.a.id), text: "one too many" });
    assert.equal(over.status, 429);
    assert.equal((await plan("a")).suggested.length, 20);
    assert.equal((await asForm(`${F}/suggest`, { id: String(amb.b.id), text: "for b" })).status, 303, "the limit is per ambassador");

    assert.equal((await asForm(`${F}/suggest`, { id: String(amb.c.id), text: "   " })).status, 400);
    assert.equal((await asForm(`${F}/suggest`, { id: String(amb.c.id), text: "x".repeat(601) })).status, 400);
    assert.equal((await asForm(`${F}/suggest`, { id: "999999", text: "nobody" })).status, 404);
    assert.equal((await asForm(`${F}/suggest`, { id: String(amb.c.id), text: "t".repeat(600), reply: "r".repeat(500) })).status, 303);
    assert.equal((await plan("c")).suggested[0].reply.length, 300);

    const target = (await plan("b")).suggested[0];
    assert.equal((await asForm(`${F}/suggest-delete`, { id: String(target.id) })).status, 303);
    assert.deepEqual((await plan("b")).suggested, []);
    assert.equal((await plan("a")).suggested.length, 20, "deleting b's did not touch a's");
    assert.equal((await exportJSON()).suggestions.length, 21 + 0, "export lists suggestions");
  });

  t("captures: founder ids like -1, 1e3 and '1 ' act on nothing", async () => {
    const before = await exportJSON();
    for (const bad of ["-1", "1e3", "0x10", "01", "0", "abc", "1.5"]) {
      for (const action of ["suggest-delete", "capture-seen", "capture-delete"]) {
        assert.equal((await asForm(`${F}/${action}`, { id: bad })).status, 400, `${action} ${bad}`);
      }
      assert.equal((await asForm(`${F}/suggest`, { id: bad, text: "hi" })).status, 400, `suggest ${bad}`);
    }
    // "1 " is trimmed by the body reader, so it is the id 1: that one is legitimate.
    for (const action of ["capture-seen", "capture-delete"]) {
      assert.equal((await asForm(`${F}/${action}`, { amb: "-1", batch: batchId() })).status, 400);
      assert.equal((await asForm(`${F}/${action}`, { amb: String(amb.a.id), batch: "NOPE" })).status, 400);
      assert.equal((await asForm(`${F}/${action}`, { amb: String(amb.a.id) })).status, 400);
    }
    const after = await exportJSON();
    assert.equal(after.captures.length, before.captures.length);
    assert.equal(after.suggestions.length, before.suggestions.length);
  });

  t("captures: capture-seen and capture-delete by id, and by batch for one ambassador only", async () => {
    await add("x", "Cap x", "uva");
    await add("y", "Cap y", "uva");
    const shared = batchId(); // the same batch id used by both, on purpose
    for (let i = 0; i < 3; i++) {
      assert.equal((await frame("x", { batch: shared, seq: String(i) })).status, 200);
      assert.equal((await frame("y", { batch: shared, seq: String(i) })).status, 200);
    }
    const other = batchId();
    assert.equal((await frame("x", { batch: other, seq: "0" })).status, 200);
    assert.equal((await asForm(`${F}/capture-seen`, { amb: String(amb.x.id), batch: shared })).status, 303);
    const seen = (await capsOf("x")).filter((c) => c.seenAt);
    assert.equal(seen.length, 3);
    assert.ok(seen.every((c) => c.batch === shared));
    assert.ok((await capsOf("y")).every((c) => !c.seenAt), "y untouched");

    assert.equal((await asForm(`${F}/capture-delete`, { amb: String(amb.x.id), batch: shared })).status, 303);
    assert.deepEqual((await capsOf("x")).map((c) => c.batch), [other]);
    assert.equal((await capsOf("y")).length, 3, "y's batch with the same id survives");
    const one = (await capsOf("y"))[0];
    assert.equal((await asForm(`${F}/capture-delete`, { id: String(one.id) })).status, 303);
    assert.equal((await capsOf("y")).length, 2);
    assert.equal((await req(`${F}/capture/${one.id}`)).status, 404);
  });

  t("captures: a second ambassador cannot see or change the first one's captures or suggestions", async () => {
    const p = await plan("y");
    assert.deepEqual(p.suggested, []);
    assert.equal(p.captures.feed.stored, 2);
    // Their routes only ever act on the code's own id: nothing they can post names another's.
    const before = (await capsOf("a")).length;
    await frame("y", { batch: batchId(), seq: "0", ambassador_id: String(amb.a.id), amb: String(amb.a.id) });
    assert.equal((await capsOf("a")).length, before);
    const page = await (await req(`/a/${amb.y.token}`)).text();
    assert.doesNotMatch(page, /What do you use for deadlines/);
  });

  t("captures: the ambassador page shows the playbook, the new sections and no private code in post texts", async () => {
    const page = await (await req(`/a/${amb.c.token}`)).text();
    assert.match(page, /the posts that work don't look like ads\./);
    assert.match(page, /id="works"/);
    assert.match(page, /id="feed"/);
    assert.match(page, /id="result"/);
    assert.match(page, /Smooth for Students on the App Store/);
    assert.match(page, /check nothing private is in the pictures\./);
    assert.match(page, /name="robots" content="noindex,nofollow"/);
    assert.match(page, /name="referrer" content="no-referrer"/);
    assert.doesNotMatch(page, /https?:\/\/(?!example\.test|apps\.apple\.com|smooth-poster-scans)[a-z0-9.-]+\//i.source ? /src="https?:\/\/(?!example\.test)/ : /x^/);
    const p = await plan("c");
    const texts = [p.today?.text ?? "", ...p.messages.map((m) => m.text), ...p.playbook.examples.flatMap((e) => [e.post, e.reply])];
    for (const text of texts) assert.ok(!text.includes(amb.c.token), "no private code in post texts");
  });

  t("captures: the 16 KB cap still holds on every other route", async () => {
    const r = await asJSON(`/a/${amb.c.token}/feedback`, { body: "x".repeat(20000) });
    assert.equal(r.status, 413);
  });

  t("captures: export.json carries captures without image data, and suggestions", async () => {
    const ex = await exportJSON();
    assert.ok(Array.isArray(ex.captures) && Array.isArray(ex.suggestions));
    assert.ok(ex.captures.length > 0);
    assert.ok(ex.captures.every((c) => !("image" in c) && typeof c.id === "number"));
    assert.ok(!JSON.stringify(ex.captures).includes("AAAA"));
    const founderPage = await (await req(F)).text();
    assert.match(founderPage, /id="feeds"/);
    assert.match(founderPage, /id="results"/);
    assert.match(founderPage, /send a post to try/);
  });
}
