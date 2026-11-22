// Install-count tests shared by test/routes.test.mjs (the source Worker) and
// test/sites.test.mjs (the built single file). Not a test file itself.
import assert from "node:assert/strict";

// Written out on purpose: the built-file run must not import the source module.
const PER_NETWORK = 30;
const HOST_CAP = 2000;
const TEST_IP = "203.0.113.77";
const TEST_UA = "installs-suite-agent/9.9";

export function installTests({ test, skip, req, founder, db, label = "" }) {
  const t = (name, fn) => test(`${label}${name}`, { skip }, fn);
  const F = `/f/${founder}`;
  const today = () => new Date().toISOString().slice(0, 10);
  const post = (data, { ip = TEST_IP, ct = "application/json", raw } = {}) =>
    req("/api/install", {
      method: "POST",
      headers: { "content-type": ct, "cf-connecting-ip": ip, "user-agent": TEST_UA },
      body: raw ?? JSON.stringify(data),
    });
  const tally = async (host, kind) =>
    (await (await db()).prepare("SELECT COALESCE(SUM(n),0) AS n FROM installs WHERE host = ?1 AND kind = ?2").bind(host, kind).first()).n;
  const rowsIn = async () => (await (await db()).prepare("SELECT COUNT(*) AS n FROM installs").first()).n;
  const amb = {};
  const asForm = (path, data) =>
    req(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(data).toString() });
  async function add(key, name, school) {
    const r = await asForm(`${F}/add`, { name, school, contact: "", notes: "" });
    assert.equal(r.status, 303);
    amb[key] = new URL(r.headers.get("location"), "https://x").searchParams.get("created");
  }

  t("installs: a valid post counts, new and existing tally separately", async () => {
    const r = await post({ host: "canvas.upenn.edu", kind: "new" });
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { ok: true });
    assert.equal(r.headers.get("cache-control"), "no-store");
    assert.equal(r.headers.get("access-control-allow-origin"), null);
    assert.equal(await tally("canvas.upenn.edu", "new"), 1);
    assert.equal(await tally("canvas.upenn.edu", "existing"), 0);
    assert.equal((await post({ host: "CANVAS.Upenn.edu", kind: "existing" })).status, 200);
    assert.equal(await tally("canvas.upenn.edu", "existing"), 1);
    const row = await (await db()).prepare("SELECT day FROM installs WHERE host = 'canvas.upenn.edu' AND kind = 'new'").first();
    assert.equal(row.day, today());
  });

  t("installs: malformed bodies are 400 and store nothing", async () => {
    const before = await rowsIn();
    const long = "a".repeat(98) + ".c"; // 100 chars is allowed, 101 is not
    const bad = [
      { host: "http://x.edu", kind: "new" },
      { host: "x", kind: "new" },
      { host: "a..b", kind: "new" },
      { host: "x.edu/path", kind: "new" },
      { host: "x.edu:8080", kind: "new" },
      { host: ".x.edu", kind: "new" },
      { host: "x.edu.", kind: "new" },
      { host: "a b.edu", kind: "new" },
      { host: long + "x", kind: "new" },
      { host: 12345, kind: "new" },
      { host: null, kind: "new" },
      { kind: "new" },
      { host: "x.edu", kind: "other" },
      { host: "x.edu", kind: "NEW" },
      { host: "x.edu" },
      [],
      "x.edu",
    ];
    assert.equal(long.length, 100);
    for (const b of bad) {
      const r = await post(b);
      assert.equal(r.status, 400, JSON.stringify(b).slice(0, 60));
      assert.deepEqual(await r.json(), { ok: false });
    }
    assert.equal((await post(null, { raw: "{nope" })).status, 400);
    assert.equal((await post(null, { raw: "" })).status, 400);
    assert.equal((await post({ host: "x.edu", kind: "new", pad: "p".repeat(600) })).status, 400);
    assert.equal((await post({ host: "x.edu", kind: "new" }, { ct: "text/plain" })).status, 400);
    assert.equal((await req("/api/install", { method: "POST", body: JSON.stringify({ host: "x.edu", kind: "new" }) })).status, 400);
    assert.equal(await rowsIn(), before);
    // a 100-character host is fine
    assert.equal((await post({ host: long, kind: "new" }, { ip: "198.51.100.200" })).status, 200);
    assert.equal(await tally(long, "new"), 1);
    // charset header is tolerated
    assert.equal((await post({ host: "ok.example.edu", kind: "new" }, { ip: "198.51.100.201", ct: "application/json; charset=utf-8" })).status, 200);
  });

  t("installs: other methods are 405", async () => {
    for (const method of ["GET", "PUT", "DELETE", "HEAD"]) {
      const r = await req("/api/install", { method });
      assert.equal(r.status, 405, method);
      assert.equal(r.headers.get("cache-control"), "no-store");
    }
    assert.equal((await req("/api/install/")).status, 404);
  });

  t("installs: 40 concurrent posts from one network for one host store exactly 30", async () => {
    const host = "burst.example.edu";
    const ip = "192.0.2.10";
    const rs = await Promise.all(Array.from({ length: 40 }, () => post({ host, kind: "new" }, { ip })));
    assert.ok(rs.every((r) => r.status === 200), "a swallowed count still answers 200");
    assert.equal(await tally(host, "new"), PER_NETWORK);
    // a second network still counts, and so does the same one for another host
    assert.equal((await post({ host, kind: "new" }, { ip: "192.0.2.11" })).status, 200);
    assert.equal(await tally(host, "new"), PER_NETWORK + 1);
    assert.equal((await post({ host: "other-burst.example.edu", kind: "new" }, { ip })).status, 200);
    assert.equal(await tally("other-burst.example.edu", "new"), 1);
    // a missing address is one shared bucket, not unlimited
    const noip = await Promise.all(
      Array.from({ length: 35 }, () => req("/api/install", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ host: "noip.example.edu", kind: "new" }) })),
    );
    assert.ok(noip.every((r) => r.status === 200));
    assert.equal(await tally("noip.example.edu", "new"), PER_NETWORK);
  });

  t("installs: no table keeps the address or the user agent", async () => {
    await post({ host: "canvas.upenn.edu", kind: "new" });
    const d = await db();
    for (const table of ["installs", "install_salts", "install_seen"]) {
      const { results } = await d.prepare(`SELECT * FROM ${table}`).all();
      assert.ok(results.length > 0, table);
      for (const row of results) for (const v of Object.values(row)) {
        assert.ok(!String(v).includes(TEST_IP), `${table} holds the address`);
        assert.ok(!String(v).includes("installs-suite-agent"), `${table} holds the user agent`);
      }
    }
    // the bucket is a hash, 64 hex characters
    const b = await d.prepare("SELECT bucket FROM install_seen LIMIT 1").first();
    assert.match(b.bucket, /^[0-9a-f]{64}$/);
    const s = await d.prepare("SELECT salt FROM install_salts WHERE day = ?1").bind(today()).first();
    assert.match(s.salt, /^[0-9a-f]{32}$/);
  });

  t("installs: salts and buckets older than yesterday are removed on the next write", async () => {
    const d = await db();
    const iso = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
    await d.prepare("INSERT INTO install_seen (day, bucket, n) VALUES (?1, 'old', 3), (?2, 'yesterday', 1)").bind(iso(2), iso(1)).run();
    await d.prepare("INSERT INTO install_salts (day, salt) VALUES (?1, 'oldsalt'), (?2, 'yestsalt')").bind(iso(5), iso(1)).run();
    await d.prepare("INSERT INTO installs (host, day, kind, n) VALUES ('keeps.tally.edu', ?1, 'new', 4)").bind(iso(40)).run();
    assert.equal((await post({ host: "canvas.upenn.edu", kind: "new" }, { ip: "198.51.100.5" })).status, 200);
    const left = async (sql) => (await d.prepare(sql).first()).n;
    assert.equal(await left("SELECT COUNT(*) n FROM install_seen WHERE bucket = 'old'"), 0);
    assert.equal(await left("SELECT COUNT(*) n FROM install_salts WHERE salt = 'oldsalt'"), 0);
    assert.equal(await left("SELECT COUNT(*) n FROM install_seen WHERE bucket = 'yesterday'"), 1);
    assert.equal(await left("SELECT COUNT(*) n FROM install_salts WHERE salt = 'yestsalt'"), 1);
    assert.equal(await tally("keeps.tally.edu", "new"), 4, "the tally itself is never cleaned");
  });

  t("installs: plan.json, the ambassador page and the founder page show the counts", async () => {
    await add("uva", "Install Friend", "uva");
    for (let i = 0; i < 3; i++) assert.equal((await post({ host: "canvas.its.virginia.edu", kind: "new" }, { ip: `198.51.100.${30 + i}` })).status, 200);
    assert.equal((await post({ host: "canvas.its.virginia.edu", kind: "existing" }, { ip: "198.51.100.40" })).status, 200);
    // an old 'new' counts toward the total but not the recent window
    await (await db()).prepare("INSERT INTO installs (host, day, kind, n) VALUES ('canvas.its.virginia.edu', '2020-01-01', 'new', 5)").run();
    const plan = await (await req(`/a/${amb.uva}/plan.json`)).json();
    assert.equal(plan.numbers.schoolInstalls, 9);
    assert.equal(plan.numbers.schoolInstallsRecent, 3);
    assert.equal(typeof plan.numbers.linkOpens, "number", "existing keys are still there");
    const page = await (await req(`/a/${amb.uva}`)).text();
    assert.match(page, /<b>9<\/b><span>uva downloads<\/span><small>3 new in 14d<\/small>/);
    assert.match(page, /downloads are students who connected canvas, counted since the app update that added the count\./);
    await (await db()).prepare("INSERT INTO installs (host, day, kind, n) VALUES ('unmapped.school.edu', ?1, 'new', 2)").bind(today()).run();
    const fp = await (await req(F)).text();
    assert.match(fp, /<th class="num">downloads<\/th>/);
    assert.match(fp, /other schools/);
    assert.match(fp, /<td>unmapped\.school\.edu<\/td><td class="num">2<\/td><td class="num">2<\/td>/);
    assert.doesNotMatch(fp.split("other schools")[1].split("</table>")[0], /canvas\.its\.virginia\.edu/);
  });

  t("installs: a school without a mapped host has no number (null, never a false zero)", async () => {
    const plan = await (await req(`/a/${amb.uva}/plan.json`)).json();
    // Every school in the catalog is mapped today, so the unmapped branch is
    // exercised through the founder page: a host that no school claims stays
    // out of the per-school column and in "other schools" only.
    assert.ok("schoolInstalls" in plan.numbers);
    const fp = await (await req(F)).text();
    assert.ok(!fp.split("by school")[1].split("other schools")[0].includes("unmapped.school.edu"));
  });

  t("installs: the public dashboard and /api/stats are byte-identical after posts", async () => {
    const grab = async () => [await (await req("/")).text(), await (await req("/api/stats")).text()];
    const before = await grab();
    for (let i = 0; i < 5; i++) await post({ host: "canvas.upenn.edu", kind: "new" }, { ip: `198.51.100.${60 + i}` });
    assert.deepEqual(await grab(), before);
  });

  // Last on purpose: it fills `installs` with 2,000 hosts and then removes them.
  t("installs: the distinct-host cap refuses a new host and still counts an existing one", async () => {
    const d = await db();
    await d.prepare("DELETE FROM installs").run();
    await d.prepare("DELETE FROM install_seen").run();
    const fill = [];
    for (let i = 0; i < HOST_CAP - 1; i++) fill.push(d.prepare("INSERT INTO installs (host, day, kind, n) VALUES (?1, '2020-01-01', 'new', 1)").bind(`fill${i}.cap.edu`));
    for (let i = 0; i < fill.length; i += 200) await d.batch(fill.slice(i, i + 200));
    // 1,999 hosts: one more is allowed (the 2,000th), the next is not
    assert.equal((await post({ host: "last.cap.edu", kind: "new" }, { ip: "192.0.2.50" })).status, 200);
    assert.equal(await tally("last.cap.edu", "new"), 1);
    const r = await post({ host: "beyond.cap.edu", kind: "new" }, { ip: "192.0.2.51" });
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { ok: true });
    assert.equal(await tally("beyond.cap.edu", "new"), 0);
    assert.equal((await post({ host: "last.cap.edu", kind: "existing" }, { ip: "192.0.2.52" })).status, 200);
    assert.equal(await tally("last.cap.edu", "existing"), 1, "a host already present keeps counting");
    assert.equal((await d.prepare("SELECT COUNT(DISTINCT host) n FROM installs").first()).n, HOST_CAP);
    await d.prepare("DELETE FROM installs").run();
    await d.prepare("DELETE FROM install_seen").run();
  });
}
