// Entry point of the bundle folded into the hosting platform's single-file Worker
// (scripts/build-sites.mjs). The host file calls handle() first on every request
// and logScan() after a legacy scan.
import { handleAmbassadors } from "../worker/ambassadors.js";
import migration1 from "../migrations/0001_ambassadors.sql";
import migration2 from "../migrations/0002_poster_ideas.sql";
import migration3 from "../migrations/0003_captures.sql";
import migration4 from "../migrations/0004_installs.sql";
import migration5 from "../migrations/0005_schools.sql";

// The platform has no migration step we can rely on, and the existing Worker
// already creates its table lazily with CREATE TABLE IF NOT EXISTS, so the
// ambassador tables are created the same way. Every statement in the migration
// files (0001 the roster, 0002 poster ideas, 0003 captures and suggestions, 0004 install counts) is CREATE ... IF NOT EXISTS, so
// running them on each cold isolate is idempotent, and an existing deployment gets
// the 0002 to 0004 tables on their first request with no manual step.
let schemaReady = null;

// Statements are split off the files; ALTER TABLE ... ADD COLUMN (0005) is not
// idempotent in SQLite, so those run one by one and "duplicate column name" is
// the expected answer on every cold isolate after the first ever run.
const clean = (sql) =>
  sql
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

function ensureSchema(db) {
  if (!schemaReady) {
    const all = [migration1, migration2, migration3, migration4, migration5].flatMap(clean);
    const creates = all.filter((s) => !/^ALTER\s/i.test(s));
    const alters = all.filter((s) => /^ALTER\s/i.test(s));
    schemaReady = (async () => {
      await db.batch(creates.map((s) => db.prepare(s)));
      for (const a of alters) {
        try {
          await db.prepare(a).run();
        } catch (err) {
          if (!/duplicate column/i.test(String(err?.message ?? err) + String(err?.cause?.message ?? ""))) throw err;
        }
      }
    })().catch((err) => {
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
  // such as /api/leaderboard/ stay the host's 404. /api/install is the app's
  // anonymous install count, likewise only at exactly that path.
  const mine = parts[0] === "a" || parts[0] === "f" || parts[0] === "r" || pathname === "/api/leaderboard" || pathname === "/api/install";
  if (!mine) return null; // before touching env.DB: every other route is the host's
  await ensureSchema(env.DB);
  return handleAmbassadors(request, env, ctx);
}

export async function logScan(env, key) {
  await ensureSchema(env.DB);
  await env.DB.prepare("INSERT INTO scan_events (poster, ambassador_id) VALUES (?1, NULL)").bind(key).run();
}
