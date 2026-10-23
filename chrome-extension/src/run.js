// One refresh: read Canvas and Gradescope, merge, store. Local only.
import { readCanvas } from "./adapters/canvas.js";
import { readGradescope } from "./adapters/gradescope.js";
import { loadWorkList, saveWorkList } from "./adapters/store.js";
import { merge } from "./core/dedup.js";
import { toStored, fromStored } from "./core/workList.js";

let inFlight = null;

// Never rejects; failures become status words in the stored record.
export function refresh() {
  inFlight ??= run().catch(() => {}).finally(() => { inFlight = null; });
  return inFlight;
}

async function run() {
  const now = new Date();
  const prior = await loadWorkList();
  // Sequential: at most one request in flight per host, no parallel storm.
  const canvas = await readCanvas();
  const gradescope = await readGradescope({ now });
  // A source that could not be read keeps its last good list, so a signed-out
  // or offline run does not empty the popup.
  const canvasPool = canvas.status === "in" ? canvas.items.map(toStored) : (prior?.canvasPool ?? []);
  const gradescopePool = gradescope.status === "in" ? gradescope.items.map(toStored) : (prior?.gradescopePool ?? []);
  const items = merge(canvasPool.map(fromStored), gradescopePool.map(fromStored)).map(toStored);
  await saveWorkList({
    items,
    canvasPool,
    gradescopePool,
    canvas: canvas.status,
    gradescope: gradescope.status,
    refreshedAt: now.toISOString(),
  });
}
