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
  const token = newToken();
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
    designs,
    leaderboard: await schoolLeaderboard(env, days),
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
  return { kind: entry.kind, channel, platform: channel ? (Object.hasOwn(CHANNELS, channel) ? CHANNELS[channel] : channel) : "rest", text: entry.text };
}

export function dayIndex(date = new Date(), tzOffsetMinutes = 300) {
  // Local day for the US east coast by default (the founders' zone); the
  // app passes its own offset so "today" matches the phone.
  return Math.floor((date.getTime() - tzOffsetMinutes * 60000) / 86400000);
}

export { CHANNELS };
