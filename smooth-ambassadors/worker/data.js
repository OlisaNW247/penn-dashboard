// D1 queries for the ambassador system. Everything that touches the roster
// lives here so it is easy to audit what is private.

import { SCHOOLS, CHANNELS, designsFor, scanKey } from "./catalog.js";

const ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"; // no 0/o/1/l/i

export function newToken(len = 14) {
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  let out = "";
  for (const b of bytes) out += ALPHABET[b % ALPHABET.length];
  return out;
}

export function sinceIso(days) {
  return new Date(Date.now() - days * 86400000).toISOString();
}

export function isPhone(contact) {
  return /^\+?[\d\s().-]{7,}$/.test((contact || "").trim());
}

export function phoneForSms(contact) {
  let d = (contact || "").replace(/[^\d+]/g, "");
  if (d.length === 10) d = "+1" + d;
  else if (d.length === 11 && d.startsWith("1")) d = "+" + d;
  return d;
}

export async function ambassadorByToken(env, token) {
  if (!token || token.length < 10 || token.length > 40) return null;
  return env.DB.prepare("SELECT * FROM ambassadors WHERE token = ?1")
    .bind(token)
    .first();
}

// The public id from a share link or sticker. Never the secret token, and a
// token passed here matches nothing because the two are generated apart.
export async function ambassadorByRef(env, ref) {
  if (typeof ref !== "string" || ref.length !== 10) return null;
  return env.DB.prepare("SELECT * FROM ambassadors WHERE ref = ?1")
    .bind(ref)
    .first();
}

export async function listAmbassadors(env) {
  const { results } = await env.DB.prepare(
    "SELECT * FROM ambassadors ORDER BY school, name",
  ).all();
  return results;
}

export async function createAmbassador(env, { name, school, contact, notes }) {
  if (typeof school !== "string" || !Object.hasOwn(SCHOOLS, school)) throw new Error("unknown school");
  name = (name || "").trim().slice(0, 80);
  if (!name) throw new Error("name required");
  // The code starts with the school (`uva-7k3m9x2p4q8w`), so a founder reading a
  // list of codes, or an ambassador reading their own, can tell which campus it
  // belongs to. The prefix is a label and no part of the secret: the fourteen
  // random characters after it are the whole credential, exactly as before, and
  // codes made before 2026-11-11 have no prefix and keep working, because a code
  // is only ever looked up whole. Moving someone to another school later does
  // not change their code (it would sign them out), so the prefix records where
  // they started. The public `ref` stays bare: it goes into every posted link,
  // where shorter is better.
  const token = `${school}-${newToken()}`;
  const ref = newToken(10); // independent of the token: see the migration
  await env.DB.prepare(
    "INSERT INTO ambassadors (token, ref, name, school, contact, notes) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
  )
    .bind(token, ref, name, school, (contact || "").trim().slice(0, 120), (notes || "").trim().slice(0, 500))
    .run();
  return ambassadorByToken(env, token);
}

export async function updateAmbassador(env, id, fields) {
  const allowed = ["name", "contact", "status", "title", "notes", "paused_until", "school"];
  const sets = [];
  const vals = [];
  for (const k of allowed) {
    if (fields[k] !== undefined) {
      if (k === "school" && !Object.hasOwn(SCHOOLS, fields[k])) continue;
      if (k === "status" && !["invited", "active", "paused", "left"].includes(fields[k])) continue;
      sets.push(`${k} = ?${vals.length + 1}`);
      vals.push(fields[k] === "" && k === "paused_until" ? null : String(fields[k]).slice(0, 500));
    }
  }
  if (!sets.length) return;
  vals.push(id);
  await env.DB.prepare(
    `UPDATE ambassadors SET ${sets.join(", ")} WHERE id = ?${vals.length}`,
  )
    .bind(...vals)
    .run();
}

export async function recordHit(env, amb, kind, key) {
  await env.DB.prepare(
    "INSERT INTO amb_hits (ambassador_id, kind, key) VALUES (?1, ?2, ?3)",
  )
    .bind(amb.id, kind, key)
    .run();
}

