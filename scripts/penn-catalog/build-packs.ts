// Builds the degree "packs" from the Degree Works audit templates fetched by
// fetch-programs.mjs (Penn's public `programs-v2-info`).
//
//   deno run --allow-read --allow-write scripts/penn-catalog/build-packs.ts \
//     <rawDir> <outDir> [--check]
//
// Reads <rawDir>/programs/*.xml (and the .json metadata beside each, and
// <rawDir>/index.json, when present) and writes
//   <outDir>/blocks/<Req_id>.json   one block per unique Req_id (+ programs)
//   <outDir>/programs.json          code -> { title, goals, blockIds }
//   <outDir>/index.json             one summary row per block
// then prints a report. The report is the point: it says which blocks two
// programs disagree about (the same Req_id appears in many templates, and the
// planner will trust one copy), which qualifier names Penn used that the parser
// only keeps as text, and which course lists did not read. Run it after every
// refetch and read the numbers before trusting the output.
//
// `--check` also verifies the XML reader itself, by comparing the number of
// elements it built for each tag with a regex count of `<Tag` in the raw text.
//
// Output is deterministic: sorted keys where order is not document order,
// 1-space indent, trailing newline. Reading is by bytes and the declared
// encoding (Penn says ISO-8859-1), not Deno's UTF-8 default.

import { parseTemplate, MODELLED_HEADER_QUALIFIERS, MODELLED_RULE_QUALIFIERS } from "../../backend/supabase/functions/_shared/degreePlanner/pack.ts";
import type { PackBlock, PackRule } from "../../backend/supabase/functions/_shared/degreePlanner/pack.ts";
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
async function writeJson(path: string, value: unknown, sorted = false) {
  const text = JSON.stringify(sorted ? sortKeys(value) : value, null, 1) + "\n";
  bytesWritten += new TextEncoder().encode(text).length;
  await Deno.writeTextFile(path, text);
}

/** First path at which two JSON values differ, with both values clipped. */
function firstDiff(a: any, b: any, path = ""): string | null {
  if (JSON.stringify(a) === JSON.stringify(b)) return null;
  if (a && b && typeof a === "object" && typeof b === "object" && Array.isArray(a) === Array.isArray(b)) {
    const keys = Array.isArray(a) ? [...Array(Math.max(a.length, b.length)).keys()] : [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
    for (const k of keys) {
      const d = firstDiff(a[k as any], b[k as any], `${path}/${k}`);
      if (d) return d;
    }
  }
  const clip = (v: unknown) => (JSON.stringify(v) ?? "undefined").slice(0, 60);
  return `${path || "/"}: ${clip(a)} vs ${clip(b)}`;
}

function hint(a: PackBlock, b: PackBlock): string {
  const la = a.rules.map((r) => r.label);
  const lb = b.rules.map((r) => r.label);
  const onlyA = la.filter((x) => !lb.includes(x));
  const onlyB = lb.filter((x) => !la.includes(x));
  const parts: string[] = [];
  if (onlyA.length || onlyB.length) {
    parts.push(`top-level rule labels differ (only first: ${JSON.stringify(onlyA.slice(0, 3))}, only second: ${JSON.stringify(onlyB.slice(0, 3))})`);
  }
  parts.push(`first diff ${firstDiff({ ...a, programs: undefined }, { ...b, programs: undefined }) ?? "?"}`);
  return parts.join("; ");
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

const blocksById = new Map<string, { block: PackBlock; json: string; first: string; programs: string[] }>();
const programs: Record<string, { title: string; goals: unknown; blockIds: string[] }> = {};
const failures: { file: string; message: string }[] = [];
const errorDocs: string[] = [];
const conflicts: { reqId: string; title: string; a: string; b: string; hint: string }[] = [];
const conflictSeen = new Set<string>();
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
    programs[code] = {
      title: titles.get(code) ?? meta?.prog_name ?? code,
      goals: t.goals,
      blockIds: t.blocks.map((b) => b.reqId),
    };
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
      const json = JSON.stringify(block);
      const seen = blocksById.get(block.reqId);
      if (!seen) blocksById.set(block.reqId, { block, json, first: code, programs: [code] });
      else {
        if (!seen.programs.includes(code)) seen.programs.push(code);
        if (seen.json !== json && !conflictSeen.has(`${block.reqId}|${json}`)) {
          conflictSeen.add(`${block.reqId}|${json}`);
          conflicts.push({ reqId: block.reqId, title: block.title, a: seen.first, b: code, hint: hint(seen.block, block) });
        }
      }
    }
  } catch (e) {
    failures.push({ file, message: e instanceof Error ? e.message : String(e) });
  }
}

await Deno.mkdir(`${outDir}/blocks`, { recursive: true });
const ids = [...blocksById.keys()].sort();
for (const id of ids) {
  const e = blocksById.get(id)!;
  await writeJson(`${outDir}/blocks/${id}.json`, { ...e.block, programs: [...e.programs].sort() });
}
const sortedPrograms = Object.fromEntries(Object.keys(programs).sort().map((k) => [k, programs[k]]));
await writeJson(`${outDir}/programs.json`, sortedPrograms);
const generatedFrom = index ? { srcdb: index.srcdb, fetched: index.fetched } : undefined;
await writeJson(`${outDir}/index.json`, {
  ...(generatedFrom ? { generatedFrom } : {}),
  blocks: ids.map((id) => {
    const e = blocksById.get(id)!;
    return { reqId: id, type: e.block.type, code: e.block.code, title: e.block.title, catalogStart: e.block.catalogYears.start, programs: e.programs.length };
  }),
});

// ------------------------------------------------------------- report

console.log(`templates parsed: ${parsed} of ${files.length} files`);
console.log(`error documents (Penn answered <errors>, no template; not parse failures): ${errorDocs.length}${errorDocs.length ? ` [${errorDocs.join(", ")}]` : ""}`);
console.log(`failures: ${failures.length}`);
for (const f of failures) console.log(`  ${f.file}: ${f.message}`);
console.log(`unique blocks: ${ids.length}`);
console.log(`conflicts: ${conflicts.length} (first 20)`);
for (const c of conflicts.slice(0, 20)) console.log(`  ${c.reqId} "${c.title}" ${c.a} vs ${c.b}: ${c.hint}`);

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
if (failures.length) Deno.exit(1);
