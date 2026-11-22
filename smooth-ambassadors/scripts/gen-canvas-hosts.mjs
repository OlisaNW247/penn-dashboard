// Writes worker/canvas-hosts.json: every Canvas host the iOS app's own school
// catalog knows (its `host:` and `hostAliases:`), lowercased, de-duplicated and
// sorted. POST /api/install counts only these (and the SCHOOLS canvasHosts), so
// one caller cannot fill the table with made-up hosts.
//   node scripts/gen-canvas-hosts.mjs          rewrite the file
// test/routes.test.mjs imports extractCanvasHosts and fails if the committed
// file has drifted from the Swift source.
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
export const SWIFT_SOURCES = join(root, "../LowHangingFruitKit/Sources/LowHangingFruitKit");
export const OUT = join(root, "worker/canvas-hosts.json");

export function findCatalogFiles(dir = SWIFT_SOURCES) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...findCatalogFiles(p));
    else if (name === "CanvasSchoolCatalogData.swift") out.push(p);
  }
  return out;
}

export function extractCanvasHosts(swiftTexts) {
  const hosts = new Set();
  for (const text of swiftTexts) {
    for (const m of text.matchAll(/\b(?:host|hostAliases):\s*"([^"]*)"/g)) {
      for (const h of m[1].split(";")) {
        const v = h.trim().toLowerCase();
        if (v) hosts.add(v);
      }
    }
  }
  return [...hosts].sort();
}

if (process.argv[1] && process.argv[1] === fileURLToPath(import.meta.url)) {
  const files = findCatalogFiles();
  if (!files.length) {
    console.error("gen-canvas-hosts: CanvasSchoolCatalogData.swift not found");
    process.exit(1);
  }
  const hosts = extractCanvasHosts(files.map((f) => readFileSync(f, "utf8")));
  writeFileSync(OUT, JSON.stringify(hosts, null, 2) + "\n");
  console.log(`gen-canvas-hosts: ${hosts.length} hosts -> worker/canvas-hosts.json`);
}