export async function logActivity(env, amb, { kind, design, channel, place, copies, note }) {
  await env.DB.prepare(
    "INSERT INTO activity (ambassador_id, kind, design, channel, place, copies, note) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
  )
    .bind(
      amb.id,
      kind,
      design || null,
      channel || null,
      (place || "").trim().slice(0, 120),
      Math.max(1, Math.min(200, parseInt(copies, 10) || 1)),
      (note || "").trim().slice(0, 300),
    )
    .run();
  if (amb.status === "invited") await updateAmbassador(env, amb.id, { status: "active" });
}

export async function setChecklist(env, amb, step, done) {
  if (done) {
    await env.DB.prepare(
      "INSERT OR IGNORE INTO checklist (ambassador_id, step) VALUES (?1, ?2)",
    )
      .bind(amb.id, step)
      .run();
  } else {
    await env.DB.prepare(
      "DELETE FROM checklist WHERE ambassador_id = ?1 AND step = ?2",
    )
      .bind(amb.id, step)
      .run();
  }
}

export async function addFeedback(env, amb, body) {
  body = (body || "").trim().slice(0, 2000);
  if (!body) return;
  await env.DB.prepare(
    "INSERT INTO feedback (ambassador_id, body) VALUES (?1, ?2)",
  )
    .bind(amb.id, body)
    .run();
}

// ---- poster ideas. Private to the founders: an ambassador can add and count
// their own, and nothing here returns another ambassador's row to them.
export const IDEA_DAILY_LIMIT = 5;
export const IDEA_TOTAL_LIMIT = 30;

export async function ideaCounts(env, amb) {
  const dayStart = new Date().toISOString().slice(0, 10) + "T00:00:00.000Z"; // the UTC day
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS total, COALESCE(SUM(CASE WHEN ts >= ?2 THEN 1 ELSE 0 END), 0) AS today FROM poster_ideas WHERE ambassador_id = ?1",
  )
    .bind(amb.id, dayStart)
    .first();
  return { total: row?.total ?? 0, today: row?.today ?? 0 };
}

// Returns false when the ambassador is at a limit. The limits are checked
// inside the insert itself, not by a count beforehand: a count and then an
// insert are two statements, and twenty requests sent at once all read the same
// count before any of them writes (the review ran exactly that and stored 17
// in a day meant to hold 5). D1 runs one statement at a time, so a single
// conditional insert cannot be raced, and with images near the size cap that
// is what keeps one leaked code from filling the database.
export async function addIdea(env, amb, { note, mime, image }) {
  const dayStart = new Date().toISOString().slice(0, 10) + "T00:00:00.000Z"; // the UTC day
  const r = await env.DB.prepare(
    `INSERT INTO poster_ideas (ambassador_id, note, mime, image)
     SELECT ?1, ?2, ?3, ?4
     WHERE (SELECT COUNT(*) FROM poster_ideas WHERE ambassador_id = ?1 AND ts >= ?5) < ?6
       AND (SELECT COUNT(*) FROM poster_ideas WHERE ambassador_id = ?1) < ?7`,
  )
    .bind(amb.id, note, mime, image, dayStart, IDEA_DAILY_LIMIT, IDEA_TOTAL_LIMIT)
    .run();
  return (r.meta?.changes ?? 0) > 0;
}

// Founder only. Never selects the image itself: the list stays small, and the
// bytes are fetched one at a time through the image route.
export async function listIdeas(env) {
  const { results } = await env.DB.prepare(
    "SELECT i.id, i.ambassador_id, i.ts, i.note, i.mime, (i.image IS NOT NULL) AS has_image, i.seen_at, b.name, b.school FROM poster_ideas i JOIN ambassadors b ON b.id = i.ambassador_id ORDER BY i.ts DESC, i.id DESC LIMIT 200",
  ).all();
  return results.map((r) => ({
    id: r.id,
    ambassadorId: r.ambassador_id,
    ambassador: r.name,
    school: r.school,
    ts: r.ts,
    note: r.note,
    mime: r.mime,
    hasImage: !!r.has_image,
    seenAt: r.seen_at,
  }));
}

export async function ideaImage(env, id) {
  return env.DB.prepare("SELECT mime, image FROM poster_ideas WHERE id = ?1 AND image IS NOT NULL").bind(id).first();
}

export async function markIdeaSeen(env, id) {
  await env.DB.prepare("UPDATE poster_ideas SET seen_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?1 AND seen_at IS NULL")
    .bind(id)
    .run();
}

export async function deleteIdea(env, id) {
  await env.DB.prepare("DELETE FROM poster_ideas WHERE id = ?1").bind(id).run();
}

