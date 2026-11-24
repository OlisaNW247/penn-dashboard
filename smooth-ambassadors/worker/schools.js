// Built-in schools plus the ones created at request time (table `schools`).
//
// Built-in = the catalog's list (the host's Map in the built file): unchanged,
// they always win. Dynamic = a row in D1. catalog.js's own exports stay
// synchronous and static; this module gives a request-scoped merged view, read
// from D1 at most once per request (loadSchools) and passed down.
import * as cat from "./catalog.js";
import allowlist from "./canvas-hosts.json" with { type: "json" };

export const GENERIC = cat.GENERIC;
// Words that are routes, and so can never be a school id.
export const RESERVED_IDS = ["all", "a", "r", "f", "api", "scan", "posters", "new"];
export const SCHOOL_ID_RE = /^[a-z0-9][a-z0-9-]{1,23}$/;
export const INVITE_DAILY_LIMIT = 20;
export const INVITED_TOTAL_LIMIT = 300;
export const SCHOOLS_DAILY_LIMIT = 10;
export const SCHOOLS_TOTAL_LIMIT = 500;

// The app's catalog hosts plus any a built-in school maps by hand.
const hostSet = new Set([...allowlist, ...Object.values(cat.SCHOOLS).flatMap((x) => x.canvasHosts ?? [])]);
export const isAllowlistedHost = (h) => typeof h === "string" && hostSet.has(h);
const hasOwn = (o, k) => Object.hasOwn(o, k);

