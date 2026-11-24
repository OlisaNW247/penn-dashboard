// Adds poster designs to the hosting platform's single-file Worker, which
// owns the list of designs (`const posters = new Map([...])`) and the images
// (`const imageData = {...}`, one line, megabytes of base64). The ambassador
// code reads that list through SMOOTH_HOST, so a design the app should show
// has to exist there, and its preview has to be in the dictionary for
// `/posters/{school}/{key}.jpg` to answer.
//
// The dictionary's exact shape was never written down, so this reads it from
// the file instead of assuming it: the keys of the parsed object say whether
// images are kept per school ("uva/ib"), per design ("ib") or nested by
// school ({ uva: { ib } }), and an existing value says whether it is a data
// URL or bare base64. Anything else is refused, loudly, with nothing written.
// Every entry already there is kept exactly as parsed, and a design the host
// already lists is skipped, so a second run changes nothing.
//
// Pure: text in, text out. scripts/build-sites.mjs calls it; test/add-posters
// .test.mjs runs it against synthetic hosts of each shape.

const MAP_START = "const posters = new Map([";
const IMAGE_PREFIX = "const imageData = ";

export class AddPostersError extends Error {}

function fail(msg) {
  throw new AddPostersError(msg);
}

// The designs the host's Map names, with the quote style of its last entry.
export function hostDesigns(text) {
  const at = text.indexOf(MAP_START);
  if (at === -1 || text.indexOf(MAP_START, at + 1) !== -1) fail("the posters Map was not found exactly once");
  const close = text.indexOf("])", at);
  if (close === -1) fail("the posters Map has no closing ])");
  const body = text.slice(at + MAP_START.length, close);
  const entries = [...body.matchAll(/\[\s*(['"])([^'"]+)\1\s*,\s*(['"])((?:\\.|(?!\3)[^\\])*)\3\s*\]/g)];
  if (!entries.length) fail("the posters Map has no entries this reader understands");
  return { at, close, body, keys: entries.map((m) => m[2]), quote: entries[entries.length - 1][1] };
}

export function imageLine(text) {
  const lines = text.split("\n");
  const i = lines.findIndex((l) => l.startsWith(IMAGE_PREFIX));
  if (i === -1 || lines.findIndex((l, j) => j > i && l.startsWith(IMAGE_PREFIX)) !== -1) fail("the imageData line was not found exactly once");
  const line = lines[i];
  if (!line.endsWith(";")) fail("the imageData line does not end with ;");
  let data;
  try {
    data = JSON.parse(line.slice(IMAGE_PREFIX.length, -1));
  } catch {
    fail("the imageData dictionary is not JSON");
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) fail("the imageData dictionary is not an object");
  return { lines, i, data };
}

// How the dictionary is keyed and what a value looks like, read from what is there.
export function imageShape(data, schools) {
  const keys = Object.keys(data);
  if (!keys.length) fail("the imageData dictionary is empty");
  const first = data[keys[0]];
  let keyed;
  if (typeof first === "string") keyed = keys.every((k) => k.includes("/")) ? "school/design" : keys.some((k) => k.includes("/")) ? null : "design";
  else if (first && typeof first === "object" && keys.every((k) => schools.includes(k))) keyed = "nested";
  if (!keyed) fail("the imageData dictionary is keyed in a way this reader does not understand");
  const sample = keyed === "nested" ? Object.values(first)[0] : first;
  if (typeof sample !== "string") fail("an imageData value is not a string");
  const m = sample.match(/^data:([a-z]+\/[a-z0-9.+-]+);base64,/i);
  return { keyed, prefix: m ? `data:${m[1]};base64,` : "" };
}

// additions: [{ key, name, jpeg: Buffer }]. schools: the host's school ids.
export function addPosters(text, additions, schools) {
  const map = hostDesigns(text);
  const fresh = additions.filter((a) => !map.keys.includes(a.key));
  for (const a of fresh) {
    if (!/^[a-z0-9-]+$/.test(a.key)) fail(`bad key ${JSON.stringify(a.key)}`);
    if (typeof a.name !== "string" || !a.name || /["\\\n]/.test(a.name)) fail(`bad name for ${a.key}`);
    if (!Buffer.isBuffer(a.jpeg) || a.jpeg.length < 4 || a.jpeg[0] !== 0xff || a.jpeg[1] !== 0xd8) fail(`${a.key}: the preview is not a JPEG`);
  }
  if (!fresh.length) return { text, added: [] };

  // 1. The Map: new entries before its closing ]), in the host's own quote style.
  const q = map.quote;
  const sep = map.body.trimEnd().endsWith(",") ? "" : ",";
  const entry = (a) => `[${q}${a.key}${q}, ${q}${a.name.replace(/'/g, q === "'" ? "\\'" : "'")}${q}]`;
  const insert = `${sep} ${fresh.map(entry).join(", ")}`;
  let out = text.slice(0, map.close) + insert + text.slice(map.close);

  // 2. The dictionary: one entry per school for a per-school host, one per
  //    design otherwise. Re-serialised from the parsed object, so what was
  //    there survives as data even if not byte for byte (package-sites
  //    checks exactly that).
  const { lines, i, data } = imageLine(out);
  const { keyed, prefix } = imageShape(data, schools);
  for (const a of fresh) {
    const value = prefix + a.jpeg.toString("base64");
    if (keyed === "design") data[a.key] = value;
    else if (keyed === "school/design") for (const s of schools) data[`${s}/${a.key}`] = value;
    else for (const s of schools) (data[s] ??= {})[a.key] = value;
  }
  lines[i] = IMAGE_PREFIX + JSON.stringify(data) + ";";
  out = lines.join("\n");
  return { text: out, added: fresh.map((a) => a.key) };
}

// For package-sites: every image the original had is still there, unchanged.
export function imagesKept(originalText, editedText) {
  const a = imageLine(originalText).data;
  const b = imageLine(editedText).data;
  const flat = (o, p = "") => Object.entries(o).flatMap(([k, v]) => (typeof v === "string" ? [[p + k, v]] : flat(v, p + k + "/")));
  const bm = new Map(flat(b));
  return flat(a).every(([k, v]) => bm.get(k) === v);
}
