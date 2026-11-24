/* global SMOOTH_HOST */
// In the hosting platform's build the real tracker is a single file that already
// owns the list of schools and posters (`posters`, `schools`, `counterKey`). The
// ambassador code must read that one list, not a second copy that could drift, so
// this module stands in for worker/catalog.js there: same exports, derived from
// SMOOTH_HOST, which the host file defines (see scripts/build-sites.mjs).
// The three helpers that do not depend on the lists are re-exported unchanged;
// the build's alias only applies to imports made from worker/, so this import
// reaches the real catalog.

export { CHANNELS, GENERIC, RETIRED, parseScanKey, posterImagePath } from "../worker/catalog.js";
import { SCHOOLS as SOURCE_SCHOOLS, RETIRED } from "../worker/catalog.js";

export const APP_STORE_URL = SMOOTH_HOST.appStore;

// canvasHosts (the install count's host-to-school map) is not something the host
// file knows, so it is read from the source catalog by school id; a school the
// host has and the catalog lacks simply has none.
export const SCHOOLS = Object.fromEntries(
  [...SMOOTH_HOST.schools].map(([id, name]) => [
    id,
    { name, ...(id === "upenn" ? { legacy: true } : {}), ...(SOURCE_SCHOOLS[id]?.canvasHosts ? { canvasHosts: SOURCE_SCHOOLS[id].canvasHosts } : {}) },
  ]),
);

export const UPENN_ONLY = [...SMOOTH_HOST.upennOnly];

export const DESIGNS = [...SMOOTH_HOST.posters.keys()].filter((k) => !UPENN_ONLY.includes(k));

export const POSTER_NAMES = Object.fromEntries(SMOOTH_HOST.posters);

export function posterName(poster) {
  return POSTER_NAMES[poster] ?? poster;
}

export function designsFor(school) {
  if (!SMOOTH_HOST.schools.has(school)) return [];
  return [...SMOOTH_HOST.posters.keys()].filter((k) => school === "upenn" || !UPENN_ONLY.includes(k));
}

// Retired designs are a fixed list in the real catalog, so it is the same
// list here; the host Map keeps them because printed codes still scan.
export function offeredDesignsFor(school) {
  return designsFor(school).filter((d) => !RETIRED.includes(d));
}

export function isValidCombo(school, poster) {
  return designsFor(school).includes(poster);
}

export const scanKey = SMOOTH_HOST.counterKey;
