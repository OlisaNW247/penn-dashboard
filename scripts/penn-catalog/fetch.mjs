// Fetches public Penn course data into a folder, raw, for the degree planner's
// snapshot builder to parse. Run on a GitHub runner (see
// .github/workflows/penn-catalog.yml). Every request is to a public page; no
// sign-in, no student data. Failures are recorded, never fatal, so one bad
// URL does not lose the rest.
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

const out = process.argv[2] ?? "out";
await mkdir(join(out, "raw"), { recursive: true });

const UA = "SmoothDegreePlanner/1 (student dashboard; contact in repo)";

// Attribute codes the audits name (Wharton gen-eds and flex fundamentals,
// SEAS electives). The attribute index page is fetched too, to find the rest.
const ATTRIBUTES = [
  "wuge", "wuti", "wuhm", "wucn", "wucu", "wufl", "wumg", "wusc", "wuss", "wunm",
  "eucu", "euns", "euma", "eune", "euhs", "euss", "eutb", "eums",
];

// Subjects whose courses a requirement names by range ("Any MGMT 1011-4180",
// "Any CIS 2000-9999", "Any NETS 2000-5999") or by subject (business breadth).
const SUBJECTS = [
  "cis", "nets", "ese", "eas", "math", "stat", "mgmt", "oidd", "acct", "bepp",
  "fnce", "lgst", "mktg", "real", "hcmg", "wh", "span", "phys",
];

const urls = [
  ["attributes-index.html", "https://catalog.upenn.edu/attributes/"],
  ["cis-tech-electives.json", "https://advising.cis.upenn.edu/assets/json/37cu_csci_tech_elective_list.json"],
  ["cis-tech-electives.html", "https://advising.cis.upenn.edu/tech-electives/"],
  ["wharton-double-counting.html", "https://undergrad-inside.wharton.upenn.edu/double-counting-courses/"],
  ["wharton-business-breadth.html", "https://undergrad-inside.wharton.upenn.edu/business-breadth/"],
  ["wharton-course-load.html", "https://undergrad-inside.wharton.upenn.edu/course-load/"],
  ["wharton-foreign-language.html", "https://undergrad-inside.wharton.upenn.edu/foreign-language-requirement/"],
  ["wharton-curriculum.html", "https://catalog.upenn.edu/undergraduate/wharton/curriculum/"],
  ["seas-enrollment.html", "https://academics.engineering.upenn.edu/ugrad/student-handbook/academic-policies/enrollment/"],
  ["cs-bse.html", "https://catalog.upenn.edu/undergraduate/programs/computer-science-bse/"],
  ["mgmt-general.html", "https://catalog.upenn.edu/undergraduate/programs/management-general-track-bs/"],
  // Penn Labs' public API: does a course carry attributes, CU, prereqs?
  ["pcx-BEPP-2500-2027A.json", "https://penncoursereview.com/api/base/2027A/courses/BEPP-2500/"],
  ["pcx-CIS-4000-2026C.json", "https://penncoursereview.com/api/base/2026C/courses/CIS-4000/"],
  ["pcx-search-wuge-2027A.json", "https://penncoursereview.com/api/base/2027A/search/courses/?attributes=WUGE"],
  ["pcx-attributes.json", "https://penncoursereview.com/api/base/attributes/"],
  ["pcx-courses-2027A.json", "https://penncoursereview.com/api/base/2027A/courses/"],
];
for (const a of ATTRIBUTES) urls.push([`attr-${a}.html`, `https://catalog.upenn.edu/attributes/${a}/`]);
for (const s of SUBJECTS) urls.push([`courses-${s}.html`, `https://catalog.upenn.edu/courses/${s}/`]);

const log = [];
async function get(name, url) {
  const started = Date.now();
  try {
    const res = await fetch(url, { headers: { "User-Agent": UA }, redirect: "follow" });
    const body = Buffer.from(await res.arrayBuffer());
    await writeFile(join(out, "raw", name), body);
    log.push({ name, url, status: res.status, bytes: body.length, ms: Date.now() - started });
  } catch (err) {
    log.push({ name, url, error: String(err), ms: Date.now() - started });
  }
}

// A few at a time, to be polite to Penn's servers.
for (let i = 0; i < urls.length; i += 4) {
  await Promise.all(urls.slice(i, i + 4).map(([n, u]) => get(n, u)));
}
await writeFile(join(out, "fetch-log.json"), JSON.stringify(log, null, 2));
for (const l of log) console.log(`${l.status ?? "ERR"} ${l.bytes ?? 0}B ${l.name}`);
