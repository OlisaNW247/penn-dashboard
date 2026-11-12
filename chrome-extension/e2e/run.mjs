// End-to-end harness: real headless Chromium, the real extension, a local fake
// of Ed / Canvas / Gradescope / the backend. See e2e/README.md.
// Usage: node e2e/run.mjs [path-to-extension-dir]
import { createRequire } from "node:module";
import { randomBytes, webcrypto } from "node:crypto";
import { rmSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startWorld } from "./fakeWorld.mjs";

let chromium;
let requireVia = "createRequire";
try { ({ chromium } = createRequire(import.meta.url)("playwright")); }
catch { requireVia = "import()"; ({ chromium } = await import("playwright")); }

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EXT = path.resolve(process.argv[2] || path.join(HERE, ".."));
const SCRATCH = "/tmp/claude-0/-home-user-penn-dashboard/dcac4934-2bbf-5755-bc54-94026e956f75/scratchpad/e2e";
const PROFILE = path.join(SCRATCH, "profile");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const TOKEN = randomBytes(20).toString("hex"); // 40 chars

let failures = 0;
const check = (ok, name, evidence = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${evidence ? `\n        ${String(evidence).split("\n").join("\n        ")}` : ""}`);
  return ok;
};
const note = (s) => console.log(`NOTE  ${s}`);
const section = (s) => console.log(`\n== ${s}`);

async function until(what, fn, ms, world) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) {
      console.log(`TIMEOUT waiting for: ${what}. Request log so far:`);
      for (const r of world.log) console.log(`   +${r.t}ms ${r.method} ${r.host}${r.path}${Object.keys(r.query).length ? "?" + new URLSearchParams(r.query) : ""}`);
      return null;
    }
    await sleep(250);
  }
}

mkdirSync(SCRATCH, { recursive: true });
rmSync(PROFILE, { recursive: true, force: true });
const world = await startWorld({ token: TOKEN, certDir: path.join(SCRATCH, "cert") });
console.log(`playwright loaded via ${requireVia}; fake world on 127.0.0.1:${world.port}; extension ${EXT}`);

async function launch() {
  const args = [
    `--host-resolver-rules=${world.hostRules}`, "--ignore-certificate-errors", "--no-proxy-server",
    `--disable-extensions-except=${EXT}`, `--load-extension=${EXT}`,
  ];
  // Extensions need the "new" headless mode, i.e. the full chromium channel.
  const ctx = await chromium.launchPersistentContext(PROFILE, { headless: true, channel: "chromium", args });
  let sw = ctx.serviceWorkers().find((w) => w.url().startsWith("chrome-extension://"));
  if (!sw) sw = await ctx.waitForEvent("serviceworker", { timeout: 20000 });
  const id = new URL(sw.url()).host;
  const popup = await ctx.newPage();
  await popup.goto(`chrome-extension://${id}/src/popup/popup.html`);
  return { ctx, id, popup };
}

const local = (popup) => popup.evaluate(() => chrome.storage.local.get(null));
const summaryOf = async (popup) => (await popup.evaluate(() => chrome.storage.local.get("collectSummaryV1"))).collectSummaryV1;
const lever = (popup) => popup.evaluate(async () => {
  await chrome.storage.local.set({ collectRunAtV1: 0 });
  await chrome.alarms.create("sync", { when: Date.now() + 200 });
});

