#!/usr/bin/env node
// Downloads the 62 poster previews from the live tracker into
// public/posters/{school}/{poster}.jpg, where the Worker's POSTERS assets
// binding serves them. The images are not committed (public/posters is
// git-ignored): the live Worker embeds its own copies, and this exists so a
// build from this repository can serve them too. Read-only: it only ever
// requests /posters/..., never a /scan/ link, so no counter moves.
//
// Usage: npm run posters            (from the live site)
//        ORIGIN=http://localhost:8787 npm run posters
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SCHOOLS, designsFor } from "../worker/catalog.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const origin = process.env.ORIGIN || "https://smooth-poster-scans.jazzysmile20.chatgpt.site";
let ok = 0;
const failed = [];
for (const school of Object.keys(SCHOOLS)) {
  for (const poster of designsFor(school)) {
    const path = `/posters/${school}/${poster}.jpg`;
    const res = await fetch(origin + path);
    const type = res.headers.get("content-type") || "";
    if (!res.ok || !type.startsWith("image/")) {
      failed.push(`${path} (${res.status} ${type})`);
      continue;
    }
    const file = join(root, "public", path);
    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, Buffer.from(await res.arrayBuffer()));
    ok++;
  }
}
console.log(`${ok} posters saved to public/posters`);
if (failed.length) {
  console.error(`failed:\n  ${failed.join("\n  ")}`);
  process.exit(1);
}
