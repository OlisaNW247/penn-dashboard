// Builds the degree "packs" from the Degree Works audit templates fetched by
// fetch-programs.mjs (Penn's public `programs-v2-info`).
//
//   deno run --allow-read --allow-write scripts/penn-catalog/build-packs.ts \
//     <rawDir> <outDir> [--check]
//
// Reads <rawDir>/programs/*.xml (and the .json metadata beside each, and
// <rawDir>/index.json, when present) and writes
//   <outDir>/packs/<CODE>.json   one ProgramPack per program (its own blocks)
//   <outDir>/programs.json       { generatedFrom, programs: ProgramIndexEntry[] }
// then prints a report. Packs are per program because Penn resolves each
// template for its program: the same Req_id differs between programs, so a
// shared per-block copy would be wrong for most of them. The old packs/ and
// blocks/ folders are deleted first so a program Penn drops does not linger,
// but nothing is deleted or written when fewer than 100 templates parse: a
// failed fetch must never be published as "Penn removed its programs". The
// report says which qualifier names the parser only keeps as text and which
// course lists did not read; read it before trusting the output.
//
// `--check` also verifies the XML reader itself, by comparing the number of
// elements it built for each tag with a regex count of `<Tag` in the raw text.
//
// Output is deterministic: sorted keys where order is not document order,
// 1-space indent, trailing newline. Reading is by bytes and the declared
// encoding (Penn says ISO-8859-1), not Deno's UTF-8 default.

import { parseTemplate, toIndexEntry, toProgramPack, MODELLED_HEADER_QUALIFIERS, MODELLED_RULE_QUALIFIERS } from "../../backend/supabase/functions/_shared/degreePlanner/pack.ts";
import type { PackRule, ProgramIndexEntry, ProgramPack } from "../../backend/supabase/functions/_shared/degreePlanner/pack.ts";
import { countTags, findAll, parseXml } from "../../backend/supabase/functions/_shared/degreePlanner/xml.ts";

const args = Deno.args.filter((a) => !a.startsWith("--"));
const check = Deno.args.includes("--check");
if (args.length < 2) {
  console.error("usage: build-packs.ts <rawDir> <outDir> [--check]");
  Deno.exit(2);
}
const [rawDir, outDir] = args;

function decode(bytes: Uint8Array): string {
  const head = new TextDecoder("latin1").decode(bytes.subarray(0, 200));
  const label = /encoding\s*=\s*["']([^"']+)["']/i.exec(head)?.[1] ?? "utf-8";
  try {
    return new TextDecoder(label).decode(bytes);
  } catch {
    return new TextDecoder("utf-8").decode(bytes);
  }
}

async function readJson(path: string): Promise<any | undefined> {
  try {
    return JSON.parse(await Deno.readTextFile(path));
  } catch {
    return undefined;
  }
}

const sortKeys = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sortKeys)
    : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys((v as any)[k])]))
    : v;

let bytesWritten = 0;
let largest = { path: "", bytes: 0 };
async function writeJson(path: string, value: unknown, sorted = false) {
  const text = JSON.stringify(sorted ? sortKeys(value) : value, null, 1) + "\n";
  const size = new TextEncoder().encode(text).length;
  bytesWritten += size;
  if (!path.endsWith("/programs.json") && size > largest.bytes) largest = { path, bytes: size };
  await Deno.writeTextFile(path, text);
}

function walkRules(rules: PackRule[], f: (r: PackRule) => void) {
  for (const r of rules) {
    f(r);
    if (r.children) walkRules(r.children, f);
  }
}

// ---------------------------------------------------------------- run

const files: string[] = [];
for await (const e of Deno.readDir(`${rawDir}/programs`)) if (e.isFile && e.name.endsWith(".xml")) files.push(e.name);
files.sort();

const index = await readJson(`${rawDir}/index.json`);
const titles = new Map<string, string>();
for (const p of index?.programs ?? []) titles.set(p.code, p.title);

const SOURCE = "https://courses.upenn.edu/api/?page=fose&route=programs-v2-info";
const provenance = { source: SOURCE, srcdb: String(index?.srcdb ?? ""), fetched: String(index?.fetched ?? "") };
const packs: ProgramPack[] = [];
const contentsByReqId = new Map<string, Set<string>>(); // information only
const failures: { file: string; message: string }[] = [];
const errorDocs: string[] = [];
const checkMismatches: string[] = [];
const qualTotals = { header: new Map<string, number>(), rule: new Map<string, number>() };
const qualOther = { header: new Map<string, number>(), rule: new Map<string, number>() };
let parsed = 0;
let listsTotal = 0;
let listsUnparsed = 0;
const unparsedTexts = new Map<string, string>(); // text -> first program
const bump = (m: Map<string, number>, k: string) => m.set(k, (m.get(k) ?? 0) + 1);

