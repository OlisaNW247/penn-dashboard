// Checks the unverified rules in docs/research/degree-data/RULES.md against
// Penn's own public pages, from a GitHub runner (the cloud sessions that
// wrote RULES.md could not reach a Penn host, so 67 of its rules quote what
// a search tool reported, not what the page says).
//
// It crawls the public handbooks those rules cite (Wharton's undergraduate
// site, the Engineering student handbook, the College's policy pages, the
// Nursing BSN handbook, the catalog's policy pages) plus every URL RULES.md
// names, turns each page into text, and for every quoted fragment of every
// rule that is not already VERIFIED prints one of:
//
//   EXACT  the words appear on a page, whitespace and punctuation aside
//   NEAR   most of the words appear close together; the passage is printed
//   MISS   nothing close was found; the best page and score are printed
//
// Searching the whole corpus, and not only the URL a rule names, is on
// purpose: many of the rules cite a URL the search tool abbreviated or
// guessed, and the sentence may live one page over.
//
// Nothing is written anywhere but the job log. No sign-in, no student data:
// every URL is a public page. Failures are printed and never thrown.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/pdf;q=0.8,*/*;q=0.7",
  "Accept-Language": "en-US,en;q=0.9",
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const DEADLINE = Date.now() + 18 * 60 * 1000;

// ---------------------------------------------------------------- rules