// ---- captures: stills of an ambassador's school feed, and screenshots of how
// a post did. Private to the founders, like the ideas above. The limits are the
// same kind of promise as the idea limits and are kept the same way: inside the
// INSERT, never by reading a count first. A count and then an insert is two
// statements, and requests sent at once all read the same count before any of
// them writes; poster ideas were already overrun that way (17 stored against a
// limit of 5). The wrong fix is a lock or a retry loop in the Worker, because
// separate isolates share no memory to lock.
export const FEED_FRAMES_PER_RECORDING = 16;
export const FEED_DAILY_LIMIT = 32;
export const FEED_TOTAL_LIMIT = 96;
export const FEED_FRAME_BYTES = 200000;
export const RESULT_DAILY_LIMIT = 8;
export const RESULT_TOTAL_LIMIT = 60;
export const RESULT_IMAGE_BYTES = 300000;
export const SUGGESTION_LIMIT = 20;
// A ceiling on `captures` across every ambassador, enforced inside the same
// INSERTs as the per-ambassador limits. The arithmetic that makes it necessary:
// one ambassador may hold 96 feed frames of 200,000 bytes and 60 results of
// 300,000 bytes, about 26 MB decoded, or about 34 MB of base64 text, and each
// ambassador's limits are independent, so a roster of thirty leaked or hostile
// codes could store about a gigabyte in a database that holds the founders' real
// numbers. A global number bounds the whole table whatever the roster size.
// 1500 rows is 450 MB decoded at the very worst (every row a 300,000-byte
// result), about 600 MB as base64 text, and far less in practice (a downscaled
// screenshot is nearer 100 KB, so nearer 200 MB of text). Founders make room by deleting
// recordings and results they have dealt with.
export const CAPTURES_GLOBAL_LIMIT = 1500;

const utcDayStart = () => new Date().toISOString().slice(0, 10) + "T00:00:00.000Z";

export async function captureCounts(env, amb) {
  const { results } = await env.DB.prepare(
    "SELECT kind, COUNT(*) AS total, COALESCE(SUM(CASE WHEN ts >= ?2 THEN 1 ELSE 0 END), 0) AS today FROM captures WHERE ambassador_id = ?1 GROUP BY kind",
  )
    .bind(amb.id, utcDayStart())
    .all();
  const by = (k) => results.find((r) => r.kind === k) ?? { total: 0, today: 0 };
  return { feed: { total: by("feed").total, today: by("feed").today }, result: { total: by("result").total, today: by("result").today } };
}

export async function capturesFull(env) {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM captures").first();
  return (row?.n ?? 0) >= CAPTURES_GLOBAL_LIMIT;
}

// One still of a recording. Returns "stored", "duplicate" (this batch and seq
// are already held, which is a client retry and not an error), "full" (the
// global ceiling refused it) or "limit" (an ambassador's own limit).
// NOT EXISTS makes the retry a no-write inside the same statement, so two
// copies of one frame arriving together still store one.
export async function addFeedFrame(env, amb, { batch, seq, mime, image }) {
  const r = await env.DB.prepare(
    `INSERT INTO captures (ambassador_id, kind, batch, seq, mime, image)
     SELECT ?1, 'feed', ?2, ?3, ?4, ?5
     WHERE NOT EXISTS (SELECT 1 FROM captures WHERE ambassador_id = ?1 AND kind = 'feed' AND batch = ?2 AND seq = ?3)
       AND (SELECT COUNT(*) FROM captures WHERE ambassador_id = ?1 AND kind = 'feed' AND ts >= ?6) < ?7
       AND (SELECT COUNT(*) FROM captures WHERE ambassador_id = ?1 AND kind = 'feed') < ?8
       AND (SELECT COUNT(*) FROM captures WHERE ambassador_id = ?1 AND kind = 'feed' AND batch = ?2) < ?9
       AND (SELECT COUNT(*) FROM captures) < ?10`,
  )
    .bind(amb.id, batch, seq, mime, image, utcDayStart(), FEED_DAILY_LIMIT, FEED_TOTAL_LIMIT, FEED_FRAMES_PER_RECORDING, CAPTURES_GLOBAL_LIMIT)
    .run();
  if ((r.meta?.changes ?? 0) > 0) return "stored";
  const dup = await env.DB.prepare(
    "SELECT 1 AS x FROM captures WHERE ambassador_id = ?1 AND kind = 'feed' AND batch = ?2 AND seq = ?3",
  )
    .bind(amb.id, batch, seq)
    .first();
  if (dup) return "duplicate";
  return (await capturesFull(env)) ? "full" : "limit";
}