for (const file of files) {
  const code = file.replace(/\.xml$/, "");
  try {
    const text = decode(await Deno.readFile(`${rawDir}/programs/${file}`));
    const tree = parseXml(text);
    if (tree.tag === "errors") {
      errorDocs.push(code);
      continue;
    }
    if (check) {
      const built = countTags(tree);
      const raw: Record<string, number> = {};
      for (const m of text.matchAll(/<([A-Za-z][\w.-]*)(?=[\s/>])/g)) raw[m[1]] = (raw[m[1]] ?? 0) + 1;
      for (const tag of new Set([...Object.keys(built), ...Object.keys(raw)])) {
        if ((built[tag] ?? 0) !== (raw[tag] ?? 0)) checkMismatches.push(`${code}: <${tag}> reader ${built[tag] ?? 0} vs regex ${raw[tag] ?? 0}`);
      }
    }
    for (const b of findAll(tree, "Block")) {
      for (const h of b.children.filter((c) => c.tag === "Header")) {
        for (const q of h.children.filter((c) => c.tag === "Qualifier")) bump(qualTotals.header, q.attrs.Name ?? "");
      }
    }
    for (const r of findAll(tree, "Requirement")) {
      for (const q of r.children.filter((c) => c.tag === "Qualifier")) bump(qualTotals.rule, q.attrs.Name ?? "");
    }

    const t = parseTemplate(text);
    parsed++;
    const meta = await readJson(`${rawDir}/programs/${code}.json`);
    packs.push(toProgramPack(code, titles.get(code) ?? meta?.prog_name ?? code, t, provenance));
    for (const block of t.blocks) {
      const lists = [...block.limits, ...block.overlays];
      for (const o of block.other) bump(qualOther.header, o.name);
      walkRules(block.rules, (r) => {
        lists.push(...(r.limits ?? []), ...(r.overlays ?? []));
        for (const o of r.other ?? []) bump(qualOther.rule, o.name);
      });
      for (const l of lists) {
        listsTotal++;
        if (l.unparsed) {
          listsUnparsed++;
          if (!unparsedTexts.has(l.text)) unparsedTexts.set(l.text, code);
        }
      }
      const set = contentsByReqId.get(block.reqId) ?? new Set<string>();
      set.add(JSON.stringify(block));
      contentsByReqId.set(block.reqId, set);
    }
  } catch (e) {
    failures.push({ file, message: e instanceof Error ? e.message : String(e) });
  }
}

// A failed or partial fetch must not be published as "Penn dropped these
// programs": refuse before deleting or writing anything.
if (parsed < 100) {
  console.error(`refusing to write: only ${parsed} templates parsed (need at least 100); nothing deleted`);
  Deno.exit(1);
}
await Deno.remove(`${outDir}/packs`, { recursive: true }).catch(() => {});
await Deno.remove(`${outDir}/blocks`, { recursive: true }).catch(() => {});
await Deno.remove(`${outDir}/index.json`).catch(() => {});
await Deno.mkdir(`${outDir}/packs`, { recursive: true });
packs.sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0));
for (const pack of packs) await writeJson(`${outDir}/packs/${pack.code}.json`, pack);
const programsIndex: { generatedFrom: { srcdb: string; fetched: string }; programs: ProgramIndexEntry[] } = {
  generatedFrom: { srcdb: provenance.srcdb, fetched: provenance.fetched },
  programs: packs.map(toIndexEntry),
};
await writeJson(`${outDir}/programs.json`, programsIndex);

// ------------------------------------------------------------- report

console.log(`templates parsed: ${parsed} of ${files.length} files`);
console.log(`error documents (Penn answered <errors>, no template; not parse failures): ${errorDocs.length}${errorDocs.length ? ` [${errorDocs.join(", ")}]` : ""}`);
console.log(`failures: ${failures.length}`);
for (const f of failures) console.log(`  ${f.file}: ${f.message}`);
console.log(`packs written: ${packs.length}`);
console.log(`Req_ids with more than one distinct content across programs: ${[...contentsByReqId.values()].filter((v) => v.size > 1).length} of ${contentsByReqId.size} (information only)`);

console.log("qualifier names (count over all templates; 'other' = kept only as text in the output):");
for (const [where, label, modelled] of [["header", "block header", MODELLED_HEADER_QUALIFIERS], ["rule", "rule", MODELLED_RULE_QUALIFIERS]] as const) {
  console.log(` ${label}:`);
  const names = [...qualTotals[where].keys()].sort((a, b) => qualTotals[where].get(b)! - qualTotals[where].get(a)! || a.localeCompare(b));
  for (const n of names) {
    const o = qualOther[where].get(n) ?? 0;
    const status = modelled.includes(n) ? (o ? `modelled, ${o} fell to other` : "modelled") : "other";
    console.log(`  ${n.padEnd(16)} ${String(qualTotals[where].get(n)).padStart(6)}  ${status}`);
  }
}
console.log(`course lists (limits + overlays): ${listsTotal}, unparsed: ${listsUnparsed} (${listsTotal ? ((100 * listsUnparsed) / listsTotal).toFixed(2) : "0"}%), distinct unparsed texts: ${unparsedTexts.size}`);
for (const [text, code] of [...unparsedTexts].slice(0, 15)) console.log(`  [${code}] ${text.slice(0, 220)}`);
if (check) {
  console.log(`xml reader check: ${checkMismatches.length} mismatches`);
  for (const m of checkMismatches.slice(0, 20)) console.log(`  ${m}`);
}
console.log(`bytes written: ${bytesWritten}`);
console.log(`largest pack: ${largest.path} ${largest.bytes} bytes`);
if (failures.length) Deno.exit(1);
