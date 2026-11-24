// Adds schools to the hosting platform's single-file Worker. The host owns
// the list of schools in three places and the ambassador code reads all of
// them through SMOOTH_HOST, so a school the app should know has to exist in
// each:
//   1. `const schools = new Map([...])`: what /api/stats, /scan/{school}/...
//      and /posters/{school}/... validate against;
//   2. the dashboard's school <select>: one <option> per school;
//   3. the dashboard script's `const schoolNames = {...}`: the cards and the
//      table's school column.
// Each anchor must be found exactly once or the function throws and nothing
// is written. A school the host already lists is skipped, so a second run
// changes nothing. Nothing existing is edited: every insertion is an append
// right before a closing delimiter, in the host's own quote style.
//
// A new school also needs a picture for every design (`addSchoolImages`):
// a design whose picture is the same for two existing schools (no printed QR)
// is copied; one that differs is a QR edition and is rebuilt by
// scripts/lib/school-edition.mjs from the first existing school's picture.
//
// Pure: text in, text out. scripts/build-sites.mjs calls it.
import { imageLine, imageShape, hostDesigns } from "./add-posters.mjs";

export class AddSchoolError extends Error {}
const fail = (m) => {
  throw new AddSchoolError(m);
};

const MAP_START = "const schools = new Map([";
const OPTION_END = "</option>\n</select>";
const NAMES_RE = /const schoolNames = \{([^}\n]*)\};/g;

const count = (text, needle) => text.split(needle).length - 1;

export function hostSchools(text) {
  const at = text.indexOf(MAP_START);
  if (at === -1 || text.indexOf(MAP_START, at + 1) !== -1) fail("the schools Map was not found exactly once");
  const close = text.indexOf("])", at);
  if (close === -1) fail("the schools Map has no closing ])");
  const body = text.slice(at + MAP_START.length, close);
  const entries = [...body.matchAll(/\[\s*(['"])([^'"]+)\1\s*,\s*(['"])((?:\\.|(?!\3)[^\\])*)\3\s*\]/g)];
  if (!entries.length) fail("the schools Map has no entries this reader understands");
  return { close, body, ids: entries.map((m) => m[2]), quote: entries[entries.length - 1][1], bodyEnd: at + MAP_START.length + body.trimEnd().length };
}

// additions: [{ id, name }]. Returns { text, added: [ids] }.
export function addSchools(text, additions) {
  const map = hostSchools(text);
  const fresh = additions.filter((a) => !map.ids.includes(a.id));
  for (const a of fresh) {
    if (!/^[a-z0-9-]+$/.test(a.id ?? "")) fail(`bad school id ${JSON.stringify(a.id)}`);
    if (typeof a.name !== "string" || !a.name.trim() || /['"`\\<>&\n\r]/.test(a.name)) fail(`bad school name ${JSON.stringify(a.name)}`);
  }
  if (new Set(fresh.map((a) => a.id)).size !== fresh.length) fail("a school is listed twice");
  if (!fresh.length) return { text, added: [] };

  // Locate all three anchors before changing anything.
  if (count(text, OPTION_END) !== 1) fail(`the dashboard's last <option> before </select> was found ${count(text, OPTION_END)} times, expected 1`);
  const names = [...text.matchAll(NAMES_RE)];
  if (names.length !== 1) fail(`the schoolNames object was found ${names.length} times, expected 1`);

  const q = map.quote;
  const nameQ = (s) => s.replace(/'/g, "\\'");
  // 1. Map. After the last entry (and its trailing comma when it has one).
  const trailing = map.body.trimEnd().endsWith(",");
  const mapInsert = fresh.map((a) => `[${q}${a.id}${q}, ${q}${nameQ(a.name)}${q}]`);
  const mapText = (trailing ? " " : ", ") + mapInsert.join(", ") + (trailing ? "," : "");
  // 2. Option.
  const optInsert = fresh.map((a) => `<option value="${a.id}">${a.name}</option>`).join("");
  // 3. schoolNames.
  const m = names[0];
  const bodyNames = m[1];
  const key = (id) => (/^[A-Za-z_$][\w$]*$/.test(id) ? id : `'${id}'`);
  const namesInsert = fresh.map((a) => `${key(a.id)}:'${nameQ(a.name)}'`).join(",");
  const sepNames = bodyNames.trim() === "" ? "" : bodyNames.trimEnd().endsWith(",") ? "" : ",";

  // Apply from the end of the file backwards so earlier offsets stay valid.
  const edits = [
    { at: map.bodyEnd, s: mapText },
    { at: text.indexOf(OPTION_END) + "</option>".length, s: optInsert },
    { at: m.index + m[0].length - 2 - (bodyNames.length - bodyNames.trimEnd().length), s: sepNames + namesInsert },
  ].sort((a, b) => b.at - a.at);
  let out = text;
  for (const e of edits) out = out.slice(0, e.at) + e.s + out.slice(e.at);
  return { text: out, added: fresh.map((a) => a.id) };
}

// For every school in `newIds` and every design the host lists that a
// non-UPenn school may have, makes the picture when the host has none.
// makeEdition(templateBytes, templateSchool, design, newSchool) -> Buffer.
export function addSchoolImages(text, newIds, { upennOnly, makeEdition }) {
  const schools = hostSchools(text).ids;
  const designs = hostDesigns(text).keys.filter((d) => !upennOnly.includes(d));
  const { lines, i, data } = imageLine(text);
  const { keyed, prefix } = imageShape(data, schools);
  if (keyed === "design") fail("this host keeps one picture per design, so a new school cannot have its own QR edition");
  const get = (s, d) => (keyed === "nested" ? data[s]?.[d] : data[`${s}/${d}`]);
  const set = (s, d, v) => (keyed === "nested" ? ((data[s] ??= {})[d] = v) : (data[`${s}/${d}`] = v));
  const bare = (v) => v.slice(prefix.length);
  const made = [];
  for (const s of newIds) {
    if (!schools.includes(s)) fail(`${s} is not in the host's schools Map`);
    const donors = schools.filter((x) => x !== "upenn" && !newIds.includes(x));
    for (const d of designs) {
      if (get(s, d) !== undefined) continue;
      const have = donors.filter((x) => typeof get(x, d) === "string").slice(0, 2);
      if (!have.length) fail(`no existing school has a picture of "${d}" to make ${s}/${d} from`);
      if (have.length === 2 && get(have[0], d) === get(have[1], d)) {
        set(s, d, get(have[0], d));
        made.push(`${s}/${d} (copy)`);
      } else {
        const jpeg = makeEdition(Buffer.from(bare(get(have[0], d)), "base64"), have[0], d, s);
        set(s, d, prefix + jpeg.toString("base64"));
        made.push(`${s}/${d} (QR edition from ${have[0]})`);
      }
    }
  }
  if (!made.length) return { text, made };
  lines[i] = "const imageData = " + JSON.stringify(data) + ";";
  return { text: lines.join("\n"), made };
}

// Every valid (school, design) pair on the host has a picture. Returns the missing ones.
export function missingImages(text, upennOnly) {
  const schools = hostSchools(text).ids;
  const designs = hostDesigns(text).keys;
  const { data } = imageLine(text);
  const { keyed } = imageShape(data, schools);
  const missing = [];
  for (const s of schools)
    for (const d of designs) {
      if (s !== "upenn" && upennOnly.includes(d)) continue;
      const v = keyed === "design" ? data[d] : keyed === "nested" ? data[s]?.[d] : data[`${s}/${d}`];
      if (typeof v !== "string") missing.push(`${s}/${d}`);
    }
  return missing;
}