export async function addResult(env, amb, { platform, style, upvotes, views, note, mime, image }) {
  const r = await env.DB.prepare(
    `INSERT INTO captures (ambassador_id, kind, platform, style, upvotes, views, note, mime, image)
     SELECT ?1, 'result', ?2, ?3, ?4, ?5, ?6, ?7, ?8
     WHERE (SELECT COUNT(*) FROM captures WHERE ambassador_id = ?1 AND kind = 'result' AND ts >= ?9) < ?10
       AND (SELECT COUNT(*) FROM captures WHERE ambassador_id = ?1 AND kind = 'result') < ?11
       AND (SELECT COUNT(*) FROM captures) < ?12`,
  )
    .bind(amb.id, platform, style, upvotes, views, note, mime, image, utcDayStart(), RESULT_DAILY_LIMIT, RESULT_TOTAL_LIMIT, CAPTURES_GLOBAL_LIMIT)
    .run();
  if ((r.meta?.changes ?? 0) > 0) return "stored";
  return (await capturesFull(env)) ? "full" : "limit";
}

// Founder only. Metadata, never the image: the bytes are fetched one at a time
// through the capture route.
export async function listCaptures(env) {
  const { results } = await env.DB.prepare(
    "SELECT c.id, c.ambassador_id, c.ts, c.kind, c.batch, c.seq, c.platform, c.style, c.upvotes, c.views, c.note, c.mime, c.seen_at, b.name, b.school FROM captures c JOIN ambassadors b ON b.id = c.ambassador_id ORDER BY c.ts DESC, c.id DESC LIMIT 1000",
  ).all();
  return results.map((r) => ({
    id: r.id,
    ambassadorId: r.ambassador_id,
    ambassador: r.name,
    school: r.school,
    ts: r.ts,
    kind: r.kind,
    batch: r.batch,
    seq: r.seq,
    platform: r.platform,
    style: r.style,
    upvotes: r.upvotes,
    views: r.views,
    note: r.note,
    mime: r.mime,
    seenAt: r.seen_at,
  }));
}

export async function captureImage(env, id) {
  return env.DB.prepare("SELECT mime, image FROM captures WHERE id = ?1").bind(id).first();
}

// Acts on one row by id, or on a whole recording by (ambassador, batch).
export async function markCaptureSeen(env, { id, amb, batch }) {
  const set = "UPDATE captures SET seen_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE seen_at IS NULL AND ";
  if (id) await env.DB.prepare(set + "id = ?1").bind(id).run();
  else await env.DB.prepare(set + "ambassador_id = ?1 AND kind = 'feed' AND batch = ?2").bind(amb, batch).run();
}

export async function deleteCapture(env, { id, amb, batch }) {
  if (id) await env.DB.prepare("DELETE FROM captures WHERE id = ?1").bind(id).run();
  else await env.DB.prepare("DELETE FROM captures WHERE ambassador_id = ?1 AND kind = 'feed' AND batch = ?2").bind(amb, batch).run();
}

// ---- suggestions: a post a founder wants one ambassador to try.
// A departed ambassador counts as not existing: their code is dead, so nothing
// new is addressed to them.
export async function ambassadorExists(env, id) {
  return !!(await env.DB.prepare("SELECT 1 AS x FROM ambassadors WHERE id = ?1 AND status <> 'left'").bind(id).first());
}

// Returns false when nothing was written (unknown ambassador, or at the limit).
export async function addSuggestion(env, ambassadorId, { text, reply }) {
  const r = await env.DB.prepare(
    `INSERT INTO suggestions (ambassador_id, text, reply)
     SELECT ?1, ?2, ?3
     WHERE EXISTS (SELECT 1 FROM ambassadors WHERE id = ?1 AND status <> 'left')
       AND (SELECT COUNT(*) FROM suggestions WHERE ambassador_id = ?1) < ?4`,
  )
    .bind(ambassadorId, text, reply, SUGGESTION_LIMIT)
    .run();
  return (r.meta?.changes ?? 0) > 0;
}

