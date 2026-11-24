// Tests for schools made at request time and the invite route, shared by
// test/routes.test.mjs (the source Worker) and test/sites.test.mjs (the built
// single file). Not a test file itself. Written out on purpose: the built-file
// run must not import the source modules for anything it asserts.
import assert from "node:assert/strict";

const GENERIC = ["missed", "moved", "one-list", "sweeper", "ask"];
// Allowlisted Canvas hosts no other suite uses.
const H1 = "auburn.instructure.com";
const H2 = "bgsu.instructure.com";
const H3 = "blueline.instructure.com";
const H4 = "arkansasstateuniversity.instructure.com";

export function schoolsTests({ test, skip, req, founder, db, label = "", origin = "https://example.test", imagesServed = true }) {
  const t = (name, fn) => test(`${label}${name}`, { skip }, fn);
  const F = `/f/${founder}`;
  const asForm = (path, data) =>
    req(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(data).toString() });
  const json = (path, body) => req(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const invite = (code, body) => json(`/a/${code}/invite`, body);
  const idOf = async (code) => (await (await db()).prepare("SELECT id FROM ambassadors WHERE token = ?1").bind(code).first()).id;
  const refOf = async (code) => (await (await db()).prepare("SELECT ref FROM ambassadors WHERE token = ?1").bind(code).first()).ref;
  const schoolRow = async (id) => (await db()).prepare("SELECT * FROM schools WHERE id = ?1").bind(id).first();
  const plan = async (code) => (await req(`/a/${code}/plan.json`)).json();
  // The daily school limit is per UTC day; backdate what earlier tests made.
  const relax = async () => (await db()).prepare("UPDATE schools SET created_ts = '2000-01-01T00:00:00.000Z'").run();
  async function add(name, school, extra = {}) {
    const r = await asForm(`${F}/add`, { name, school, contact: "", notes: "", ...extra });
    assert.equal(r.status, 303, `${name} ${school}`);
    return new URL(r.headers.get("location"), "https://x").searchParams.get("created");
  }
  const strip = (p) => JSON.stringify({ ...p, generatedAt: 0 });
  const s = {};

  t("schools: setup, and a snapshot of what must not move", async () => {
    s.penn = await add("Schools Penn Inviter", "upenn");
    s.uva = await add("Schools Uva Person", "uva");
    s.stats = await (await req("/api/stats")).text();
    s.uvaPlan = strip(await plan(s.uva));
    const p = await plan(s.penn);
    assert.equal(p.invite.allowed, true);
    assert.equal((await plan(s.uva)).invite, undefined);
  });

  t("invite: a upenn ambassador may by default, a uva one may not, the founder toggle decides", async () => {
    const ok = await invite(s.penn, { name: "Friend One", school: "uva" });
    assert.equal(ok.status, 200);
    assert.equal(ok.headers.get("cache-control"), "no-store");
    const b = await ok.json();
    assert.equal(b.ok, true);
    assert.match(b.code, /^uva-[a-z0-9]{14}$/);
    assert.equal(b.page, `${origin}/a/${b.code}`);
    assert.match(b.welcome, /Friend/);
    assert.match(b.welcome, /uva/);
    assert.deepEqual(b.school, { id: "uva", name: "UVA", isNew: false });
    assert.equal((await db().then((d) => d.prepare("SELECT invited_by FROM ambassadors WHERE token = ?1").bind(b.code).first())).invited_by, await idOf(s.penn));
    const no = await invite(s.uva, { name: "X", school: "uva" });
    assert.equal(no.status, 403);
    assert.deepEqual(await no.json(), { ok: false, error: "not_allowed" });
    const pennId = await idOf(s.penn);
    const uvaId = await idOf(s.uva);
    // off for the founders' own default, then back to the default
    assert.equal((await asForm(`${F}/can-invite`, { id: String(pennId), value: "0" })).status, 303);
    assert.equal((await invite(s.penn, { name: "X", school: "uva" })).status, 403);
    assert.equal((await plan(s.penn)).invite, undefined);
    assert.equal((await asForm(`${F}/can-invite`, { id: String(pennId), value: "" })).status, 303);
    assert.equal((await invite(s.penn, { name: "Friend Two", school: "uva" })).status, 200);
    // on for a uva ambassador
    assert.equal((await asForm(`${F}/can-invite`, { id: String(uvaId), value: "1" })).status, 303);
    assert.equal((await invite(s.uva, { name: "Friend Three", school: "uva" })).status, 200);
    assert.equal((await asForm(`${F}/can-invite`, { id: String(uvaId), value: "" })).status, 303);
    assert.equal((await invite(s.uva, { name: "X", school: "uva" })).status, 403);
    // the raw-id rule: "1 " is not an id
    assert.equal((await asForm(`${F}/can-invite`, { id: `${pennId} `, value: "0" })).status, 400);
    assert.equal((await invite(s.penn, { name: "Still Fine", school: "uva" })).status, 200);
    // a paused ambassador may not, whatever the flag
    const d = await db();
    await d.prepare("UPDATE ambassadors SET status = 'paused' WHERE token = ?1").bind(s.penn).run();
    assert.equal((await invite(s.penn, { name: "X", school: "uva" })).status, 403);
    await d.prepare("UPDATE ambassadors SET status = 'active' WHERE token = ?1").bind(s.penn).run();
    // unknown code is a 404 like every /a/ route
    assert.equal((await invite("nope-aaaaaaaaaaaaaa", { name: "X", school: "uva" })).status, 404);
  });

  t("invite: a new school by name gets a slug id, a short code, and the same name finds it again", async () => {
    await relax();
    const r = await invite(s.penn, { name: "Name Friend", schoolName: "Test University One" });
    assert.equal(r.status, 200);
    const b = await r.json();
    assert.deepEqual(b.school, { id: "test-university-one", name: "Test University One", isNew: true });
    assert.ok(b.code.startsWith("test-university-one-"));
    assert.equal((await schoolRow("test-university-one")).canvas_host, null);
    const again = await (await invite(s.penn, { name: "Second", schoolName: "  test UNIVERSITY one " })).json();
    assert.deepEqual(again.school, { id: "test-university-one", name: "Test University One", isNew: false });
    assert.equal((await (await db()).prepare("SELECT COUNT(*) AS n FROM schools WHERE id = 'test-university-one'").first()).n, 1);
    const long = await (await invite(s.penn, { name: "Long Name", schoolName: "Wumbo ".repeat(10).trim() })).json();
    assert.equal(long.school.isNew, true);
    assert.ok(long.code.length <= 40, long.code);
    assert.match(long.code, /^[a-z0-9-]+$/);
    assert.match(long.school.id, /^[a-z0-9][a-z0-9-]{1,23}$/);
    // the school is picked by id too, once it exists
    const byId = await (await invite(s.penn, { name: "By Id", school: "test-university-one" })).json();
    assert.deepEqual(byId.school, { id: "test-university-one", name: "Test University One", isNew: false });
  });

  t("invite: hosts, short names that two universities share, and built-ins found by host", async () => {
    await relax();
    const mk = async (body) => (await invite(s.penn, { name: "Host Friend", ...body })).json();
    const a = await mk({ schoolName: "Auburn U", schoolHost: H1 });
    assert.deepEqual(a.school, { id: "auburn-u", name: "Auburn U", isNew: true });
    assert.equal((await schoolRow("auburn-u")).canvas_host, H1);
    // an existing school's host wins whatever the name says
    assert.deepEqual((await mk({ schoolName: "Something Else Entirely", schoolHost: H1 })).school, { id: "auburn-u", name: "Auburn U", isNew: false });
    // a host outside the allowlist is stored as NULL
    const n = await mk({ schoolName: "Nowhere College", schoolHost: "nope.example.edu" });
    assert.equal(n.school.isNew, true);
    assert.equal((await schoolRow(n.school.id)).canvas_host, null);
    // the same short name with two different hosts is two schools
    const x1 = await mk({ schoolName: "Xyz", schoolHost: H2 });
    const x2 = await mk({ schoolName: "Xyz", schoolHost: H3 });
    assert.deepEqual([x1.school.id, x1.school.isNew, x2.school.id, x2.school.isNew], ["xyz", true, "xyz-2", true]);
    assert.equal(x2.school.name, "Xyz");
    assert.equal((await schoolRow("xyz-2")).canvas_host, H3);
    // the same name with no host is the existing school
    assert.equal((await mk({ schoolName: "Xyz" })).school.id, "xyz");
    // a dynamic school with no host yet learns the one the request brings
    const nh = await mk({ schoolName: "Nullhost College" });
    assert.equal((await schoolRow(nh.school.id)).canvas_host, null);
    const nh2 = await mk({ schoolName: "Nullhost College", schoolHost: H4 });
    assert.deepEqual(nh2.school, { id: nh.school.id, name: "Nullhost College", isNew: false });
    assert.equal((await schoolRow(nh.school.id)).canvas_host, H4);
    // a built-in is found by its host, whatever the short name
    assert.deepEqual((await mk({ schoolName: "Miami", schoolHost: "miami.instructure.com" })).school, { id: "umiami", name: "UMiami", isNew: false });
    assert.equal((await mk({ schoolName: "Case Western" })).school.id, "case-western");
  });

  t("invite: bad names and bad schools are 400 and write nothing", async () => {
    const before = (await (await db()).prepare("SELECT (SELECT COUNT(*) FROM ambassadors) AS a, (SELECT COUNT(*) FROM schools) AS s").first());
    const bad = async (body, error) => {
      const r = await invite(s.penn, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.deepEqual(await r.json(), { ok: false, error }, JSON.stringify(body));
    };
    await bad({ name: "", school: "uva" }, "bad_name");
    await bad({ name: "   ", school: "uva" }, "bad_name");
    await bad({ school: "uva" }, "bad_name");
    await bad({ name: "n".repeat(81), school: "uva" }, "bad_name");
    await bad({ name: "Ok", school: "uva", schoolName: "Both Given" }, "bad_school");
    await bad({ name: "Ok" }, "bad_school");
    await bad({ name: "Ok", school: "nope" }, "bad_school");
    for (const bad1 of ["New", "api", "A", "x", "<b>Hi</b>", "Tom's College", 'Say "hi"', "AT&T U", "a\\b", "bell\u0007college", "!!", "n".repeat(61), "posters", "SCAN"]) {
      await bad({ name: "Ok", schoolName: bad1 }, "bad_school");
    }
    const after = await (await db()).prepare("SELECT (SELECT COUNT(*) FROM ambassadors) AS a, (SELECT COUNT(*) FROM schools) AS s").first();
    assert.deepEqual(after, before);
  });

  t("invite: two long names that share 24 characters are two schools, the second suffixed", async () => {
    await relax();
    const a = await (await invite(s.penn, { name: "A", schoolName: "Alpha Beta Gamma Delta Epsilon One" })).json();
    const b = await (await invite(s.penn, { name: "B", schoolName: "Alpha Beta Gamma Delta Epsilon Two" })).json();
    assert.equal(a.school.isNew, true);
    assert.equal(b.school.isNew, true);
    assert.notEqual(a.school.id, b.school.id);
    assert.match(b.school.id, /^[a-z0-9][a-z0-9-]{1,23}$/);
    assert.ok(b.school.id.endsWith("-2"), b.school.id);
    assert.ok(b.code.length <= 40);
  });

  t("invite: 30 at once from one inviter make exactly 20, and a new school raced for makes one row", async () => {
    await relax();
    const inv = await add("Concurrent Inviter", "upenn");
    const id = await idOf(inv);
    const rs = await Promise.all(Array.from({ length: 30 }, (_, i) => invite(inv, { name: `Racer ${i}`, schoolName: "Race Same College" })));
    const codes = rs.map((r) => r.status);
    assert.equal(codes.filter((c) => c === 200).length, 20, codes.join());
    assert.equal(codes.filter((c) => c === 429).length, 10, codes.join());
    const d = await db();
    assert.equal((await d.prepare("SELECT COUNT(*) AS n FROM ambassadors WHERE invited_by = ?1").bind(id).first()).n, 20);
    assert.equal((await d.prepare("SELECT COUNT(*) AS n FROM schools WHERE id = 'race-same-college'").first()).n, 1);
    assert.equal((await plan(inv)).invite.left, 0);
    assert.deepEqual(await (await invite(inv, { name: "Late", school: "uva" })).json(), { ok: false, error: "limit" });
  });

  t("invite: a limit that refuses the ambassador leaves no orphan school", async () => {
    await relax();
    const inv = await add("Nineteen Inviter", "upenn");
    const id = await idOf(inv);
    for (let i = 0; i < 19; i++) assert.equal((await invite(inv, { name: `N${i}`, school: "uva" })).status, 200);
    // Five at once, each wanting its own new school, one slot left.
    const rs = await Promise.all(Array.from({ length: 5 }, (_, i) => invite(inv, { name: `Orph ${i}`, schoolName: `Orphan Check ${["Alpha", "Bravo", "Charlie", "Delta", "Echo"][i]}` })));
    assert.equal(rs.filter((r) => r.status === 200).length, 1);
    assert.equal(rs.filter((r) => r.status === 429).length, 4);
    const d = await db();
    const made = (await d.prepare("SELECT id FROM schools WHERE created_by = ?1").bind(id).all()).results;
    assert.equal(made.length, 1);
    for (const m of made) assert.equal((await d.prepare("SELECT COUNT(*) AS n FROM ambassadors WHERE school = ?1").bind(m.id).first()).n, 1);
  });

  t("invite: the new ambassador's plan, posters, sticker scans and the host's own routes", async () => {
    await relax();
    const b = await (await invite(s.penn, { name: "Plan Friend", schoolName: "Plan College" })).json();
    const code = b.code;
    const id = b.school.id;
    const p = await plan(code);
    assert.equal(p.school, id);
    assert.equal(p.schoolName, "Plan College");
    assert.deepEqual(p.posters.map((x) => x.key), GENERIC);
    assert.equal("dashboard" in p, false);
    assert.equal("invite" in p, false);
    assert.equal("schoolInstalls" in p.numbers, false);
    for (const x of p.posters) {
      assert.equal(x.image, `${origin}/posters/upenn/${x.key}.jpg`);
      if (imagesServed) {
        const r = await req(new URL(x.image).pathname);
        assert.equal(r.status, 200, x.key);
        assert.equal(r.headers.get("content-type"), "image/jpeg", x.key);
      }
    }
    const ref = await refOf(code);
    const total = async (k) => (await (await db()).prepare("SELECT total FROM scans WHERE poster = ?1").bind(k).first())?.total ?? 0;
    const before = await total(`${id}/missed`);
    const sc = await req(`/r/${ref}/p/missed`);
    assert.equal(sc.status, 302);
    assert.match(sc.headers.get("location"), /apps\.apple\.com/);
    assert.equal(await total(`${id}/missed`), before + 1);
    assert.equal((await plan(code)).posters[0].scans, before + 1);
    assert.equal((await req(`/r/${ref}/p/ib`)).status, 404);
    assert.equal((await req(`/r/${ref}/p/jester`)).status, 404);
    assert.equal(await total(`${id}/ib`), 0);
    assert.equal((await req(`/scan/${id}/missed`)).status, 404);
    assert.equal((await req(`/posters/${id}/missed.jpg`)).status, 404);
    // the page, the stickers, and the plan's public texts never hold the private code
    const pub = JSON.stringify({ today: p.today, messages: p.messages, links: p.links, posters: p.posters, guidance: p.guidance });
    assert.ok(!pub.includes(code), "a public text holds the code");
    const stickers = await (await req(`/a/${code}/stickers`)).text();
    assert.ok(!stickers.includes(code), "the sticker page holds the code");
    assert.equal((stickers.match(/<svg class="qr"/g) ?? []).length, 5);
    const page = await req(`/a/${code}`);
    assert.equal(page.status, 200);
    assert.doesNotMatch(await page.text(), /scan dashboard/);
    const lb = await (await req("/api/leaderboard")).json();
    const row = lb.schools.find((x) => x.school === id);
    assert.equal(row.name, "Plan College");
    assert.equal(row.total, before + 1);
    assert.equal(row.ambassadors, 1);
  });

  t("invite: downloads follow an allowlisted host, and the inviter's count goes down", async () => {
    await relax();
    const inv = await add("Count Inviter", "upenn");
    const left0 = (await plan(inv)).invite.left;
    assert.equal(left0, 20);
    const b = await (await invite(inv, { name: "Host Person", schoolName: "Host College", schoolHost: H1 })).json();
    // H1 belongs to auburn-u from an earlier test, so this is that school
    assert.equal(b.school.id, "auburn-u");
    assert.equal((await plan(inv)).invite.left, 19);
    const p = await plan(b.code);
    assert.equal(typeof p.numbers.schoolInstalls, "number");
    const before = p.numbers.schoolInstalls;
    const r = await json("/api/install", { host: H1, kind: "new" });
    assert.equal(r.status, 200);
    assert.equal((await plan(b.code)).numbers.schoolInstalls, before + 1);
    const inv2 = (await plan(inv)).invite;
    assert.deepEqual(inv2.schools.slice(0, 5).map((x) => x.id), ["upenn", "umiami", "uva", "case-western", "clark"]);
    assert.ok(inv2.schools.some((x) => x.id === "auburn-u" && x.name === "Auburn U"));
    assert.ok(inv2.schools.findIndex((x) => x.id === "auburn-u") > inv2.schools.findIndex((x) => x.id === "clark"));
  });

  t("founder page: lists dynamic schools, adds someone to a new school, renames without changing the id", async () => {
    await relax();
    const page = await (await req(F)).text();
    assert.match(page, /Auburn U/);
    assert.match(page, /new school…/);
    assert.match(page, /name="schoolName"/);
    const code = await add("Founder Made", "__new", { schoolName: "Founder Made College", schoolHost: "" });
    assert.match(code, /^founder-made-college-[a-z0-9]{14}$/);
    assert.equal((await plan(code)).schoolName, "Founder Made College");
    assert.equal((await schoolRow("founder-made-college")).created_by, null);
    const page2 = await (await req(`${F}?created=${code}`)).text();
    assert.match(page2, /added Founder Made/);
    assert.match(page2, /may not invite/);
    assert.equal((await asForm(`${F}/add`, { name: "Bad", school: "__new", schoolName: "<b>", contact: "", notes: "" })).status, 400);
    assert.equal((await asForm(`${F}/add`, { name: "Bad", school: "nope", contact: "", notes: "" })).status, 400);
    // rename: the name changes, the id never does
    assert.equal((await asForm(`${F}/school-rename`, { school: "founder-made-college", name: "Founder College" })).status, 303);
    const p = await plan(code);
    assert.equal(p.school, "founder-made-college");
    assert.equal(p.schoolName, "Founder College");
    assert.equal((await asForm(`${F}/school-rename`, { school: "uva", name: "Hacked" })).status, 400);
    assert.equal((await asForm(`${F}/school-rename`, { school: "founder-made-college", name: "<x>" })).status, 400);
    assert.equal((await plan(s.uva)).schoolName, "UVA");
    const ex = await (await req(`${F}/export.json`)).json();
    assert.ok(ex.leaderboard.schools.some((x) => x.school === "founder-made-college"));
  });

  t("schools: a row with a built-in's id is ignored, and the daily and total school limits hold", async () => {
    const d = await db();
    await d.prepare("INSERT INTO schools (id, name, canvas_host, created_ts) VALUES ('uva', 'Fake UVA', NULL, '2000-01-01T00:00:00.000Z')").run();
    assert.equal((await plan(s.uva)).schoolName, "UVA");
    const lb = await (await req("/api/leaderboard")).json();
    assert.equal(lb.schools.filter((x) => x.school === "uva").length, 1);
    assert.equal(lb.schools.find((x) => x.school === "uva").name, "UVA");
    await d.prepare("DELETE FROM schools WHERE id = 'uva'").run();
    // ten new schools a day, by the founder form (no per-inviter limit there)
    await relax();
    for (let i = 0; i < 10; i++) await add(`Limit ${i}`, "__new", { schoolName: `Limit School ${String.fromCharCode(97 + i)}${i}` });
    const r = await asForm(`${F}/add`, { name: "Eleventh", school: "__new", schoolName: "Limit School Eleventh", contact: "", notes: "" });
    assert.equal(r.status, 429);
    assert.equal(await schoolRow("limit-school-eleventh"), null);
    assert.equal((await d.prepare("SELECT COUNT(*) AS n FROM ambassadors WHERE name = 'Eleventh'").first()).n, 0);
    // an invite that would need an eleventh school is refused too, and writes nothing
    const rr = await invite(s.penn, { name: "Eleventh", schoolName: "Limit School Twelfth" });
    assert.equal(rr.status, 429);
    assert.equal(await schoolRow("limit-school-twelfth"), null);
    await relax();
  });

  t("schools: nothing the host owns moved (stats rows, a uva ambassador's plan)", async () => {
    assert.equal(await (await req("/api/stats")).text(), s.stats);
    assert.equal(strip(await plan(s.uva)), s.uvaPlan);
    assert.equal((await req("/")).status, 200);
  });
}
