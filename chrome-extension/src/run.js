// One refresh: read Canvas and Gradescope, merge, store. Local only.
import { readCanvas } from "./adapters/canvas.js";
import { readCanvasSubmissions } from "./adapters/canvasSubmissions.js";
import { readGradescope } from "./adapters/gradescope.js";
import { loadWorkList, saveWorkList, loadSnapshot, saveSnapshot } from "./adapters/store.js";
import { merge } from "./core/dedup.js";
import { toStored, fromStored } from "./core/workList.js";
import { canvasAssignmentID, assignmentID } from "./core/assignment.js";
import { recordCompletion } from "./core/syncSnapshot.js";

let inFlight = null;

// Never rejects; failures become status words in the stored record.
export function refresh(deps = {}) {
  inFlight ??= run(deps).catch(() => {}).finally(() => { inFlight = null; });
  return inFlight;
}

async function run({ fetchFn, now = new Date(), load = loadWorkList, save = saveWorkList, loadSnap = loadSnapshot, saveSnap = saveSnapshot, sleep, delayMs } = {}) {
  const prior = await load();
  // Sequential: at most one request in flight per host, no parallel storm.
  const canvas = await readCanvas({ fetchFn });
  const gradescope = await readGradescope({ fetchFn, now });
  // A source that could not be read keeps its last good list, so a signed-out
  // or offline run does not empty the popup.
  const canvasPool = canvas.status === "in" ? canvas.items.map(toStored) : (prior?.canvasPool ?? []);
  const gradescopePool = gradescope.status === "in" ? gradescope.items.map(toStored) : (prior?.gradescopePool ?? []);
  // Canvas's calendar feed has no submission state; its API does. Last good
  // map wins when the read is throttled, signed out or failed.
  let submissions = prior?.submissions ?? { at: null, submitted: {} };
  let submissionsStatus = "unknown";
  if (canvas.status === "in") {
    const read = await readCanvasSubmissions({ fetchFn, now, prior: submissions, sleep, delayMs });
    submissions = { at: read.at, submitted: read.submitted };
    submissionsStatus = read.status;
  }
  const turnedIn = submissions.submitted ?? {};
  const canvasItems = canvasPool.map(fromStored).map((a) => {
    const id = canvasAssignmentID(a);
    return id !== null && turnedIn[id] ? { ...a, submitted: true } : a;
  });
  const merged = merge(canvasItems, gradescopePool.map(fromStored));
  const items = merged.map(toStored);
  if (submissionsStatus === "in") await feedPhone(merged, turnedIn, now, loadSnap, saveSnap);
  await save({
    items,
    canvasPool,
    gradescopePool,
    canvas: canvas.status,
    gradescope: gradescope.status,
    canvasSubmissions: submissionsStatus,
    submissions,
    refreshedAt: now.toISOString(),
  });
}

// Canvas says it is turned in: tell the phone through the encrypted sync, even
// if its own Canvas session is dead. Only ever records done:true, and never
// over an existing record, so a student's un-tick (or an earlier tick) stands.
async function feedPhone(merged, turnedIn, now, loadSnap, saveSnap) {
  let snapshot = await loadSnap(now);
  let changed = false;
  for (const a of merged) {
    const cid = canvasAssignmentID(a);
    const hit = cid !== null ? turnedIn[cid] : undefined;
    if (!hit) continue;
    const ids = [assignmentID(a), ...(a.linkedID ? [a.linkedID] : [])];
    if (ids.some((id) => snapshot.completions?.[id])) continue;
    const parsed = hit.submittedAt ? new Date(hit.submittedAt) : null;
    const at = parsed && !Number.isNaN(parsed.getTime()) ? parsed : now;
    snapshot = recordCompletion(snapshot, assignmentID(a), true, at);
    changed = true;
  }
  if (changed) await saveSnap(snapshot);
}
