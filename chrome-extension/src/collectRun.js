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
  progress: "collectProgressV1",
};
// A pass that has not finished in this long is abandoned so the next alarm can start a fresh one.
export const PASS_DEADLINE_MS = 25 * 60 * 1000;
export const PROGRESS_MIN_GAP_MS = 2000;
// 30 minutes, not 5: the server's manifest calls a course fresh for an hour, so
// a faster collection would re-read Canvas for nothing. 30 catches new
// announcements and Ed posts twice as fast at a tolerable cost.
export const INTERVAL_MS = 30 * 60 * 1000;
export const RATE_LIMIT_BACKOFF_MS = 6 * 60 * 60 * 1000;
export const DISCOVER_BATCH = 3;

// Whether a freshly delivered Ed token should start a collection now. The
// worker's startup run happens before the student visits Ed (storage.session is
// cleared on every browser restart), so the visit must start the read; but only
// when the last run had no Ed, only once per token (an Ed page-load storm must
// not start a Canvas pass each time, and a token Ed rejects must not retry on
// every page load).
export function shouldCollectOnEdToken({ summary, token, lastTriggeredToken } = {}) {
  if (typeof token !== "string" || token === "") return false;
  if (token === lastTriggeredToken) return false;
  return !summary || summary.ed !== "in";
}

let inFlight = null;

// A forced run (an Ed token just arrived) that finds a pass in flight is
// queued and started once that pass ends, instead of being handed the running
// pass and lost: on 2026-11-11 the owner opened Ed while the first pass of a
// new laptop was running, the arrival got that pass back, and the pass ended
// with ed "none". One queued run at most; a second request while one waits
// is the same request.
let queuedForce = null;

export function collectRun(opts) {
  if (inFlight) {
    if (opts?.force && !queuedForce) queuedForce = opts;
    return inFlight;
  }
  const o = opts ?? {};
  const deadlineMs = o.deadlineMs ?? PASS_DEADLINE_MS;
  const mine = {};
  let timer;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ status: "deadline" }), deadlineMs);
  });
  const run = pass(o, mine).catch(() => ({ status: "error" }));
  const promise = Promise.race([run, deadline]).then(async (result) => {
    if (result.status === "deadline") {
      // Free the slot first, whatever the storage does.
      if (inFlight === promise) inFlight = null;
      try { await writeDeadlineSummary(o.storage, mine); } catch { /* never throws */ }
    }
    return result;
  }).finally(() => {
    clearTimeout(timer);
    if (inFlight === promise) inFlight = null;
    if (queuedForce && inFlight === null) {
      const next = queuedForce;
      queuedForce = null;
      collectRun(next).catch(() => {});
    }
  });
  inFlight = promise;
  return promise;
}

// The abandoned pass's own counts, if it got far enough to have any.
async function writeDeadlineSummary(storage, mine) {
  if (!storage || mine.startedAt === undefined) return;
  mine.abandoned = true;
  if ((await get(storage, KEYS.lastRun)) !== mine.startedAt) return; // a newer pass owns the summary
  await storage.set({ [KEYS.summary]: { at: mine.startedAt, canvas: "error", ed: "none", stopped: "deadline", requests: mine.requests ?? 0 } });
}

const get = async (storage, k) => (await storage.get(k))[k];

function nextLocalMidnight(nowMs) {
  const d = new Date(nowMs);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
}

async function pass({ force = false, fetch: fetchFn, callFunction, storage, sessionStorage, now = () => Date.now(), extractText, sleep, requestTimeoutMs, extractTimeoutMs }, mine = {}) {
  if (!(await get(storage, KEYS.pairingKey))) return { status: "unpaired" };
  const t = typeof now === "function" ? now() : now;
  const nowMs = t instanceof Date ? t.getTime() : t;
  const last = await get(storage, KEYS.lastRun);
  if (!force && typeof last === "number" && nowMs >= last && nowMs - last < INTERVAL_MS) return { status: "throttled" };
  const until = await get(storage, KEYS.backoffUntil);
  if (typeof until === "number" && nowMs < until) return { status: "backoff" };
  await storage.set({ [KEYS.lastRun]: nowMs });
  mine.startedAt = nowMs;

  // Progress: phase words and numbers only. At most one write per 2 s, and the
  // last report is always written (flushed before the upload and at the end).
  let lastWrite = -Infinity;
  let latest = null;
  const writeProgress = async () => {
    if (!latest || mine.abandoned) return;
    const body = latest;
    latest = null;
    lastWrite = Date.now();
    await storage.set({ [KEYS.progress]: body }).catch(() => {});
  };
  const report = (p) => {
    mine.requests = p.requests;
    latest = { at: Date.now(), phase: p.phase, course: p.course, requests: p.requests };
    if (Date.now() - lastWrite >= PROGRESS_MIN_GAP_MS) writeProgress();
  };

  const edToken = sessionStorage ? await readEdToken(sessionStorage).catch(() => undefined) : undefined;
  const seen = (await get(storage, KEYS.filesSeen)) ?? {};
  const holdings = (await get(storage, KEYS.holdings)) ?? {};

  const collected = await collectCourseMaterial({
    fetch: fetchFn, now: nowMs, edToken, sleep, // sleep: tests only
    onProgress: report,
    limits: { requestTimeoutMs, extractTimeoutMs },
    files: typeof extractText === "function" ? { extractText, seen } : undefined,
  });
  // Persist what the file pass learned even if the upload stops.
  if (collected.filesSeen) await storage.set({ [KEYS.filesSeen]: collected.filesSeen });

  report({ phase: "upload", course: null, requests: collected.summary?.requests ?? 0 });
  await writeProgress();
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
  // An abandoned pass (the deadline won) must not clobber a newer pass's summary.
  if (!mine.abandoned && (await get(storage, KEYS.lastRun)) === nowMs) {
    await storage.set({ [KEYS.summary]: summary });
    report({ phase: "done", course: null, requests: summary.requests });
    await writeProgress();
  }
  return { status: "ok", summary };
}
