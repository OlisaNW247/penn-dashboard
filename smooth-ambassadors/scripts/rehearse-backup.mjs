// Dress rehearsal of a deploy on the real data.
//
//   node scripts/rehearse-backup.mjs <backup-dir> <original index.js> <edited dist/server/index.js>
//   LIVE=1 ... also compares the backup with the live /api/stats (one read-only GET).
//
// <backup-dir> holds scans.json and scans.sql, the export of the live `scans` table
// taken before a deploy. The rows are loaded into two local D1 databases and run
// through the original Worker and the edited one: the dashboard numbers must match
// the backup from both, the whole ambassador flow must leave every row as it was,
// and a scan must add exactly 1 to one row. Nothing here opens a /scan link on the
// live site. Keep the backup itself out of git (backups/ is ignored).
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { Miniflare } from "miniflare";

const [backupDir, originalPath, editedPath] = process.argv.slice(2);
const backup = JSON.parse(readFileSync(backupDir + "/scans.json", "utf8"));
const sql = readFileSync(backupDir + "/scans.sql", "utf8");
const rows = backup.rows;
const sha = (s) => createHash("sha256").update(s).digest("hex").slice(0, 16);
const say = (ok, msg) => { console.log((ok ? "PASS  " : "FAIL  ") + msg); if (!ok) process.exitCode = 1; };

