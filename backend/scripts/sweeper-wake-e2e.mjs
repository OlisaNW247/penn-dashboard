#!/usr/bin/env node
// Plays the student's phone against the LIVE `sweeper-wake` function, end to
// end, with no real phone and no real Apple device token
// (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md §8). A throwaway anonymous user
// uploads a syntactically valid FAKE token with one moment a minute ahead,
// waits for the once-a-minute tick, and reads the function's own log line:
// Apple answering `400 BadDeviceToken` to a fake token is the proof that the
// request reached Apple over HTTP/2 with a valid provider JWT (a status of 0,
// a connection-level failure, is the HTTP/2 question of §3.3 answered "no").
// Then the refusals (25 moments, a moment three days out, a forbidden key, no
// version header, a tick without its secret), the delete, and the throwaway
// user's deletion through `delete-account`.
//
//   node backend/scripts/sweeper-wake-e2e.mjs [--dry-run] [--no-logs]
//
// Reading the tick line and pg_cron's run history needs the Management API
// token (SUPABASE_ACCESS_TOKEN or the token file; see deploy-function.mjs);
// without one, those two steps are skipped and said so. The token is never
// printed, and neither are the JWT, the fake device token or a moment.
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { PROJECT_REF, resolveManagementToken } from "./deploy-function.mjs";

const SUPABASE_URL = process.env.LHF_SUPABASE_URL ?? `https://${PROJECT_REF}.supabase.co`;
const PUBLISHABLE_KEY = process.env.LHF_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt";
const MANAGEMENT = "https://api.supabase.com";
export const VERSION = "3.5.0";

export const STEPS = [
  "throwaway anonymous user",
  "put one moment a minute or so ahead: 200, stored 1, next moment",
  "the tick: the function's log line says claimed 1, sent 1 and Apple's status (400 BadDeviceToken proves HTTP/2 and the JWT)",
  "refusals: 25 moments, a moment 3 days out, an assignment_id key, no version header, a tick without its secret",
  "pg_cron: the tick ran every minute in the last five",
  "delete: 200, and a second delete finds nothing",
  "cleanup: delete-account",
];

// ---- pure parts -----------------------------------------------------

/** The first whole minute at least `leadSeconds` after `now`. */
export function momentAhead(now, leadSeconds = 45) {
  return new Date(Math.ceil((now.getTime() + leadSeconds * 1000) / 60000) * 60000);
}

/** A 64-hex token that is well formed and belongs to no device. */
export function fakeToken(bytes = crypto.randomBytes(32)) {
  return Buffer.from(bytes).toString("hex");
}

export function manyMoments(now, n) {
  return Array.from({ length: n }, (_, i) => new Date(momentAhead(now).getTime() + i * 60000).toISOString());
}

export function logsQuery() {
  return "select timestamp, event_message from logs where source = 'function_logs' and event_message like '%sweeper-wake tick%' order by timestamp desc limit 50";
}

export function logsURL(ref, now, hours = 1) {
  const params = new URLSearchParams({
    sql: logsQuery(),
    iso_timestamp_start: new Date(now.getTime() - hours * 3600 * 1000).toISOString(),
    iso_timestamp_end: new Date(now.getTime() + 60 * 1000).toISOString(),
  });
  return `${MANAGEMENT}/v1/projects/${ref}/analytics/endpoints/logs?${params}`;
}

/** `sweeper-wake tick <iso>: claimed n, sent s, status {...}, deleted d, took t ms` -> object, or null. */
export function parseTickLine(line) {
  const m = /sweeper-wake tick (\S+): claimed (\d+), sent (\d+), status (\{[^}]*\}), deleted (\d+), took (\d+) ms/.exec(String(line ?? ""));
  if (!m) return null;
  let status;
  try {
    status = JSON.parse(m[4]);
  } catch {
    return null;
  }
  return { minute: m[1], claimed: Number(m[2]), sent: Number(m[3]), status, deleted: Number(m[5]), took: Number(m[6]) };
}