export async function deleteSuggestion(env, id) {
  await env.DB.prepare("DELETE FROM suggestions WHERE id = ?1").bind(id).run();
}

// One ambassador's own, newest first. The only suggestions query an ambassador
// route calls, and it is keyed on their id.
export async function suggestionsFor(env, ambassadorId) {
  const { results } = await env.DB.prepare(
    "SELECT id, text, reply, ts FROM suggestions WHERE ambassador_id = ?1 ORDER BY ts DESC, id DESC",
  )
    .bind(ambassadorId)
    .all();
  return results;
}

export async function listSuggestions(env) {
  const { results } = await env.DB.prepare(
    "SELECT s.id, s.ambassador_id, s.ts, s.text, s.reply, b.name FROM suggestions s JOIN ambassadors b ON b.id = s.ambassador_id ORDER BY s.ts DESC, s.id DESC",
  ).all();
  return results.map((r) => ({ id: r.id, ambassadorId: r.ambassador_id, ambassador: r.name, ts: r.ts, text: r.text, reply: r.reply }));
}

// scans.total per poster key for one school, so a page or the app can show
// how often each design was scanned there.
export async function schoolDesignScans(env, school) {
  const { results } = await env.DB.prepare(
    "SELECT poster, total FROM scans WHERE poster LIKE ?1 OR (?2 = 'upenn' AND poster NOT LIKE '%/%')",
  )
    .bind(`${school}/%`, school)
    .all();
  return Object.fromEntries(results.map((r) => [r.poster, r.total]));
}

// ---- install counts: one anonymous tally per school host, sent by the app after
// a student connects Canvas. Two limits keep a public, unauthenticated endpoint
// from being used to flood the table or to inflate a school's number, and both
// are enforced inside the write statement, never by reading a count first. A
// count and then an insert is two statements, and requests sent at once all read
// the same count before any of them writes (poster ideas were overrun that way,
// 17 stored against a limit of 5). The wrong fix is a lock or a retry loop in the
// Worker: separate isolates share no memory to lock.
//
// At most 30 counted per network per host per day. The "network" is a bucket,
// the SHA-256 of a salt that is random per UTC day and deleted when the day is
// over, so after that nobody can hash an address and find its bucket.
export const INSTALL_PER_NETWORK_DAILY_LIMIT = 30;
// At most 2,000 distinct hosts in `installs`. The host is the one thing the
// caller chooses freely, so without a ceiling one script could write a new row
// per request forever. A new host beyond it is silently not counted; a host
// already present keeps counting.
export const INSTALL_DISTINCT_HOST_LIMIT = 2000;

const utcDay = (date) => date.toISOString().slice(0, 10);