// 1. The backup itself.
say(rows.length === 62, `backup has ${rows.length} rows (README says 62)`);
say(new Set(rows.map((r) => r.poster)).size === rows.length, "no duplicate keys");
say(rows.every((r) => typeof r.poster === "string" && Number.isInteger(r.total) && r.total >= 0), "every row is a string key and a whole number");
const fromSql = [...sql.matchAll(/INSERT INTO scans \(poster, total\) VALUES \('([^']+)', (\d+)\);/g)].map((m) => ({ poster: m[1], total: Number(m[2]) }));
say(JSON.stringify(fromSql) === JSON.stringify(rows), `scans.sql and scans.json hold the same ${fromSql.length} rows`);
const sum = rows.reduce((n, r) => n + r.total, 0);
console.log(`      total link opens in the backup: ${sum}`);

const make = async (path, bindings = {}) => {
  const mf = new Miniflare({ modules: [{ type: "ESModule", path: "index.js", contents: readFileSync(path, "utf8") }], compatibilityDate: "2026-01-01", d1Databases: { DB: "db" }, bindings });
  const db = await mf.getD1Database("DB");
  await db.prepare("CREATE TABLE IF NOT EXISTS scans (poster TEXT PRIMARY KEY, total INTEGER NOT NULL)").run();
  await db.batch(rows.map((r) => db.prepare("INSERT INTO scans (poster, total) VALUES (?1, ?2)").bind(r.poster, r.total)));
  return { mf, db };
};
const get = (x, p, init) => x.mf.dispatchFetch("https://example.test" + p, { redirect: "manual", ...init });
const dump = async (x) => JSON.stringify((await x.db.prepare("SELECT poster, total FROM scans ORDER BY poster").all()).results);
const original = await make(originalPath);
const edited = await make(editedPath, { FOUNDER_TOKEN: "rehearsal-founder-token-0123456789" });
const before = JSON.stringify([...rows].sort((a, b) => (a.poster < b.poster ? -1 : 1)));

// 2. Every backed-up key is one the Worker lists: nothing orphaned, nothing missing.
const statsO = await (await get(original, "/api/stats")).text();
const statsE = await (await get(edited, "/api/stats")).text();
say(statsO === statsE, `/api/stats identical from both Workers on the real data (sha ${sha(statsE)})`);
const stats = JSON.parse(statsE).rows;
const key = (r) => (r.school === "upenn" ? r.poster : r.school + "/" + r.poster);
const listed = new Map(stats.map((r) => [key(r), r.total]));
say(rows.every((r) => listed.get(r.poster) === r.total), "every backed-up row shows in /api/stats with its exact total");
say(stats.length === rows.length && stats.every((r) => r.total > 0 || !rows.find((b) => b.poster === key(r))), `the Worker lists ${stats.length} school and design pairs, the backup has a row for ${rows.length}`);
say(stats.reduce((n, r) => n + r.total, 0) === sum, "the dashboard's grand total equals the backup's");

// 3. The whole ambassador system runs on top of the real data and moves nothing.
const F = "/f/rehearsal-founder-token-0123456789";
say((await get(edited, "/a/aaaaaaaaaaaaaa/plan.json")).status === 404, "unknown code is a 404 (tables created lazily beside the real scans)");
const add = await get(edited, F + "/add", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "name=Rehearsal+Person&school=uva&contact=&notes=" });
const token = new URL(add.headers.get("location"), "https://example.test").searchParams.get("created");
say(add.status === 303 && !!token, "founder can add an ambassador");
const plan = await (await get(edited, `/a/${token}/plan.json?anon=fizz&tz=300`, { headers: { accept: "application/json" } })).json();
say(plan.name === "Rehearsal Person" && plan.school === "uva" && typeof plan.today?.kind === "string", "the app's sign-in request answers with a plan");
say(plan.numbers.schoolScans === rows.filter((r) => r.poster.startsWith("uva/")).reduce((n, r) => n + r.total, 0), `the plan's school total (${plan.numbers.schoolScans}) is UVA's real total`);
for (const [a, b] of [["post", { channel: plan.today.channel ?? "fizz", place: "daily" }], ["check", { step: plan.checklist[0].key, done: "1" }], ["feedback", { body: "rehearsal" }], ["pause", { weeks: "4" }], ["pause", { weeks: "0" }]]) {
  const r = await get(edited, `/a/${token}/${a}`, { method: "POST", headers: { "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(b) });
  say(r.status === 200 && (await r.json()).ok === true, `POST ${a} answers ok`);
}
await get(edited, F); await get(edited, "/api/leaderboard"); await get(edited, `/a/${token}`); await get(edited, `/a/${token}/stickers`);
say((await dump(edited)) === before, "after all of that, all 62 scans rows are exactly the backup");

// 4. One scan each way, same key, both Workers: +1 and nothing else.
const ref = (await edited.db.prepare("SELECT ref FROM ambassadors WHERE token = ?1").bind(token).first()).ref;
const want = JSON.parse(before).map((r) => (r.poster === "uva/ib" ? { ...r, total: r.total + 1 } : r));
const a1 = await get(original, "/scan/uva/ib"); const a2 = await get(edited, "/scan/uva/ib");
say(a1.status === 302 && a2.status === 302 && a1.headers.get("location") === a2.headers.get("location"), `a scan redirects to ${a2.headers.get("location")} from both`);
say((await dump(original)) === JSON.stringify(want) && (await dump(edited)) === JSON.stringify(want), "a plain scan adds exactly 1 to uva/ib in both, every other row untouched");
await get(edited, `/r/${ref}/p/ib`);
want.find((r) => r.poster === "uva/ib").total += 1;
say((await dump(edited)) === JSON.stringify(want), "an ambassador's sticker scan adds exactly 1 to uva/ib, every other row untouched");
await get(edited, `/r/${ref}/s/fizz`);
say((await dump(edited)) === JSON.stringify(want), "a share-link open changes no scans row");

// 5. The backup against the live site right now (read-only).
if (process.env.LIVE === "1") {
  try {
    const live = (await (await fetch("https://smooth-poster-scans.jazzysmile20.chatgpt.site/api/stats", { cache: "no-store" })).json()).rows;
    const liveMap = new Map(live.map((r) => [key(r), r.total]));
    const moved = rows.filter((r) => liveMap.get(r.poster) !== r.total).map((r) => `${r.poster}: backup ${r.total}, live ${liveMap.get(r.poster)}`);
    const lower = rows.filter((r) => (liveMap.get(r.poster) ?? -1) < r.total);
    say(live.length === stats.length, `live lists ${live.length} pairs, same as the Worker in the archive`);
    say(lower.length === 0, "no live total is below the backup");
    console.log(moved.length ? "      changed since the backup:\n        " + moved.join("\n        ") : "      live totals equal the backup exactly");
  } catch (e) { console.log("      could not read the live site: " + e.message); }
}
await original.mf.dispose(); await edited.mf.dispose();