/** From the logs endpoint's answer, the newest tick line with `claimed >= 1` at or after `since`. */
export function findClaimingTick(result, since) {
  const rows = Array.isArray(result?.result) ? result.result : Array.isArray(result) ? result : [];
  for (const row of rows) {
    const tick = parseTickLine(row?.event_message);
    if (tick && tick.claimed >= 1 && Date.parse(tick.minute) >= since.getTime()) return tick;
  }
  return null;
}

/** What a tick that claimed our fake token must have said for the probe to pass. */
export function judgeTick(tick) {
  if (!tick) return { ok: false, detail: "no tick line with claimed >= 1 appeared" };
  if (tick.status["0"]) return { ok: false, detail: `a connection-level failure (status 0): the Edge runtime did not reach Apple; see design 3.3 for the Vercel fallback` };
  if (tick.status["403"]) return { ok: false, detail: "Apple answered 403: the key, key id or team id is wrong" };
  if (tick.status.error) return { ok: false, detail: "the tick could not send (a missing function secret); read the function log" };
  if (tick.status["400"]) return { ok: true, detail: "Apple answered 400 (BadDeviceToken for a fake token): the request, the JWT and HTTP/2 all worked" };
  if (tick.status["200"]) return { ok: true, detail: "Apple answered 200 (unexpected for a fake token, but accepted)" };
  return { ok: false, detail: `unexpected status ${JSON.stringify(tick.status)}` };
}

export function cronQuery() {
  return "select count(*) as runs, count(*) filter (where status = 'succeeded') as succeeded from cron.job_run_details where jobid = (select jobid from cron.job where jobname = 'sweeper-wake-tick') and start_time > now() - interval '5 minutes'";
}

export function parseArgs(argv) {
  const opts = { dryRun: false, logs: true };
  for (const a of argv) {
    if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--no-logs") opts.logs = false;
    else throw new Error(`unknown argument ${a}`);
  }
  return opts;
}

// ---- the run --------------------------------------------------------

class StepFailure extends Error {}
const must = (cond, detail) => {
  if (!cond) throw new StepFailure(detail);
};

