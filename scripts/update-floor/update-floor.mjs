#!/usr/bin/env node
// Raises the forced-update floor (`minimumVersion` in lhf-update.json on the
// `update-manifest` orphan branch) to whatever version the App Store is
// serving, so that only the latest release ever works. See CLAUDE.md, "Update
// gate". The file is dependency-free ESM on purpose: it runs on a bare
// GitHub-hosted runner with nothing but setup-node, and anything that needed
// `npm install` would be one more thing that can break the gate's upkeep.
//
// The split is deliberate: `decide` is pure (no clock, no network, no disk) so
// every rule below is testable with plain objects, and `main` is the only
// place that touches the outside world.
//
// Everything here leans toward doing nothing. A floor above what the App Store
// will actually serve is the one unrecoverable mistake the gate has (the wall's
// button leads to a version that still fails the check, and everyone is
// stuck), while a floor that lags a few hours behind costs nothing. So every
// doubt, whether an odd lookup response, an unreadable version or a missing
// date, resolves to "no change" with a reason, never to a guess.

import { readFileSync, writeFileSync, appendFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const APP_STORE_ID = 6783911002;
// PRODUCT_BUNDLE_IDENTIFIER of the iOS app target in project.yml (not the
// ".widget" extension, which is never what the App Store lookup describes).
export const BUNDLE_ID = "com.lhf.lowhangingfruit";
export const LOOKUP_URL = `https://itunes.apple.com/lookup?id=${APP_STORE_ID}&country=us`;
export const DEFAULT_DELAY_HOURS = 6;

const MAX_COMPONENT = 9223372036854775807n; // Swift's Int.max, so overflow fails to parse as it does in the app.

// Mirrors `AppVersion.init?(_ string:)` in LowHangingFruitKit: dot-separated,
// every component a non-empty run of ASCII digits, surrounding whitespace
// trimmed, and null (never 0.0.0) when anything is off. Returning a plausible
// default for an unreadable version is exactly how a typo would turn into a
// wall for the whole user base, so null propagates outward as "no change".
export function parseVersion(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "") return null;
  const parts = trimmed.split(".");
  const out = [];
  for (const part of parts) {
    if (!/^[0-9]+$/.test(part)) return null;
    const n = BigInt(part);
    if (n > MAX_COMPONENT) return null;
    out.push(n);
  }
  return out;
}

// Component-wise, missing trailing components are zero ("3.2" == "3.2.0").
export function compareVersions(a, b) {
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const l = a[i] ?? 0n;
    const r = b[i] ?? 0n;
    if (l !== r) return l < r ? -1 : 1;
  }
  return 0;
}

function none(reason, from = null, to = null) {
  return { action: "none", reason, from, to };
}

export function decide({ manifest, lookup, now, hold = false, delayHours = DEFAULT_DELAY_HOURS }) {
  const from = typeof manifest?.minimumVersion === "string" ? manifest.minimumVersion : null;

  // The hold switch comes first and short-circuits everything: it is the
  // owner's emergency stop, so it must work even if the lookup is garbage.
  if (hold === true) return none("hold is set", from);

  const results = Array.isArray(lookup?.results) ? lookup.results : null;
  if (!results || results.length !== 1) {
    return none(`lookup returned ${results ? results.length : "no"} results, expected exactly 1`, from);
  }
  const app = results[0];
  if (app?.trackId !== APP_STORE_ID) {
    return none(`lookup trackId ${JSON.stringify(app?.trackId)} is not ${APP_STORE_ID}`, from);
  }
  if (app?.bundleId !== BUNDLE_ID) {
    return none(`lookup bundleId ${JSON.stringify(app?.bundleId)} is not ${BUNDLE_ID}`, from);
  }

  const live = parseVersion(app.version);
  if (!live) return none(`live version ${JSON.stringify(app.version)} is not a dotted numeric version`, from);
  const to = app.version;

  const current = parseVersion(manifest?.minimumVersion);
  if (!current) {
    return none(`current minimumVersion ${JSON.stringify(manifest?.minimumVersion)} is not a dotted numeric version`, from, to);
  }

  // Compare before the delay so the common steady state reports "already
  // current" rather than a misleading delay message.
  if (compareVersions(live, current) <= 0) {
    return none(`live ${to} is not above the current floor ${from}`, from, to);
  }

  // The delay gives Apple's CDN time to serve the build everywhere (the
  // lookup can show a version before every storefront or device can download
  // it) and gives the owner a window to set the hold switch if the new build
  // crashes on launch, before it becomes the only build that works.
  const releasedAt = typeof app.currentVersionReleaseDate === "string" ? Date.parse(app.currentVersionReleaseDate) : NaN;
  if (Number.isNaN(releasedAt)) {
    return none(`live ${to} has a missing or unparseable currentVersionReleaseDate`, from, to);
  }
  const nowMs = now instanceof Date ? now.getTime() : Number(now);
  if (Number.isNaN(nowMs)) return none("now is not a valid time", from, to);
  const ageHours = (nowMs - releasedAt) / 3_600_000;
  if (ageHours < delayHours) {
    return none(`live ${to} is only ${ageHours.toFixed(1)}h old, waiting for ${delayHours}h`, from, to);
  }

  // Spread keeps every other key and the original key order; assigning to an
  // existing key does not move it.
  const next = { ...manifest, minimumVersion: to, latestVersion: to };
  return {
    action: "raise",
    reason: `live ${to} is above the floor ${from} and ${ageHours.toFixed(1)}h old`,
    from,
    to,
    manifestText: JSON.stringify(next, null, 2) + "\n",
  };
}

async function fetchLookup() {
  const url = `${LOOKUP_URL}&_=${Date.now()}`; // cache-buster: a stale CDN copy would delay or misreport a release
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`lookup HTTP ${res.status}`);
  return await res.json();
}

function parseArgs(argv) {
  const args = { manifest: null, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--manifest") args.manifest = argv[++i];
    else if (argv[i] === "--dry-run") args.dryRun = true;
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  if (!args.manifest) throw new Error("usage: update-floor.mjs --manifest <path> [--dry-run]");
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifest = JSON.parse(readFileSync(args.manifest, "utf8"));
  const lookup = await fetchLookup();
  const delayRaw = process.env.UPDATE_FLOOR_DELAY_HOURS;
  const delayParsed = delayRaw === undefined || delayRaw.trim() === "" ? NaN : Number(delayRaw);
  const delayHours = Number.isNaN(delayParsed) ? DEFAULT_DELAY_HOURS : delayParsed;
  const hold = process.env.UPDATE_FLOOR_HOLD === "true";

  const d = decide({ manifest, lookup, now: new Date(), hold, delayHours });
  const wrote = d.action === "raise" && !args.dryRun;
  if (wrote) writeFileSync(args.manifest, d.manifestText);

  const verb = d.action === "raise" ? (args.dryRun ? "would raise" : "raised") : "no change";
  console.log(`update-floor: ${verb}${d.action === "raise" ? ` ${d.from} -> ${d.to}` : ""} (${d.reason})`);

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT, `to=${d.to ?? ""}\naction=${d.action}\n`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((err) => {
    // Exit non-zero without touching the manifest: the Actions run goes red
    // and the owner gets an email, but a flaky network never edits the floor.
    console.error(`update-floor: ${err?.stack ?? err}${err?.cause ? `\n  cause: ${err.cause}` : ""}`);
    process.exit(1);
  });
}
