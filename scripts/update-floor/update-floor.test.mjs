// Each rule in `decide` has a test, because every one of them is a guard
// against the gate's one unrecoverable mistake: a floor the App Store can't
// actually serve yet.
import test from "node:test";
import assert from "node:assert/strict";
import { decide, parseVersion, compareVersions, BUNDLE_ID } from "./update-floor.mjs";

const NOW = new Date("2026-10-27T12:00:00Z");
const manifest = () => ({
  minimumVersion: "3.2.0",
  latestVersion: "3.2.0",
  message: "A new version of Smooth is required to keep going. It only takes a moment.",
  appStoreURL: "https://apps.apple.com/app/id6783911002",
});
const lookup = (over = {}, count = 1) => ({
  resultCount: count,
  results: [{
    trackId: 6783911002,
    bundleId: BUNDLE_ID,
    version: "3.3.0",
    currentVersionReleaseDate: "2026-10-26T12:00:00Z",
    ...over,
  }],
});
const run = (o = {}) => decide({ manifest: manifest(), lookup: lookup(), now: NOW, hold: false, delayHours: 6, ...o });

test("raises when live is newer and old enough", () => {
  const d = run();
  assert.equal(d.action, "raise");
  assert.equal(d.from, "3.2.0");
  assert.equal(d.to, "3.3.0");
  assert.equal(
    d.manifestText,
    `{\n  "minimumVersion": "3.3.0",\n  "latestVersion": "3.3.0",\n  "message": "A new version of Smooth is required to keep going. It only takes a moment.",\n  "appStoreURL": "https://apps.apple.com/app/id6783911002"\n}\n`,
  );
});

test("raise keeps extra keys and key order, writes version as Apple returned it", () => {
  const m = { latestVersion: "3.2.0", extra: 1, minimumVersion: "3.2.0", message: "m", appStoreURL: "u" };
  const d = run({ manifest: m, lookup: lookup({ version: "3.10" }) });
  assert.equal(d.action, "raise");
  const out = JSON.parse(d.manifestText);
  assert.deepEqual(Object.keys(out), ["latestVersion", "extra", "minimumVersion", "message", "appStoreURL"]);
  assert.equal(out.minimumVersion, "3.10");
  assert.equal(out.latestVersion, "3.10");
  assert.equal(out.extra, 1);
  assert.equal(d.manifestText.endsWith("}\n"), true);
});

test("hold blocks a raise", () => {
  const d = run({ hold: true });
  assert.equal(d.action, "none");
  assert.match(d.reason, /hold/);
  assert.equal(d.manifestText, undefined);
});

test("delay: too-new release waits, exactly delayHours passes", () => {
  assert.equal(run({ lookup: lookup({ currentVersionReleaseDate: "2026-10-27T06:00:01Z" }) }).action, "none");
  assert.equal(run({ lookup: lookup({ currentVersionReleaseDate: "2026-10-27T06:00:00Z" }) }).action, "raise");
});

test("delay defaults to 6 hours", () => {
  const d = decide({ manifest: manifest(), lookup: lookup({ currentVersionReleaseDate: "2026-10-27T09:00:00Z" }), now: NOW });
  assert.equal(d.action, "none");
});

test("missing or unparseable release date -> none", () => {
  assert.equal(run({ lookup: lookup({ currentVersionReleaseDate: undefined }) }).action, "none");
  assert.equal(run({ lookup: lookup({ currentVersionReleaseDate: "yesterday-ish" }) }).action, "none");
});

test("never lowers", () => {
  const d = run({ lookup: lookup({ version: "3.1.0" }) });
  assert.equal(d.action, "none");
  assert.equal(d.manifestText, undefined);
});

test("never rewrites an equal floor, including 3.2 == 3.2.0", () => {
  assert.equal(run({ lookup: lookup({ version: "3.2.0" }) }).action, "none");
  assert.equal(run({ lookup: lookup({ version: "3.2" }) }).action, "none");
});

test("lookup shape: zero, two results, wrong trackId, wrong bundleId -> none", () => {
  assert.equal(run({ lookup: { resultCount: 0, results: [] } }).action, "none");
  const two = lookup();
  two.results.push({ ...two.results[0] });
  assert.equal(run({ lookup: two }).action, "none");
  assert.equal(run({ lookup: lookup({ trackId: 1 }) }).action, "none");
  assert.equal(run({ lookup: lookup({ bundleId: "com.lhf.lowhangingfruit.widget" }) }).action, "none");
  assert.equal(run({ lookup: {} }).action, "none");
  assert.equal(run({ lookup: null }).action, "none");
});

test("unparseable live version -> none", () => {
  for (const v of ["", "abc", "3..0", "3.x", "-3.0", "3.0.", undefined, 3]) {
    assert.equal(run({ lookup: lookup({ version: v }) }).action, "none", String(v));
  }
});

test("unparseable current floor -> none", () => {
  const m = manifest();
  m.minimumVersion = "3..0";
  assert.equal(run({ manifest: m }).action, "none");
  delete m.minimumVersion;
  assert.equal(run({ manifest: m }).action, "none");
});

test("version parsing and comparison match AppVersion", () => {
  assert.deepEqual(parseVersion("3.2"), [3n, 2n]);
  assert.equal(parseVersion("+3.2"), null);
  assert.equal(parseVersion("٣.٢"), null); // non-ASCII digits
  assert.equal(compareVersions(parseVersion("3.2"), parseVersion("3.2.0")), 0);
  assert.equal(compareVersions(parseVersion("3.10"), parseVersion("3.9")), 1);
  assert.equal(compareVersions(parseVersion("3.2.0.1"), parseVersion("3.2")), 1);
});
