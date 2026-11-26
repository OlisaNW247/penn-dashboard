#!/usr/bin/env node
// Renders posters/src/*.html to print PNGs (posters/print, git-ignored) and
// the 700 px JPEG previews (posters/previews, committed) with the Chrome on
// this Mac. One design takes about half a minute in headless Chrome, so it
// prints a line per file.
//
//   node scripts/render-posters.mjs [key ...]
import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const src = join(root, "posters/src");
const print = join(root, "posters/print");
const previews = join(root, "posters/previews");
mkdirSync(print, { recursive: true });
mkdirSync(previews, { recursive: true });
const wanted = process.argv.slice(2);
const keys = readdirSync(src)
  .filter((f) => f.endsWith(".html"))
  .map((f) => f.slice(0, -5))
  .filter((k) => !wanted.length || wanted.includes(k));
for (const key of keys) {
  const png = join(print, `${key}.png`);
  execFileSync(chrome, [
    "--headless=new", `--user-data-dir=${join(print, ".chrome")}`, "--no-first-run", "--disable-gpu",
    "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=2376,3672",
    `--screenshot=${png}`, `file://${join(src, `${key}.html`)}`,
  ], { stdio: "ignore" });
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "82", "-Z", "1082", png, "--out", join(previews, `${key}.jpg`)], { stdio: "ignore" });
  console.log(`rendered ${key}`);
}