export async function run(argv, {
  fetchImpl = fetch,
  log = console.log,
  now = () => new Date(),
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  managementToken = resolveManagementToken().token,
} = {}) {
  const opts = parseArgs(argv);
  if (opts.dryRun) {
    log(`dry run against ${SUPABASE_URL}; nothing is sent`);
    STEPS.forEach((s, i) => log(`${i + 1}. ${s}`));
    return 0;
  }
  let failed = false;
  let user = null;
  const step = async (name, fn) => {
    try {
      const note = await fn();
      log(`ok: ${name}${note ? ` (${note})` : ""}`);
    } catch (err) {
      failed = true;
      log(`FAIL: ${name}: ${err instanceof Error ? err.message : err}`);
      throw err;
    }
  };
  const skip = (name, why) => log(`skipped: ${name} (${why})`);
  const call = async (path, body, headers = { "x-smooth-version": VERSION }) => {
    const res = await fetchImpl(`${SUPABASE_URL}/functions/v1/sweeper-wake${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${user.jwt}`, apikey: PUBLISHABLE_KEY, "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
    });
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { json = undefined; }
    return { status: res.status, json, text };
  };
  const management = async (url, init = {}) => {
    const res = await fetchImpl(url, { ...init, headers: { Authorization: `Bearer ${managementToken}`, "Content-Type": "application/json" } });
    const text = await res.text();
    must(res.ok, `Management API HTTP ${res.status} ${text.slice(0, 200)}`);
    return JSON.parse(text);
  };

  const token = fakeToken();
  const s = {};
  try {
    await step(STEPS[0], async () => {
      const res = await fetchImpl(`${SUPABASE_URL}/auth/v1/signup`, { method: "POST", headers: { apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" }, body: "{}" });
      must(res.ok, `signup HTTP ${res.status}`);
      const j = await res.json();
      must(j.access_token, "signup returned no access_token");
      user = { jwt: j.access_token };
    });

    await step(STEPS[1], async () => {
      s.moment = momentAhead(now());
      const r = await call("", { action: "put", token, environment: "development", moments: [s.moment.toISOString()], plan: "0123456789abcdef" });
      must(r.status === 200, `put HTTP ${r.status} ${r.text.slice(0, 200)}`);
      must(r.json.stored === 1, `stored ${r.json.stored}, expected 1`);
      must(r.json.nextMoment === s.moment.toISOString(), `nextMoment ${r.json.nextMoment}`);
      return "stored 1";
    });

    if (opts.logs && managementToken) {
      await step(STEPS[2], async () => {
        // The cron fires at the top of the minute; the sends run after the 202.
        const wait = Math.max(0, s.moment.getTime() + 20000 - now().getTime());
        await sleep(wait);
        let tick = null;
        for (let attempt = 0; attempt < 4 && !tick; attempt++) {
          tick = findClaimingTick(await management(logsURL(PROJECT_REF, now())), s.moment);
          if (!tick) await sleep(15000);
        }
        const verdict = judgeTick(tick);
        must(verdict.ok, verdict.detail);
        return `claimed ${tick.claimed}, sent ${tick.sent}, status ${JSON.stringify(tick.status)}, took ${tick.took} ms; ${verdict.detail}`;
      });
    } else {
      skip(STEPS[2], opts.logs ? "no Management API token" : "--no-logs");
    }

    await step(STEPS[3], async () => {
      const many = await call("", { action: "put", token, environment: "development", moments: manyMoments(now(), 25) });
      must(many.status === 400 && many.json?.message === "too_many_moments", `25 moments: HTTP ${many.status} ${many.text.slice(0, 120)}`);
      const far = await call("", { action: "put", token, environment: "development", moments: [new Date(now().getTime() + 3 * 24 * 3600 * 1000).toISOString()] });
      must(far.status === 400 && far.json?.message === "moment_beyond_horizon", `3 days out: HTTP ${far.status} ${far.text.slice(0, 120)}`);
      const forbidden = await call("", { action: "put", token, environment: "development", moments: [], assignment_id: "a1" });
      must(forbidden.status === 400 && forbidden.json?.message === "forbidden_field", `assignment_id: HTTP ${forbidden.status} ${forbidden.text.slice(0, 120)}`);
      const noVersion = await call("", { action: "put", token, environment: "development", moments: [] }, {});
      must(noVersion.status === 426, `no version header: HTTP ${noVersion.status}`);
      const tick = await call("/tick", {});
      must(tick.status === 403, `tick without its secret: HTTP ${tick.status}`);
      return "five refusals";
    });

    if (managementToken) {
      await step(STEPS[4], async () => {
        const r = await management(`${MANAGEMENT}/v1/projects/${PROJECT_REF}/database/query`, { method: "POST", body: JSON.stringify({ query: cronQuery() }) });
        const row = Array.isArray(r) ? r[0] : undefined;
        must(row && Number(row.runs) >= 2, `pg_cron ran ${row?.runs ?? "?"} times in five minutes`);
        must(Number(row.succeeded) === Number(row.runs), `pg_cron: ${row.succeeded} of ${row.runs} runs succeeded`);
        return `${row.succeeded} of ${row.runs} runs succeeded`;
      });
    } else {
      skip(STEPS[4], "no Management API token");
    }

    await step(STEPS[5], async () => {
      const first = await call("", { action: "delete" });
      must(first.status === 200 && first.json.deleted >= 1, `delete HTTP ${first.status} ${first.text.slice(0, 120)}`);
      const second = await call("", { action: "delete" });
      must(second.status === 200 && second.json.deleted === 0, `second delete found ${second.json?.deleted}`);
    });
  } catch {
    // already reported by step()
  } finally {
    if (user) {
      try {
        const res = await fetchImpl(`${SUPABASE_URL}/functions/v1/delete-account`, {
          method: "POST",
          headers: { Authorization: `Bearer ${user.jwt}`, apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
          body: "{}",
        });
        if (res.status === 200) log(`ok: ${STEPS[6]}`);
        else { failed = true; log(`FAIL: ${STEPS[6]}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}; delete the anonymous user by hand`); }
      } catch (err) {
        failed = true;
        log(`FAIL: ${STEPS[6]}: ${err instanceof Error ? err.message : err}; delete the anonymous user by hand`);
      }
    }
  }
  return failed ? 1 : 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  run(process.argv.slice(2)).then((code) => process.exit(code), (err) => { console.error(err.message); process.exit(1); });
}