const rulesText = readFileSync("docs/research/degree-data/RULES.md", "utf8");
const rules = [];
for (const block of rulesText.split(/\n(?=\*\*[A-Z]+-\d+[a-z]?\. )/)) {
  const head = block.match(/^\*\*([A-Z]+-\d+[a-z]?)\. ([^*]*)\*\*/);
  if (!head) continue;
  const statuses = [...block.matchAll(/Status:\s*([A-Z]+(?: \([^)]*\))?)/g)].map((m) => m[1]);
  const status = statuses.join(" / ") || "NONE";
  // Checked: anything the first pass only heard about (REPORTED), read in
  // someone's code (CODE), or found in two versions (CONFLICTING).
  if (!/REPORTED|CONFLICTING|CODE|NONE/.test(status)) continue;
  const body = block.split(/\n---\n|\n## /)[0];
  const quotes = [];
  for (const m of body.matchAll(/"([^"]{12,})"/g)) {
    for (const part of m[1].split(/\s*\.\.\.\s*|\s+·\s+|\s*\[[^\]]*\]\s*/)) {
      const clean = part.replace(/\s+/g, " ").trim();
      if (tokens(clean).length >= 4) quotes.push(clean);
    }
  }
  const urls = [...body.matchAll(/https?:\/\/[^\s`)>\]]+/g)]
    .map((m) => m[0].replace(/[.,;]+$/, ""))
    .filter((u) => !u.includes("{"));
  rules.push({ id: head[1], title: head[2].trim(), status, quotes, urls });
}
console.log(`rules to check: ${rules.length}; quoted fragments: ${rules.reduce((n, r) => n + r.quotes.length, 0)}`);

// ---------------------------------------------------------------- crawl

/** A scope is one crawl: where it starts, which links it follows, how far. */
const scopes = [
  {
    name: "wharton-ug",
    seeds: [
      "https://undergrad-inside.wharton.upenn.edu/",
      "https://undergrad-inside.wharton.upenn.edu/wp-content/uploads/2025/06/2025-26_Handbook.pdf",
    ],
    sitemaps: [
      "https://undergrad-inside.wharton.upenn.edu/wp-sitemap.xml",
      "https://undergrad-inside.wharton.upenn.edu/sitemap_index.xml",
      "https://undergrad-inside.wharton.upenn.edu/page-sitemap.xml",
    ],
    // The sitemap lists every page; following links as well only queues
    // a thousand student stories ahead of the policy pages.
    follow: (u, from) => from === "sitemap" && u.host === "undergrad-inside.wharton.upenn.edu" &&
      !/internship|blog|award|webinar|story|stories|spotlight|profile|\/(news|events?|people|tag|category|author|feed)\//.test(u.pathname),
    pdf: (u) => /handbook/i.test(u.pathname),
    max: 420,
  },
  {
    name: "seas-handbook",
    seeds: ["https://academics.engineering.upenn.edu/ugrad/student-handbook/"],
    follow: (u) => u.host === "academics.engineering.upenn.edu" && u.pathname.startsWith("/ugrad/student-handbook"),
    max: 260,
  },
  {
    name: "seas-www",
    seeds: ["https://www.seas.upenn.edu/dual-degrees/"],
    follow: () => false,
    max: 3,
  },
  {
    name: "college",
    seeds: [
      "https://www.college.upenn.edu/degree-requirements",
      "https://www.college.upenn.edu/dual-degree",
      "https://www.college.upenn.edu/pass-fail",
      "https://www.college.upenn.edu/equivalent-credit",
      "https://www.college.upenn.edu/academics",
      "https://www.college.upenn.edu/academics/policies-procedures",
      "https://www.college.upenn.edu/double-counting",
      "https://www.college.upenn.edu/courseload",
      "https://www.college.upenn.edu/sectors",
      "https://www.college.upenn.edu/foundational-approaches",
      "https://www.college.upenn.edu/language-requirement",
      "https://www.college.upenn.edu/academics/new-curriculum-class-2031-later/new-curriculum-distribution",
      "https://www.college.upenn.edu/academics/new-curriculum-class-2031-later/new-curriculum-foundations",
      "https://www.college.upenn.edu/academics/academic-options/campus-options/xcat-external-credit-approval-tool",
    ],
    follow: (u) => u.host === "www.college.upenn.edu" &&
      /polic|double|count|courseload|course-load|dual|credit|requirement|sector|foundation|language|major|minor|pass-fail|retak|repeat|residen|submat|curriculum|academic-options|graduat|transfer|placement|grade/i.test(u.pathname),
    pdf: (u) => /polic|handbook|C\d\d/i.test(u.pathname),
    // The College's site answers a runner 403; the archive's copy is read
    // instead and every verdict from it says so.
    archiveFallback: true,
    max: 110,
  },
  {
    name: "nursing-bsn",
    seeds: ["https://www.nursing.upenn.edu/students/handbooks-forms/bsn-handbook/"],
    follow: (u) => u.host === "www.nursing.upenn.edu" && u.pathname.startsWith("/students/handbooks-forms/bsn-handbook"),
    max: 90,
  },
  {
    name: "catalog",
    seeds: [
      "https://catalog.upenn.edu/undergraduate/policies-procedures/",
      "https://catalog.upenn.edu/undergraduate/wharton/curriculum/",
      "https://catalog.upenn.edu/undergraduate/arts-sciences/curriculum/",
      "https://catalog.upenn.edu/undergraduate/nursing/curriculum/",
      "https://catalog.upenn.edu/undergraduate/engineering-applied-science/",
      "https://catalog.upenn.edu/undergraduate/programs/international-studies-ba/",
      "https://catalog.upenn.edu/undergraduate/programs/artificial-intelligence-bse/",
      "https://catalog.upenn.edu/undergraduate/programs/electrical-engineering-bse/",
      "https://catalog.upenn.edu/undergraduate/programs/materials-science-engineering-bse/",
      "https://catalog.upenn.edu/undergraduate/programs/nursing-bsn/",
      "https://catalog.upenn.edu/undergraduate/programs/computer-science-bse/",
    ],
    follow: (u) => u.host === "catalog.upenn.edu" && u.pathname.startsWith("/undergraduate/policies-procedures/"),
    archiveFallback: true,
    max: 60,
  },
];
// Every other URL a rule names is a one-page scope of its own host.
{
  const covered = new Set(scopes.flatMap((s) => s.seeds.map((u) => new URL(u).host)));
  const extra = new Map();
  for (const r of rules) {
    for (const raw of r.urls) {
      let u; try { u = new URL(raw); } catch { continue; }
      if (covered.has(u.host)) {
        const scope = scopes.find((s) => s.seeds.some((x) => new URL(x).host === u.host));
        if (!scope.seeds.includes(u.href)) scope.seeds.push(u.href);
        continue;
      }
      if (!extra.has(u.host)) extra.set(u.host, []);
      if (!extra.get(u.host).includes(u.href)) extra.get(u.host).push(u.href);
    }
  }
  for (const [host, seeds] of extra) {
    scopes.push({ name: host, seeds, follow: () => false, max: seeds.length + 1, archiveFallback: true });
  }
}

/** url -> { text, via } for every page read. */
const corpus = new Map();
const fetchLog = [];

function htmlToText(html) {
  return html
    .replace(/<(script|style|noscript|svg|nav|header|footer)\b[\s\S]*?<\/\1>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<\/(p|div|li|h[1-6]|tr|td|th|br|section|article|ul|ol|table|dd|dt)>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#0?39;|&apos;|&rsquo;|&lsquo;/g, "'")
    .replace(/&ldquo;|&rdquo;/g, '"').replace(/&ndash;|&mdash;/g, "-")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/[ \t\r]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();
}

function linksOf(html, base) {
  const out = [];
  for (const m of html.matchAll(/href\s*=\s*["']([^"'#]+)(?:#[^"']*)?["']/gi)) {
    try {
      const u = new URL(m[1], base);
      if (u.protocol !== "https:" && u.protocol !== "http:") continue;
      u.hash = "";
      out.push(u);
    } catch { /* not a URL */ }
  }
  return out;
}

const pdfDir = mkdtempSync(join(tmpdir(), "penn-pdf-"));
let pdfCount = 0;
function pdfToText(buffer) {
  const file = join(pdfDir, `f${pdfCount++}.pdf`);
  writeFileSync(file, buffer);
  try {
    return execFileSync("pdftotext", ["-layout", file, "-"], { maxBuffer: 64 * 1024 * 1024 }).toString("utf8");
  } catch (err) {
    return `pdftotext failed: ${String(err).slice(0, 120)}`;
  }
}

async function get(url, { archive = false } = {}) {
  const target = archive ? `https://web.archive.org/web/2026id_/${url}` : url;
  try {
    const res = await fetch(target, { headers: HEADERS, redirect: "follow", signal: AbortSignal.timeout(archive ? 45000 : 25000) });
    const type = res.headers.get("content-type") ?? "";
    if (!res.ok || res.status === 202) return { status: res.status, type, body: null, finalUrl: res.url };
    const buffer = Buffer.from(await res.arrayBuffer());
    return { status: res.status, type, body: buffer, finalUrl: res.url };
  } catch (err) {
    return { status: 0, type: "", body: null, error: String(err).slice(0, 100), finalUrl: target };
  }
}

async function crawl(scope) {
  const queue = [...scope.seeds];
  const seen = new Set(queue.map(norm));
  let pdfs = 0;
  // A sitemap, where the site has one, finds pages no link reaches.
  for (const map of scope.sitemaps ?? []) {
    const res = await get(map);
    if (!res.body) continue;
    const xml = res.body.toString("utf8");
    const locs = [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => m[1]);
    for (const loc of locs) {
      if (/sitemap.*\.xml/i.test(loc)) {
        const sub = await get(loc);
        if (sub.body) {
          for (const m of sub.body.toString("utf8").matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)) enqueue(m[1], "sitemap");
        }
        await sleep(200);
      } else enqueue(loc, "sitemap");
    }
    console.log(`[${scope.name}] sitemap ${map}: ${locs.length} entries`);
  }
  function enqueue(raw, from = "link") {
    let u; try { u = new URL(raw); } catch { return; }
    const isPdf = /\.pdf$/i.test(u.pathname);
    if (isPdf ? !(scope.pdf?.(u) && pdfs < 14) : !scope.follow(u, from)) return;
    if (/\.(jpg|jpeg|png|gif|svg|css|js|zip|docx?|xlsx?|pptx?|ics|mp4)$/i.test(u.pathname)) return;
    const key = norm(u.href);
    if (seen.has(key)) return;
    seen.add(key);
    if (isPdf) pdfs++;
    queue.push(u.href);
  }
  let read = 0;
  while (queue.length > 0 && read < scope.max && Date.now() < DEADLINE) {
    const url = queue.shift();
    let res = await get(url);
    let via = "live";
    if (!res.body && scope.archiveFallback) {
      const first = res.status;
      res = await get(url, { archive: true });
      via = `archive (live answered ${first})`;
    }
    read++;
    if (!res.body) {
      fetchLog.push(`${scope.name} FAIL ${res.status} ${res.error ?? ""} ${url}`);
      await sleep(250);
      continue;
    }
    const isPdf = /pdf/i.test(res.type) || /\.pdf$/i.test(new URL(url).pathname);
    let text;
    if (isPdf) text = pdfToText(res.body);
    else {
      const html = res.body.toString("utf8");
      text = htmlToText(html);
      for (const link of linksOf(html, res.finalUrl?.startsWith("https://web.archive.org") ? url : (res.finalUrl ?? url))) enqueue(link.href);
    }
    corpus.set(url, { text, via });
    fetchLog.push(`${scope.name} ok ${via} ${text.length} ${url}`);
    await sleep(250);
  }
  console.log(`[${scope.name}] read ${read}, left in queue ${queue.length}`);
}
function norm(href) { return href.replace(/^http:/, "https:").replace(/\/+$/, "").toLowerCase(); }

// ---------------------------------------------------------------- matching

function tokens(s) {
  return (s.toLowerCase().replace(/[‘’]/g, "'").match(/[a-z0-9]+(?:\.[0-9]+)?/g)) ?? [];
}
function indexDoc(text) {
  const toks = [], starts = [], ends = [];
  const lower = text.toLowerCase().replace(/[‘’]/g, "'");
  for (const m of lower.matchAll(/[a-z0-9]+(?:\.[0-9]+)?/g)) {
    toks.push(m[0]); starts.push(m.index); ends.push(m.index + m[0].length);
  }
  return { toks, starts, ends, joined: ` ${toks.join(" ")} `, set: new Set(toks) };
}

function check(quote, docs) {
  const q = tokens(quote);
  const needle = ` ${q.join(" ")} `;
  for (const [url, d] of docs) {
    const at = d.index.joined.indexOf(needle);
    if (at >= 0) return { verdict: "EXACT", url, via: d.via };
  }
  const key = [...new Set(q.filter((t) => t.length >= 4 || /\d/.test(t)))];
  if (key.length === 0) return { verdict: "MISS", score: 0 };
  const ranked = [...docs]
    .map(([url, d]) => ({ url, d, cover: key.filter((t) => d.index.set.has(t)).length / key.length }))
    .sort((a, b) => b.cover - a.cover)
    .slice(0, 6);
  let best = { score: 0 };
  for (const { url, d } of ranked) {
    const { toks, starts, ends } = d.index;
    const size = Math.max(Math.round(q.length * 1.6), 24);
    const step = Math.max(Math.floor(q.length / 3), 4);
    for (let i = 0; i < Math.max(toks.length - size, 1); i += step) {
      const window = new Set(toks.slice(i, i + size));
      const score = key.filter((t) => window.has(t)).length / key.length;
      if (score > best.score) {
        const a = Math.max(i - 6, 0), b = Math.min(i + size + 6, toks.length - 1);
        best = { score, url, via: d.via, passage: d.text.slice(starts[a], ends[b]).replace(/\s+/g, " ") };
      }
    }
  }
  return { verdict: best.score >= 0.6 ? "NEAR" : "MISS", ...best };
}

// ---------------------------------------------------------------- run

await Promise.all(scopes.map((s) => crawl(s).catch((err) => console.log(`[${s.name}] crawl failed: ${err}`))));
for (const d of corpus.values()) d.index = indexDoc(d.text);
console.log(`\ncorpus: ${corpus.size} pages, ${[...corpus.values()].reduce((n, d) => n + d.text.length, 0)} characters`);

console.log("\n================ RULES ================");
const tally = { EXACT: 0, NEAR: 0, MISS: 0 };
for (const r of rules) {
  console.log(`\n## ${r.id} | ${r.title} | was ${r.status}`);
  if (r.quotes.length === 0) console.log("  (no quoted fragment to check)");
  for (const quote of r.quotes) {
    const res = check(quote, corpus);
    tally[res.verdict]++;
    if (res.verdict === "EXACT") console.log(`  EXACT [${res.via}] ${res.url}\n        q: ${quote}`);
    else if (res.verdict === "NEAR") console.log(`  NEAR ${res.score.toFixed(2)} [${res.via}] ${res.url}\n        q: ${quote}\n        page: ${res.passage}`);
    else console.log(`  MISS best ${(res.score ?? 0).toFixed(2)} ${res.url ?? ""}\n        q: ${quote}${res.passage ? `\n        closest: ${res.passage.slice(0, 400)}` : ""}`);
  }
}
console.log(`\ntally: ${JSON.stringify(tally)}`);

// The pages the planner's own policy rests on, printed whole (capped), so the
// rule can be read in its context and not only matched as a fragment.
console.log("\n================ FULL TEXT OF KEY PAGES ================");
const KEY = [
  /academics\.engineering\.upenn\.edu\/.*(dual-degrees-and-special-programs|dual-majors|enrollment|course-load|summer|social-science-and-humanities|free-electives|pass-fail|transfer-academic-opportunities|advanced-placement|submatriculation|no-credit|technical-electives|second-major|minor|standing-grading|graduation|courses-at-other|course-categories)[^/]*\/?$/,
  /www\.seas\.upenn\.edu\/dual-degrees\/?$/,
  /www\.college\.upenn\.edu\/.*(dual-degree|double-count|courseload|pass-fail|equivalent-credit|degree-requirements|sectors|foundational|language|polic)[^/]*\/?$/,
];
const WHARTON_KEY = /curriculum|requirement|concentration|elective|technology|cross-cultural|humanities|flex|liberal|fundamental|unrestricted|minor|retak|failing|abroad|transfer|credit|advanced-placement|language|capstone|breadth|double|course-load|dual|pass-fail|graduation|polic|leadership-journey|first-year|las-course|incompatible|natural-science|social-science|summer-courses|registration/;
const WHARTON_SKIP = /internship|blog|award|webinar|story|stories|news|event|form|faq-|research|scholar|career|club|housing|wellness|award/;
let whole = 0;
for (const [url, d] of corpus) {
  const path = new URL(url).pathname;
  const wharton = url.includes("undergrad-inside.wharton.upenn.edu") && !/\.pdf$/i.test(path) &&
    WHARTON_KEY.test(path) && !WHARTON_SKIP.test(path);
  if (!wharton && !KEY.some((re) => re.test(url))) continue;
  if (whole++ >= 140) break;
  // Menus and footers repeat on every page: keep the lines that say something.
  const body = d.text.split("\n").map((l) => l.trim()).filter((l) => l.length > 45).join("\n");
  console.log(`\n----- ${url} [${d.via}] (${d.text.length} chars)\n${body.slice(0, 7000)}`);
}

// The Wharton handbook is one PDF: print the pages that state counting rules.
console.log("\n================ HANDBOOK PASSAGES ================");
for (const [url, d] of corpus) {
  if (!/handbook.*\.pdf$/i.test(url)) continue;
  console.log(`handbook: ${url} (${d.text.length} chars)`);
  const seenAt = new Set();
  for (const m of d.text.matchAll(/double[- ]count|dual[- ]degree|course load|summer|capstone|Global Economy|Technology, Innovation|unrestricted elective|placement|pass\/fail|46|second concentration/gi)) {
    const bucket = Math.floor(m.index / 900);
    if (seenAt.has(bucket) || seenAt.size >= 70) continue;
    seenAt.add(bucket);
    console.log(`  [${m[0]}] ${d.text.slice(Math.max(m.index - 350, 0), m.index + 650).replace(/\s+/g, " ")}`);
  }
}

// Sentences about the numbers the planner hard-codes, wherever they are.
console.log("\n================ KEYWORD CONTEXT ================");
const PROBES = [
  ["summer limit", /summer[^.\n]{0,160}\b(?:\d(?:\.\d)?|one|two|three|four|five)\s*(?:cus?|c\.u\.|course units?|courses)\b|\b(?:\d(?:\.\d)?|two|three|four)\s*(?:cus?|c\.u\.|course units?|courses)[^.\n]{0,160}summer/gi],
  ["46 cu", /[^.\n]{0,200}\b46\b[^.\n]{0,200}/g],
  ["load numbers", /[^.\n]{0,200}\b(?:5\.5|6\.5|7\.5|6\.0|7\.0)\s*(?:cus?|c\.u\.|course units?)[^.\n]{0,200}/gi],
  ["triple count", /[^.\n]{0,220}triple[- ]count[^.\n]{0,220}/gi],
  ["placement exam language", /[^.\n]{0,200}placement (?:exam|test)[^.\n]{0,200}/gi],
];
for (const [name, re] of PROBES) {
  console.log(`\n--- ${name}`);
  const seenText = new Set();
  let shown = 0;
  for (const [url, d] of corpus) {
    if (!/wharton|engineering|seas\.upenn/.test(url)) continue;
    for (const m of d.text.matchAll(re)) {
      const passage = m[0].replace(/\s+/g, " ").trim();
      const key = passage.slice(0, 80);
      if (seenText.has(key) || shown >= 30) continue;
      seenText.add(key); shown++;
      console.log(`  ${url}\n      ${passage}`);
    }
  }
}

console.log("\n================ FETCH LOG ================");
for (const line of fetchLog) console.log(line);
