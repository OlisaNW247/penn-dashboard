// One course-material collection pass for the service worker. Everything is
// injected so it runs in node. Never throws; the summary is counts and words only.
import { collectCourseMaterial, syncCourseMaterial, readEdToken } from "./adapters/collector.js";

export const KEYS = {
  pairingKey: "pairingKeyV1",
  lastRun: "collectRunAtV1",
  backoffUntil: "collectBackoffUntilV1",
  holdings: "courseHoldingsV1",
  filesSeen: "fileSeenV1",
  summary: "collectSummaryV1",
};
export const INTERVAL_MS = 60 * 60 * 1000;
export const RATE_LIMIT_BACKOFF_MS = 6 * 60 * 60 * 1000;
export const DISCOVER_BATCH = 3;

let inFlight = null;

export function collectRun(opts) {
  if (inFlight) return inFlight;
  inFlight = pass(opts ?? {}).catch(() => ({ status: "error" })).finally(() => { inFlight = null; });
  return inFlight;
}

const get = async (storage, k) => (await storage.get(k))[k];

function nextLocalMidnight(nowMs) {
  const d = new Date(nowMs);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
}

async function pass({ fetch: fetchFn, callFunction, storage, sessionStorage, now = () => Date.now(), extractText, sleep }) {
  if (!(await get(storage, KEYS.pairingKey))) return { status: "unpaired" };
  const t = typeof now === "function" ? now() : now;
  const nowMs = t instanceof Date ? t.getTime() : t;
  const last = await get(storage, KEYS.lastRun);
  if (typeof last === "number" && nowMs >= last && nowMs - last < INTERVAL_MS) return { status: "throttled" };
  const until = await get(storage, KEYS.backoffUntil);
  if (typeof until === "number" && nowMs < until) return { status: "backoff" };
  await storage.set({ [KEYS.lastRun]: nowMs });

  const edToken = sessionStorage ? await readEdToken(sessionStorage).catch(() => undefined) : undefined;
  const seen = (await get(storage, KEYS.filesSeen)) ?? {};
  const holdings = (await get(storage, KEYS.holdings)) ?? {};

  const collected = await collectCourseMaterial({
    fetch: fetchFn, now: nowMs, edToken, sleep, // sleep: tests only
    files: typeof extractText === "function" ? { extractText, seen } : undefined,
  });
  // Persist what the file pass learned even if the upload stops.
  if (collected.filesSeen) await storage.set({ [KEYS.filesSeen]: collected.filesSeen });

  const synced = await syncCourseMaterial({ callFunction, collected, holdings });
  await storage.set({ [KEYS.holdings]: synced.holdings });

  const rateLimited = collected.summary?.rateLimited === true || synced.summary.stopped === "rateLimited";
  const quota = synced.summary.stopped === "quota";
  if (rateLimited) await storage.set({ [KEYS.backoffUntil]: nowMs + RATE_LIMIT_BACKOFF_MS });
  else if (quota) await storage.set({ [KEYS.backoffUntil]: nextLocalMidnight(nowMs) });

  // Fire and forget: the phone does the same. Errors are swallowed.
  const quiet = (p) => { Promise.resolve(p).catch(() => {}); };
  const fire = (name, body) => { try { quiet(callFunction(name, body)); } catch { /* sync throw */ } };
  const stale = synced.profileStale ?? [];
  const pending = synced.websitesPending ?? [];
  if (stale.length > 0) fire("extract-profile", { courseIDs: stale });
  for (let i = 0; i < pending.length; i += DISCOVER_BATCH) {
    fire("discover-websites", { courseIDs: pending.slice(i, i + DISCOVER_BATCH) });
  }

  const s = collected.summary ?? {};
  const summary = {
    at: nowMs,
    canvas: collected.canvas,
    ed: collected.ed,
    courses: s.courses ?? 0,
    documents: s.documents ?? 0,
    files: s.files ?? null,
    requests: s.requests ?? 0,
    rateLimited,
    fullySynced: synced.summary.fullySynced,
    downloaded: synced.summary.downloaded,
    uploaded: synced.summary.uploaded,
    batches: synced.summary.batches,
    stopped: synced.summary.stopped,
    errors: synced.summary.errors,
    profileStale: stale.length,
    websitesPending: pending.length,
  };
  await storage.set({ [KEYS.summary]: summary });
  return { status: "ok", summary };
}