let run1;
try {
  section("1. launch + seed");
  run1 = await launch();
  console.log(`extension id ${run1.id}`);
  await run1.popup.evaluate(() => chrome.storage.local.set({ pairingKeyV1: "ab".repeat(32), collectRunAtV1: 0 }));
  // The startup run (unpaired at that moment) may already have happened; reset the clock of what we watch.
  world.uploads.length = 0;

  section("2. open the fake Ed page");
  const ed = await run1.ctx.newPage();
  await ed.goto("https://edstem.org/us/courses/101/discussion");
  await sleep(1500);
  const stored = await run1.popup.evaluate(async () => (await chrome.storage.session.get("edTokenV1")).edTokenV1);
  check(stored === TOKEN, "content script lifted the token into storage.session (edTokenV1)", stored ? "token matches" : `got ${JSON.stringify(stored)}`);

  section("3. trigger a collection run");
  let natural = await until("an upload via the natural path (token arrival)", () => world.uploads.length > 0, 20000, { log: [] });
  console.log(natural ? "natural path (token arrival starts a run): WORKED" : "natural path (token arrival starts a run): did NOT produce an upload in 20s");
  const naturalUploads = world.uploads.length;
  await sleep(natural ? 2000 : 0);
  const before = world.uploads.length;
  const atBefore = (await summaryOf(run1.popup))?.at ?? 0;
  await lever(run1.popup);
  const lev = await until("an upload via the alarm lever", async () => (await summaryOf(run1.popup))?.at > atBefore, 60000, world);
  await sleep(500);
  console.log(lev ? `alarm lever: WORKED (${world.uploads.length - before} new upload batch(es))` : "alarm lever: did NOT complete a run in 60s");
  if (!natural && !lev) throw new Error("no run completed by either path");

  section("4. assertions");
  const edReqs = world.log.filter((r) => r.host === "us.edstem.org");
  const offsets = (course) => [...new Set(edReqs.filter((r) => r.path === `/api/courses/${course}/threads`).map((r) => Number(r.query.offset)))].sort((a, b) => a - b);
  check(edReqs.some((r) => r.path === "/api/user"), "Ed API got /api/user");
  const o101 = offsets(101), o202 = offsets(202);
  if (o101.length === 1) check(false, "course 101 threads paged at offsets 0,100,200", `no paging: only offset ${o101[0]} requested`);
  else check(o101.join() === "0,100,200", "course 101 threads paged at offsets 0,100,200", `offsets seen: ${o101.join(",")}`);
  check(o202.join() === "0", "course 202 threads at offset 0 only (short page)", `offsets seen: ${o202.join(",")}`);

  check(ed_ok(edReqs), "every Ed API request carried x-token === TOKEN and no cookie header", `${edReqs.length} Ed API requests`);
  function ed_ok(rs) { return rs.length > 0 && rs.every((r) => r.headers["x-token"] === TOKEN && r.headers.cookie === undefined); }
  const canvasReqs = world.log.filter((r) => r.host === "canvas.upenn.edu");
  check(canvasReqs.length > 0 && canvasReqs.every((r) => r.headers["x-token"] === undefined), "no Canvas request carried x-token", `${canvasReqs.length} Canvas requests`);

  const supa = world.log.filter((r) => r.host.endsWith("supabase.co"));
  const leaked = supa.filter((r) => JSON.stringify([r.headers, r.body, r.path, r.query]).includes(TOKEN));
  check(supa.length > 0 && leaked.length === 0, "TOKEN appears in no request to the supabase host", `${supa.length} supabase requests, ${leaked.length} leaking`);
  const all = await local(run1.popup);
  check(!JSON.stringify(all).includes(TOKEN), "TOKEN appears nowhere in chrome.storage.local", `keys: ${Object.keys(all).join(", ")}`);

  // documents: union over every upload batch; last version of each id wins.
  const docs = new Map();
  for (const u of world.uploads) for (const d of u.documents ?? []) docs.set(d.id, d);
  const edDocs = [...docs.values()].filter((d) => d.kind === "ed");
  const ids = (course) => new Set(edDocs.filter((d) => d.id.startsWith(`ed:${course}:`)).map((d) => d.id));
  const wantKeep = new Set([...world.c101.keep].map((i) => `ed:111:${i}`));
  const got111 = ids(111);
  const missing = [...wantKeep].filter((x) => !got111.has(x));
  const extra = [...got111].filter((x) => !wantKeep.has(x));
  check(missing.length === 0 && extra.length === 0, "course 101 documents are exactly the KEEP threads (ed:111:<id>)", `want ${wantKeep.size}, got ${got111.size}; missing: [${missing}]; extra: [${extra}]`);
  const droppedPresent = [...world.c101.drop].filter((i) => got111.has(`ed:111:${i}`));
  check(droppedPresent.length === 0, "DROP threads (private, anonymous, staff question) absent", `present: [${droppedPresent}]`);
  const want222 = new Set([...world.c202.keep].map((i) => `ed:222:${i}`));
  const got222 = ids(222);
  check([...want222].every((x) => got222.has(x)) && got222.size === want222.size, "course 202 documents are exactly its announcement (ed:222:<id>)", `want [${[...want222]}] got [${[...got222]}]`);
  const badShape = edDocs.filter((d) => {
    const m = d.id.match(/^ed:111:(\d+)$/);
    return m && d.url !== `https://edstem.org/us/courses/101/discussion/${m[1]}`;
  });
  check(edDocs.length > 0 && badShape.length === 0, 'ed documents have kind "ed" and url https://edstem.org/us/courses/101/discussion/<id>', `bad urls: [${badShape.map((d) => d.id + " " + d.url)}]`);

  const east = (d) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  const s0 = world.c101.byIndex[0];
  const d0 = docs.get(`ed:111:${s0.id}`);
  const expect0 = `[ed · announcement] Exams / Midterm · posted ${east(s0.created)}\nThe midterm is in Towne 100 & starts at 10.`;
  check(d0?.text === expect0, "index-0 announcement text is exactly the expected header + body", `expected ${JSON.stringify(expect0)}\n got     ${JSON.stringify(d0?.text)}`);
  const d15 = docs.get(`ed:111:${world.c101.byIndex[15].id}`);
  check(typeof d15?.text === "string" && d15.text.endsWith("\nonly & html"), 'index-15 (content-only) text ends with "\\nonly & html"', JSON.stringify(d15?.text));

  const last = [...world.uploads].reverse().find((u) => (u.fullySyncedCourses ?? []).length > 0);
  const fs111 = last?.fullySyncedCourses.find((c) => String(c.courseID) === "111");
  const fsMissing = fs111 ? [...wantKeep].filter((x) => !fs111.documentIDs.includes(x)) : [...wantKeep];
  check(!!fs111 && fsMissing.length === 0, "last upload's fullySyncedCourses for 111 lists the ed ids", fs111 ? `${fs111.documentIDs.length} ids, ed ids missing: [${fsMissing}]` : "no fullySyncedCourses for 111");

  const sum = await summaryOf(run1.popup);
  console.log("collectSummaryV1:", JSON.stringify(sum));
  check(sum?.ed === "in", 'collectSummaryV1.ed === "in"', `ed=${sum?.ed}`);
  console.log(`(upload batches: ${world.uploads.length}, of which after natural path: ${naturalUploads})`);

  section("4b. Canvas submission feed -> encrypted snapshot");
  // The seeded "ab"x32 text is 48 bytes as base64url, not a 32-byte key, so the real pass refuses it;
  // use a proper random 32-byte key (the harness's own, never printed).
  const keyBytes = randomBytes(32);
  const keyText = keyBytes.toString("base64url");
  await run1.popup.evaluate((k) => chrome.storage.local.set({ pairingKeyV1: k }), keyText);
  const before4b = world.deviceSyncUploads.length;
  // Clear the 2-minute pass throttle and the submissions throttle so both run now.
  await run1.popup.evaluate(async () => {
    await chrome.storage.local.remove("deviceSyncAtV1");
    const w = (await chrome.storage.local.get("workListV1")).workListV1;
    if (w) await chrome.storage.local.set({ workListV1: { ...w, submissions: { ...(w.submissions ?? {}), at: null } } });
  });
  await run1.popup.evaluate(() => chrome.runtime.sendMessage({ type: "refresh" }));
  await run1.popup.evaluate(() => chrome.runtime.sendMessage({ type: "sync" }));
  const got = await until("a device-sync upload", () => world.deviceSyncUploads.length > before4b, 30000, world);
  check(!!got, "a sealed snapshot was PUT to device-sync", `${world.deviceSyncUploads.length - before4b} new put(s)`);
  if (got) {
    // Independent copy of the scheme: AES-256-GCM, base64 (standard) of nonce(12) || ciphertext || tag(16), no AAD.
    const unseal = async (b64) => {
      const raw = Buffer.from(b64, "base64");
      const key = await webcrypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["decrypt"]);
      return JSON.parse(Buffer.from(await webcrypto.subtle.decrypt({ name: "AES-GCM", iv: raw.subarray(0, 12), tagLength: 128 }, key, raw.subarray(12))).toString("utf8"));
    };
    let snap = null;
    for (const put of [...world.deviceSyncUploads].reverse()) {
      try { const s = await unseal(put.ciphertext); if (s?.completions && s.completions["canvas:assignment-5001"]) { snap = s; break; } snap ??= s; } catch { /* sealed under another key */ }
    }
    check(!!snap, "uploaded ciphertext decrypts with the pairing key (AES-256-GCM, nonce||ct||tag)");
    const comp = snap?.completions ?? {};
    const c1 = comp["canvas:assignment-5001"];
    check(!!c1 && c1.done === true && Date.parse(c1.at) === Date.parse(world.submittedAt), "snapshot has canvas:assignment-5001 done:true at the submitted_at instant", `entry: ${JSON.stringify(c1)} want at ${world.submittedAt}`);
    check(!("canvas:assignment-5002" in comp), "snapshot has no entry for the unsubmitted canvas:assignment-5002", `completion keys: ${Object.keys(comp).join(", ")}`);
  }
  const wl = (await local(run1.popup)).workListV1;
  check(wl?.canvasSubmissions === "in", 'workListV1.canvasSubmissions === "in"', `got ${wl?.canvasSubmissions}`);
  const subKeys = Object.keys(wl?.submissions?.submitted ?? {});
  check(subKeys.length === 1 && subKeys[0] === "5001", 'workListV1.submissions.submitted has exactly "5001"', `keys: ${subKeys}`);
  // Scoped to device-sync and pair: the course-material `sync` upload legitimately carries assignment
  // documents (pooled, by design); the student's own snapshot is what must leave sealed.
  const plain = world.log.filter((r) => r.host.endsWith("supabase.co") && /^\/functions\/v1\/(device-sync|pair)$/.test(r.path) && /Homework 6|assignment-5001/.test(JSON.stringify([r.headers, r.body, r.path, r.query])));
  check(plain.length === 0, 'no device-sync/pair request carries "Homework 6" or "assignment-5001" in plaintext', `${plain.length} leaking`);

  section("5. restart (storage.session gone, storage.local kept)");
  await run1.ctx.close(); run1 = null;
  const edReqsBefore = world.log.length;
  const run2 = await launch();
  run1 = run2;
  const keptKey = (await local(run2.popup)).pairingKeyV1;
  check(!!keptKey, "storage.local survived the restart (pairingKeyV1 present)");
  const gone = await run2.popup.evaluate(async () => (await chrome.storage.session.get("edTokenV1")).edTokenV1);
  check(gone === undefined, "storage.session token is gone after restart");
  const at2 = (await summaryOf(run2.popup))?.at ?? 0;
  await lever(run2.popup);
  await until("restart run summary", async () => (await summaryOf(run2.popup))?.at > at2, 60000, world);
  const s2 = await summaryOf(run2.popup);
  console.log("collectSummaryV1:", JSON.stringify(s2));
  check(s2?.ed === "none", 'after restart, a run records ed === "none"', `ed=${s2?.ed}`);
  const newEd = world.log.slice(edReqsBefore).filter((r) => r.host === "us.edstem.org");
  check(newEd.length === 0, "no Ed API request without a token", `${newEd.length} requests`);

  const ed2 = await run2.ctx.newPage();
  await ed2.goto("https://edstem.org/us/courses/101/discussion");
  const flipped = await until("token arrival to start a run", async () => (await summaryOf(run2.popup))?.ed === "in", 20000, { log: [] });
  if (flipped) check(true, "token arrival starts a run", "summary.ed flipped to in");
  else note("token arrival does not start a run yet");
} catch (e) {
  failures += 1;
  console.log(`FAIL  harness error: ${e?.stack || e}`);
  console.log("Request log so far:");
  for (const r of world.log) console.log(`   +${r.t}ms ${r.method} ${r.host}${r.path}${Object.keys(r.query).length ? "?" + new URLSearchParams(r.query) : ""}`);
} finally {
  try { await run1?.ctx.close(); } catch {}
  await world.close();
}
console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
