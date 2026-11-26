// Fetches Penn's own requirement template for every undergraduate program
// from Path@Penn's PUBLIC program endpoints (no sign-in; verified from a
// runner on 2026-11-26, docs/research/degree-data/SOURCES.md S01), so the
// degree planner's sharing rules, caps and requirement lists can be read
// from Penn's data instead of being written by hand in policy.ts.
//
//   node scripts/penn-catalog/fetch-programs.mjs <outdir> [srcdb]
//
// Writes <outdir>/programs/<CODE>.xml (the template, Penn's audit of its own
// dummy student "*Test"), <outdir>/programs/<CODE>.json (the codes around
// it) and <outdir>/index.json. Nothing here is about a real student.
// Exits non-zero when fewer than 100 templates came back, so a failed fetch
// is never published as "Penn removed its programs".
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = process.argv[2] ?? "raw";
const srcdb = process.argv[3] ?? "202630";
const API = "https://courses.upenn.edu/api/";
const HEADERS = {
  "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  "Accept": "application/json, text/javascript, */*; q=0.01",
  "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
  "X-Requested-With": "XMLHttpRequest",
  "Origin": "https://courses.upenn.edu",
  "Referer": "https://courses.upenn.edu/",
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function call(route, body, tries = 3) {
  for (let attempt = 1; attempt <= tries; attempt++) {
    try {
      const res = await fetch(`${API}?page=fose&route=${route}`, {
        method: "POST", headers: HEADERS, body: encodeURIComponent(JSON.stringify(body)),
        signal: AbortSignal.timeout(40000),
      });
      const text = await res.text();
      if (res.ok) return JSON.parse(text);
      console.log(`${route} ${JSON.stringify(body)} -> ${res.status} (attempt ${attempt})`);
    } catch (err) {
      console.log(`${route} ${JSON.stringify(body)} failed: ${String(err).slice(0, 100)} (attempt ${attempt})`);
    }
    await sleep(2000 * attempt);
  }
  return null;
}

// Undergraduate degrees and minors, by the shape of Path's program code:
// MAJR-DEGC[-CONC]. Graduate, certificate and LPS codes are left out.
const UNDERGRAD = /-(BA|BS|BSE|BAS|BSN|BFA|MINOR)(-|$)/;

const list = await call("programs-v2-list", { srcdb, programsType: "" });
if (!Array.isArray(list)) { console.log("no program list"); process.exit(1); }
const wanted = list.filter((p) => UNDERGRAD.test(p.code ?? ""));
console.log(`programs listed: ${list.length}; undergraduate: ${wanted.length}`);

mkdirSync(join(out, "programs"), { recursive: true });
const index = [];
for (const p of wanted) {
  const info = await call("programs-v2-info", { srcdb, programCode: p.code });
  await sleep(500);
  const xml = info?.audit_xml;
  if (typeof xml !== "string" || xml.length < 200) {
    console.log(`no template: ${p.code} (${p.title})`);
    index.push({ code: p.code, title: p.title, template: false });
    continue;
  }
  const { audit_xml: _drop, ...meta } = info;
  writeFileSync(join(out, "programs", `${p.code}.xml`), xml);
  writeFileSync(join(out, "programs", `${p.code}.json`), JSON.stringify(meta, null, 1) + "\n");
  index.push({
    code: p.code, title: p.title, template: true, bytes: xml.length, type: info.prog_type,
    college: info.coll_code, degree: info.degc_code, major: info.majr_code, conc: info.conc_code, minor: info.minr_code,
  });
}
const got = index.filter((x) => x.template).length;
writeFileSync(join(out, "index.json"), JSON.stringify({
  srcdb, fetched: new Date().toISOString().slice(0, 10),
  source: `${API}?page=fose&route=programs-v2-info`, listed: list.length, programs: index,
}, null, 1) + "\n");
writeFileSync(join(out, "all-programs.json"), JSON.stringify(list) + "\n");
writeFileSync(join(out, "README.md"), [
  "# Path@Penn program templates (raw)",
  "",
  "Penn's public requirement templates for undergraduate programs, as",
  "`courses.upenn.edu` serves them without a sign-in (the audit of Penn's own",
  "dummy student). Fetched by `scripts/penn-catalog/fetch-programs.mjs` on a",
  `GitHub runner for term ${srcdb}. This branch is replaced whole on each run`,
  "and holds nothing about any student. Never merge it.",
  "",
].join("\n"));
console.log(`templates saved: ${got} of ${wanted.length}`);
if (got < 100) process.exit(1);