async function installBucket(env, day, ip, host) {
  const salt = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
  await env.DB.prepare("INSERT OR IGNORE INTO install_salts (day, salt) VALUES (?1, ?2)").bind(day, salt).run();
  const row = await env.DB.prepare("SELECT salt FROM install_salts WHERE day = ?1").bind(day).first();
  const bytes = new TextEncoder().encode(`${row.salt}|${ip}|${host}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Returns true when the install was counted. A limit swallowing it is a normal
// false, and the caller still answers 200.
export async function recordInstall(env, { host, kind, ip, now = new Date() }) {
  const day = utcDay(now);
  const yesterday = utcDay(new Date(now.getTime() - 86400000));
  // Opportunistic: whoever writes next removes what is over. The tally in
  // `installs` is the only thing that outlives the day.
  await env.DB.batch([
    env.DB.prepare("DELETE FROM install_seen WHERE day < ?1").bind(yesterday),
    env.DB.prepare("DELETE FROM install_salts WHERE day < ?1").bind(yesterday),
  ]);
  const bucket = await installBucket(env, day, ip || "noip", host);
  // The DO UPDATE only fires while n is under the limit, so the statement
  // itself decides; RETURNING gives a row only when it wrote.
  const seen = await env.DB.prepare(
    `INSERT INTO install_seen (day, bucket, n) VALUES (?1, ?2, 1)
     ON CONFLICT(day, bucket) DO UPDATE SET n = n + 1 WHERE n < ?3
     RETURNING n`,
  )
    .bind(day, bucket, INSTALL_PER_NETWORK_DAILY_LIMIT)
    .all();
  if (!seen.results?.length) return false;
  const r = await env.DB.prepare(
    `INSERT INTO installs (host, day, kind, n)
     SELECT ?1, ?2, ?3, 1
     WHERE EXISTS (SELECT 1 FROM installs WHERE host = ?1)
        OR (SELECT COUNT(DISTINCT host) FROM installs) < ?4
     ON CONFLICT(host, day, kind) DO UPDATE SET n = n + 1`,
  )
    .bind(host, day, kind, INSTALL_DISTINCT_HOST_LIMIT)
    .run();
  return (r.meta?.changes ?? 0) > 0;
}

const placeholders = (n, from = 1) => Array.from({ length: n }, (_, i) => `?${i + from}`).join(",");

// { total, recent } for one school: total is every kind and every day, recent
// is kind 'new' within the last `days` UTC days. null when the school has no
// mapped host, so a page can hide the number instead of showing a false zero.
export async function installTotals(env, school, days = 14, now = new Date()) {
  const hosts = SCHOOLS[school]?.canvasHosts;
  if (!hosts?.length) return null;
  const since = utcDay(new Date(now.getTime() - days * 86400000));
  const row = await env.DB.prepare(
    `SELECT COALESCE(SUM(n), 0) AS total,
            COALESCE(SUM(CASE WHEN kind = 'new' AND day >= ?1 THEN n ELSE 0 END), 0) AS recent
     FROM installs WHERE host IN (${placeholders(hosts.length, 2)})`,
  )
    .bind(since, ...hosts)
    .first();
  return { total: row?.total ?? 0, recent: row?.recent ?? 0 };
}

export async function installsBySchool(env, days = 14, now = new Date()) {
  const out = {};
  for (const school of Object.keys(SCHOOLS)) out[school] = await installTotals(env, school, days, now);
  return out;
}

const mappedHosts = () => Object.values(SCHOOLS).flatMap((s) => s.canvasHosts ?? []);

// Hosts no school maps to, most installs first: what a founder reads to decide
// which school to add next.
export async function installsUnmapped(env, limit = 30, days = 14, now = new Date()) {
  const mapped = mappedHosts();
  const since = utcDay(new Date(now.getTime() - days * 86400000));
  const { results } = await env.DB.prepare(
    `SELECT host, SUM(n) AS total, SUM(CASE WHEN kind = 'new' AND day >= ?1 THEN n ELSE 0 END) AS recent
     FROM installs ${mapped.length ? `WHERE host NOT IN (${placeholders(mapped.length, 3)})` : ""}
     GROUP BY host ORDER BY total DESC, host LIMIT ?2`,
  )
    .bind(since, limit, ...mapped)
    .all();
  return results.map((r) => ({ host: r.host, total: r.total, recent: r.recent }));
}

// Everything one ambassador is allowed to see: their own numbers only.
export async function ambassadorStats(env, amb, days = 14) {
  const since = sinceIso(days);
  const [hitsAll, hitsRecent, acts, checks, schoolRecent, schoolTotals] =
    await env.DB.batch([
      env.DB.prepare(
        "SELECT kind, key, COUNT(*) n FROM amb_hits WHERE ambassador_id = ?1 GROUP BY kind, key",
      ).bind(amb.id),
      env.DB.prepare(
        "SELECT kind, key, COUNT(*) n FROM amb_hits WHERE ambassador_id = ?1 AND ts >= ?2 GROUP BY kind, key",
      ).bind(amb.id, since),
      env.DB.prepare(
        "SELECT * FROM activity WHERE ambassador_id = ?1 ORDER BY ts DESC LIMIT 30",
      ).bind(amb.id),
      env.DB.prepare("SELECT step FROM checklist WHERE ambassador_id = ?1").bind(amb.id),
      env.DB.prepare(
        "SELECT COUNT(*) n FROM scan_events WHERE ts >= ?1 AND (poster LIKE ?2 OR (?3 = 'upenn' AND poster NOT LIKE '%/%'))",
      ).bind(since, `${amb.school}/%`, amb.school),
      env.DB.prepare(
        "SELECT COALESCE(SUM(total),0) n FROM scans WHERE poster LIKE ?1 OR (?2 = 'upenn' AND poster NOT LIKE '%/%')",
      ).bind(`${amb.school}/%`, amb.school),
    ]);
  const sum = (rows, kind) => rows.results.filter((r) => r.kind === kind).reduce((a, r) => a + r.n, 0);
  return {
    posterOpens: sum(hitsAll, "poster"),
    linkOpens: sum(hitsAll, "link"),
    posterOpensRecent: sum(hitsRecent, "poster"),
    linkOpensRecent: sum(hitsRecent, "link"),
    byKeyRecent: hitsRecent.results,
    byKeyAll: hitsAll.results,
    activity: acts.results,
    drops: acts.results.filter((a) => a.kind === "drop").reduce((a, r) => a + r.copies, 0),
    posts: acts.results.filter((a) => a.kind === "post").length,
    checked: new Set(checks.results.map((r) => r.step)),
    schoolScansRecent: schoolRecent.results[0]?.n ?? 0,
    schoolScansTotal: schoolTotals.results[0]?.n ?? 0,
    days,
  };
}

// Public, school level only. No names, no tokens, no contacts.
export async function schoolLeaderboard(env, days = 14) {
  const since = sinceIso(days);
  const [totals, recent, ambLinks, ambCount] = await env.DB.batch([
    env.DB.prepare("SELECT poster, total FROM scans"),
    env.DB.prepare(
      "SELECT poster, COUNT(*) n FROM scan_events WHERE ts >= ?1 GROUP BY poster",
    ).bind(since),
    env.DB.prepare(
      "SELECT a.school, COUNT(*) n FROM amb_hits h JOIN ambassadors a ON a.id = h.ambassador_id WHERE h.kind = 'link' AND h.ts >= ?1 GROUP BY a.school",
    ).bind(since),
    env.DB.prepare(
      "SELECT school, COUNT(*) n FROM ambassadors WHERE status IN ('invited','active') GROUP BY school",
    ),
  ]);
  const schoolOf = (key) => (key.includes("/") ? key.split("/")[0] : "upenn");
  const out = {};
  for (const k of Object.keys(SCHOOLS))
    out[k] = { school: k, name: SCHOOLS[k].name, total: 0, recent: 0, linkOpensRecent: 0, ambassadors: 0 };
  for (const r of totals.results) if (out[schoolOf(r.poster)]) out[schoolOf(r.poster)].total += r.total;
  for (const r of recent.results) if (out[schoolOf(r.poster)]) out[schoolOf(r.poster)].recent += r.n;
  for (const r of ambLinks.results) if (out[r.school]) out[r.school].linkOpensRecent = r.n;
  for (const r of ambCount.results) if (out[r.school]) out[r.school].ambassadors = r.n;
  const list = Object.values(out).sort((a, b) => b.recent + b.linkOpensRecent - (a.recent + a.linkOpensRecent) || b.total - a.total);
  list.forEach((s, i) => (s.rank = i + 1));
  return { days, since, schools: list };
}

// Founder-only: performance by school, design and ambassador.
export async function founderStats(env, days = 14) {
  const since = sinceIso(days);
  const [ambs, hits, acts, fb, rems, designRecent, designTotals, checks] =
    await env.DB.batch([
      env.DB.prepare("SELECT * FROM ambassadors ORDER BY school, name"),
      env.DB.prepare(
        "SELECT ambassador_id, kind, SUM(CASE WHEN ts >= ?1 THEN 1 ELSE 0 END) recent, COUNT(*) total FROM amb_hits GROUP BY ambassador_id, kind",
      ).bind(since),
      env.DB.prepare(
        "SELECT a.*, b.name, b.school FROM activity a JOIN ambassadors b ON b.id = a.ambassador_id ORDER BY a.ts DESC LIMIT 100",
      ),
      env.DB.prepare(
        "SELECT f.*, b.name, b.school FROM feedback f JOIN ambassadors b ON b.id = f.ambassador_id ORDER BY f.ts DESC LIMIT 100",
      ),
      env.DB.prepare(
        "SELECT * FROM reminders ORDER BY ts DESC",
      ),
      env.DB.prepare(
        "SELECT poster, COUNT(*) n FROM scan_events WHERE ts >= ?1 GROUP BY poster",
      ).bind(since),
      env.DB.prepare("SELECT poster, total FROM scans"),
      env.DB.prepare("SELECT ambassador_id, COUNT(*) n FROM checklist GROUP BY ambassador_id"),
    ]);
  const hitMap = {};
  for (const h of hits.results) {
    hitMap[h.ambassador_id] ??= {};
    hitMap[h.ambassador_id][h.kind] = { recent: h.recent, total: h.total };
  }
  const remByAmb = {};
  for (const r of rems.results) (remByAmb[r.ambassador_id] ??= []).push(r);
  const checkMap = Object.fromEntries(checks.results.map((c) => [c.ambassador_id, c.n]));
  const ambassadors = ambs.results.map((a) => {
    const h = hitMap[a.id] || {};
    const myActs = acts.results.filter((x) => x.ambassador_id === a.id);
    const myRems = remByAmb[a.id] || [];
    const digests = myRems.filter((r) => r.kind === "digest");
    const unansweredStreak = (() => {
      let n = 0;
      for (const r of digests) {
        if (r.replied) break;
        n++;
      }
      return n;
    })();
    const pausedUntil = a.paused_until ? new Date(a.paused_until) : null;
    const paused = a.status === "paused" || a.status === "left" || (pausedUntil && pausedUntil > new Date());
    return {
      ...a,
      posterOpens: h.poster?.total ?? 0,
      posterOpensRecent: h.poster?.recent ?? 0,
      linkOpens: h.link?.total ?? 0,
      linkOpensRecent: h.link?.recent ?? 0,
      drops: myActs.filter((x) => x.kind === "drop").reduce((s, x) => s + x.copies, 0),
      posts: myActs.filter((x) => x.kind === "post").length,
      lastActivity: myActs[0]?.ts ?? null,
      checklistDone: checkMap[a.id] ?? 0,
      lastReminder: myRems[0] ?? null,
      unansweredStreak,
      paused,
      skipDigest: paused || unansweredStreak >= 2,
    };
  });
  const recentMap = Object.fromEntries(designRecent.results.map((r) => [r.poster, r.n]));
  const totalMap = Object.fromEntries(designTotals.results.map((r) => [r.poster, r.total]));
  const designs = [];
  for (const school of Object.keys(SCHOOLS))
    for (const d of designsFor(school)) {
      const key = scanKey(school, d);
      designs.push({ school, design: d, key, recent: recentMap[key] ?? 0, total: totalMap[key] ?? 0 });
    }
  designs.sort((a, b) => b.recent - a.recent || b.total - a.total);
  return {
    days,
    since,
    ambassadors,
    activity: acts.results,
    feedback: fb.results,
    ideas: await listIdeas(env),
    captures: await listCaptures(env),
    suggestions: await listSuggestions(env),
    designs,
    leaderboard: await schoolLeaderboard(env, days),
    installsBySchool: await installsBySchool(env, days),
    installsUnmapped: await installsUnmapped(env, 30, days),
  };
}

export async function recordReminder(env, id, kind) {
  await env.DB.prepare(
    "INSERT INTO reminders (ambassador_id, kind) VALUES (?1, ?2)",
  )
    .bind(id, kind.slice(0, 40))
    .run();
}

export async function markReplied(env, id) {
  await env.DB.prepare(
    "UPDATE reminders SET replied = 1 WHERE ambassador_id = ?1 AND replied = 0",
  )
    .bind(id)
    .run();
}

export async function markFeedbackSeen(env, id) {
  await env.DB.prepare("UPDATE feedback SET seen = 1 WHERE id = ?1").bind(id).run();
}

// The app's daily post: one entry from messages.daily per day, rotating.
// `anon` entries become the ambassador's chosen anonymous app (fizz by
// default). Deterministic per day so a notification and the page agree.
export function dailyPost({ daily, dayIndex, anonApp = "fizz" }) {
  if (!daily?.length) return null;
  const entry = daily[((dayIndex % daily.length) + daily.length) % daily.length];
  const channel = entry.kind === "anon" ? (Object.hasOwn(CHANNELS, anonApp) ? anonApp : "fizz") : entry.kind === "rest" ? null : entry.kind;
  return { kind: entry.kind, channel, platform: channel ? (Object.hasOwn(CHANNELS, channel) ? CHANNELS[channel] : channel) : "rest", text: entry.text, ...(entry.reply ? { reply: entry.reply } : {}) };
}

export function dayIndex(date = new Date(), tzOffsetMinutes = 300) {
  // Local day for the US east coast by default (the founders' zone); the
  // app passes its own offset so "today" matches the phone.
  return Math.floor((date.getTime() - tzOffsetMinutes * 60000) / 86400000);
}

export { CHANNELS };