const fullSlug = (name) =>
  String(name ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

// The id: the slug cut to 24 characters (a code is {id}-{14 chars}, and the
// released app refuses codes over 40 characters).
export function slugify(name) {
  return fullSlug(name).slice(0, 24).replace(/-+$/g, "");
}

// 2..60 characters, no control characters, none of <>"'&\ .
export function validSchoolName(name) {
  return typeof name === "string" && name.length >= 2 && name.length <= 60 && !/[\u0000-\u001f\u007f-\u009f<>"'&\\]/.test(name);
}

export function buildSchools(rows = []) {
  const builtinIds = Object.keys(cat.SCHOOLS);
  const taken = new Set(builtinIds.flatMap((id) => cat.SCHOOLS[id].canvasHosts ?? []));
  const dynamic = new Map();
  for (const r of rows) {
    if (!r || typeof r.id !== "string" || hasOwn(cat.SCHOOLS, r.id) || dynamic.has(r.id)) continue; // a built-in id wins
    const host = r.canvas_host && isAllowlistedHost(r.canvas_host) && !taken.has(r.canvas_host) ? r.canvas_host : null;
    if (host) taken.add(host);
    dynamic.set(r.id, { id: r.id, name: String(r.name), host, dynamic: true });
  }
  const sorted = [...dynamic.values()].sort((a, b) => a.name.localeCompare(b.name) || (a.id < b.id ? -1 : 1));
  const view = {
    dynamic: sorted,
    has: (id) => typeof id === "string" && (hasOwn(cat.SCHOOLS, id) || dynamic.has(id)),
    isDynamic: (id) => typeof id === "string" && !hasOwn(cat.SCHOOLS, id) && dynamic.has(id),
    get(id) {
      if (typeof id !== "string") return undefined;
      if (hasOwn(cat.SCHOOLS, id)) return cat.SCHOOLS[id];
      const d = dynamic.get(id);
      return d && { name: d.name, ...(d.host ? { canvasHosts: [d.host] } : {}), dynamic: true };
    },
    canvasHosts: (id) => view.get(id)?.canvasHosts ?? [],
    ids: () => [...builtinIds, ...sorted.map((d) => d.id)],
    list: () => [...builtinIds.map((id) => ({ id, name: cat.SCHOOLS[id].name, dynamic: false })), ...sorted.map((d) => ({ id: d.id, name: d.name, dynamic: true }))],
    designsFor(id) {
      if (hasOwn(cat.SCHOOLS, id)) return cat.designsFor(id);
      if (!dynamic.has(id)) return [];
      const all = cat.designsFor("upenn");
      return GENERIC.filter((d) => all.includes(d));
    },
    offeredDesignsFor: (id) => view.designsFor(id).filter((d) => !cat.RETIRED.includes(d)),
    isValidCombo: (id, d) => view.designsFor(id).includes(d),
    // A dynamic school has no pictures of its own. The generic posters are the
    // same JPEG for every school (a dashed slot for a QR sticker), so it borrows
    // UPenn's path, a legacy host route that is left exactly as it is.
    posterImagePath: (id, d) => cat.posterImagePath(view.isDynamic(id) ? "upenn" : id, d),
    scanKey: (id, d) => cat.scanKey(id, d),
    // All Canvas hosts any school maps (built-in or dynamic).
    mappedHosts: () => view.ids().flatMap((id) => view.canvasHosts(id)),
  };
  return view;
}

export const defaultSchools = () => buildSchools([]);

// One read per request. A database without the table yet reads as "none".
export async function loadSchools(env) {
  try {
    const { results } = await env.DB.prepare("SELECT id, name, canvas_host FROM schools").all();
    return buildSchools(results);
  } catch {
    return buildSchools([]);
  }
}

// Turns what a caller asked for into a school: an existing id, an existing
// school found by host or name, or a new dynamic one. Pure; the insert and its
// limits are in data.js. Returns { error } or { id, name, host, isNew }.
export function resolveSchool(S, { school, schoolName, schoolHost }) {
  const hasId = typeof school === "string" && school !== "";
  const hasName = typeof schoolName === "string" && schoolName !== "";
  if (hasId === hasName) return { error: "bad_school" };
  if (hasId) {
    if (!S.has(school)) return { error: "bad_school" };
    return { id: school, name: S.get(school).name, isNew: false };
  }
  const name = schoolName.trim();
  if (!validSchoolName(name)) return { error: "bad_school" };
  const host = typeof schoolHost === "string" ? schoolHost.trim().toLowerCase() : "";
  if (host && isAllowlistedHost(host)) {
    const owner = S.ids().find((id) => S.canvasHosts(id).includes(host));
    if (owner) return { id: owner, name: S.get(owner).name, isNew: false };
  }
  const lower = name.toLowerCase();
  const slug = slugify(name);
  // The same school when the name matches case-insensitively or by its whole
  // slug. An id that merely equals the CUT slug is not enough: two long names
  // can share their first 24 characters, and the second is a different school
  // that gets a suffix.
  const whole = fullSlug(name);
  const same = S.ids().find((id) => S.get(id).name.toLowerCase() === lower || fullSlug(S.get(id).name) === whole);
  if (same) {
    // Two universities can share a short name ("USC", "Miami"), each with its
    // own Canvas host. A name match is the same school unless the request
    // carries an allowlisted host and the matched school has a DIFFERENT one.
    const theirs = S.canvasHosts(same);
    const reqHost = host && isAllowlistedHost(host) ? host : null;
    if (!reqHost || !theirs.length) {
      // A dynamic school with no host yet learns the one the request brings.
      return { id: same, name: S.get(same).name, isNew: false, ...(reqHost && S.isDynamic(same) ? { fillHost: reqHost } : {}) };
    }
  }
  if (!SCHOOL_ID_RE.test(slug) || RESERVED_IDS.includes(slug)) return { error: "bad_school" };
  let id = slug;
  for (let n = 2; S.has(id) || RESERVED_IDS.includes(id); n++) {
    const suffix = `-${n}`;
    id = slug.slice(0, 24 - suffix.length).replace(/-+$/g, "") + suffix;
  }
  const useHost = host && isAllowlistedHost(host) ? host : null; // an owned one returned above
  return { id, name, host: useHost, isNew: true };
}
