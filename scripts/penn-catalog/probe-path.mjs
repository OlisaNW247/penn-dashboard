// Probes Path@Penn's PUBLIC endpoints from a GitHub runner, to settle what
// docs/research/degree-data/SOURCES.md (S01, S02) could only read in other
// people's code: do the program templates and the course search answer a
// runner without a sign-in, and in what shape. Every response printed here
// is Penn's public data about a program or a course (the audit of Penn's own
// dummy student, Stu_name "*Test"); nothing is about a real student.
// Failures are printed, never thrown, so the rest of the workflow still runs.
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

async function call(route, body) {
  const started = Date.now();
  try {
    const res = await fetch(`${API}?page=fose&route=${route}`, {
      method: "POST", headers: HEADERS, body: encodeURIComponent(JSON.stringify(body)),
      signal: AbortSignal.timeout(30000),
    });
    const text = await res.text();
    console.log(`\n### ${route} ${JSON.stringify(body).slice(0, 120)} -> ${res.status} ${text.length}B ${Date.now() - started}ms`);
    try { return JSON.parse(text); } catch { console.log(`not JSON: ${text.slice(0, 300)}`); return null; }
  } catch (err) {
    console.log(`\n### ${route} failed: ${err}`);
    return null;
  } finally { await sleep(600); }
}

function count(xml, re) {
  const m = new Map();
  for (const x of xml.matchAll(re)) m.set(x[1], (m.get(x[1]) ?? 0) + 1);
  return [...m].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}:${v}`).join(" ");
}

const TERM = "202630";
const list = await call("programs-v2-list", { srcdb: TERM, programsType: "" });
const programs = Array.isArray(list) ? list : (list?.results ?? list?.programs ?? []);
console.log(`programs: ${programs.length}; keys of the answer: ${list && !Array.isArray(list) ? Object.keys(list).join(",") : "array"}`);
console.log(JSON.stringify(programs.slice(0, 5)));
const byEnd = new Map();
for (const p of programs) {
  const tail = String(p.code ?? "").split("-").slice(1).join("-");
  byEnd.set(tail, (byEnd.get(tail) ?? 0) + 1);
}
console.log(`code endings: ${[...byEnd].sort((a, b) => b[1] - a[1]).slice(0, 40).map(([k, v]) => `${k}:${v}`).join(" ")}`);

// Which codes exist for the programs a first probe guessed wrong (CSCI-BSE,
// MGMT-BS and ECON-BA answered "{}"): print every code that starts with them.
for (const stem of ["CSCI", "MGMT", "ECON", "CMPE", "NETS"]) {
  console.log(`codes ${stem}: ${programs.filter((p) => String(p.code).startsWith(stem + "-")).map((p) => p.code).join(" ")}`);
}
const pick = (stem, want) => programs.map((p) => String(p.code)).find((c) => c.startsWith(stem + "-") && want.test(c));
const wanted = [pick("CSCI", /BSE/), pick("MGMT", /-BS/), "FNCS-BS", pick("ECON", /-BA/)].filter(Boolean);
for (const code of wanted) {
  const info = await call("programs-v2-info", { srcdb: TERM, programCode: code });
  if (!info) continue;
  const xml = String(info.audit_xml ?? "");
  const rest = Object.fromEntries(Object.entries(info).filter(([k]) => k !== "audit_xml").map(([k, v]) => [k, typeof v === "string" ? v.slice(0, 80) : v]));
  console.log(`keys: ${Object.keys(info).join(",")}`);
  console.log(`meta: ${JSON.stringify(rest).slice(0, 600)}`);
  console.log(`audit_xml: ${xml.length} chars`);
  if (!xml) continue;
  console.log(`blocks: ${[...xml.matchAll(/<Block [^>]*Req_type="([^"]+)"[^>]*Title="([^"]+)"/g)].map((m) => `${m[1]}=${m[2]}`).join(" | ").slice(0, 900)}`);
  console.log(`cat years: ${count(xml, /Cat_yr_start="([^"]+)"/g)}`);
  console.log(`qualifiers: ${count(xml, /<Qualifier [^>]*Name="([^"]+)"/g)}`);
  console.log(`rule types: ${count(xml, /RuleType="([^"]+)"/g)}`);
  console.log(`with codes: ${count(xml, /<With [^>]*Code="([^"]+)"/g)}`);
  console.log(`attributes: ${count(xml, /<With [^>]*Code="ATTRIBUTE"[^>]*>\s*<Value>([^<]+)<\/Value>/g).slice(0, 600)}`);
  const share = [...xml.matchAll(/<Qualifier [^>]*Name="(NONEXCLUSIVE|MAXCREDIT|MAXCLASS|MINRES|MINGPA|LASTRES)"[\s\S]*?<\/Qualifier>/g)].slice(0, 12)
    .map((m) => m[0].replace(/\s+/g, " ").slice(0, 420));
  for (const s of share) console.log(`  Q ${s}`);
  if (code === "CSCI-BSE") console.log(`first 2500 chars:\n${xml.slice(0, 2500)}`);
}

const search = await call("search", { other: { srcdb: TERM }, criteria: [{ field: "keyword", value: "BEPP 2500" }] });
console.log(`search count ${search?.count}; first: ${JSON.stringify(search?.results?.[0] ?? null).slice(0, 700)}`);
const first = search?.results?.[0];
if (first) {
  const d = await call("details", {
    group: `code:${first.code}`, key: `crn:${first.crn}`, srcdb: TERM, matched: `crn:${first.crn}`, userWithRolesStr: "!!!!!!",
  });
  if (d) {
    console.log(`details keys: ${Object.keys(d).join(",")}`);
    for (const k of ["hours_html", "attributes_detail", "registration_restrictions", "clssnotes", "xlist", "description", "prerequisites", "restrict_info", "eval_links"]) {
      if (d[k] !== undefined) console.log(`  ${k}: ${String(d[k]).replace(/\s+/g, " ").slice(0, 500)}`);
    }
  }
}

// Prerequisites: the details answer carries `prereqs_from_cim`, which the
// first probe did not print. Penn Labs' own `prerequisites` field is empty for
// most courses, so this may be the only machine source of them.
for (const kw of ["CIS 4710", "STAT 4310", "ACCT 1020", "ASLD 0200", "CIS 4000", "FNCE 2050"]) {
  const s2 = await call("search", { other: { srcdb: TERM }, criteria: [{ field: "keyword", value: kw }] });
  const hit = (s2?.results ?? []).find((r) => r.code === kw) ?? null;
  if (!hit) { console.log(`  ${kw}: not in ${TERM} (${s2?.count ?? "?"} results)`); continue; }
  const d = await call("details", {
    group: `code:${hit.code}`, key: `crn:${hit.crn}`, srcdb: TERM, matched: `crn:${hit.crn}`, userWithRolesStr: "!!!!!!",
  });
  for (const k of ["prereqs_from_cim", "xlist", "registration_restrictions", "attributes_detail", "hours_html", "notes_sapr", "registration_options"]) {
    if (d?.[k] !== undefined) console.log(`  ${kw} ${k}: ${String(d[k]).replace(/\s+/g, " ").slice(0, 700)}`);
  }
}
