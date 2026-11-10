// Entry point of the bundle folded into the hosting platform's single-file Worker
// (scripts/build-sites.mjs). The host file calls handle() first on every request
// and logScan() after a legacy scan.
import { handleAmbassadors } from "../worker/ambassadors.js";
import migration from "../migrations/0001_ambassadors.sql";

// The platform has no migration step we can rely on, and the existing Worker
// already creates its table lazily with CREATE TABLE IF NOT EXISTS, so the
// ambassador tables are created the same way. Every statement in the migration
// is CREATE ... IF NOT EXISTS, so running it on each cold isolate is idempotent.
let schemaReady = null;

function ensureSchema(db) {
  if (!schemaReady) {
    const statements = migration
      .split("\n")
      .filter((line) => !line.trim().startsWith("--"))
      .join("\n")
      .split(";")
      .map((s) => s.trim())
      .filter(Boolean);
    schemaReady = db.batch(statements.map((s) => db.prepare(s))).catch((err) => {
      schemaReady = null; // let the next request retry
      throw err;
    });
  }
  return schemaReady;
}

export async function handle(request, env, ctx) {
  const { pathname } = new URL(request.url);
  const parts = pathname.split("/").filter(Boolean);
  // /a (private), /f (founders) and /r (public share and sticker links) are
  // ours; the leaderboard only at exactly /api/leaderboard, so near-misses
  // such as /api/leaderboard/ stay the host's 404.
  const mine = parts[0] === "a" || parts[0] === "f" || parts[0] === "r" || pathname === "/api/leaderboard";
  if (!mine) return null; // before touching env.DB: every other route is the host's
  await ensureSchema(env.DB);
  return handleAmbassadors(request, env, ctx);
}

export async function logScan(env, key) {
  await ensureSchema(env.DB);
  await env.DB.prepare("INSERT INTO scan_events (poster, ambassador_id) VALUES (?1, NULL)").bind(key).run();
}
