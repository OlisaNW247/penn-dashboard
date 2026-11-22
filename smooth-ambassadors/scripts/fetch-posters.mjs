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
import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
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
    const file = join(root, "public", path);
    await mkdir(dirname(file), { recursive: true });
    const res = await fetch(origin + path);
    const type = res.headers.get("content-type") || "";
    if (!res.ok || !type.startsWith("image/")) {
      // A design the live site does not carry yet (added to the catalog, not
      // deployed): the repo's own preview serves it locally.
      const own = join(root, "posters/previews", `${poster}.jpg`);
      if (existsSync(own)) {
        await copyFile(own, file);
        ok++;
        continue;
      }
      failed.push(`${path} (${res.status} ${type})`);
      continue;
    }
    await writeFile(file, Buffer.from(await res.arrayBuffer()));
    ok++;
  }
}
console.log(`${ok} posters saved to public/posters`);
if (failed.length) {
  console.error(`failed:\n  ${failed.join("\n  ")}`);
  process.exit(1);
}
