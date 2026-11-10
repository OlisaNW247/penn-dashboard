/* global SMOOTH_HOST */
// In the hosting platform's build the real tracker is a single file that already
// owns the list of schools and posters (`posters`, `schools`, `counterKey`). The
// ambassador code must read that one list, not a second copy that could drift, so
// this module stands in for worker/catalog.js there: same exports, derived from
// SMOOTH_HOST, which the host file defines (see scripts/build-sites.mjs).
// The three helpers that do not depend on the lists are re-exported unchanged;
// the build's alias only applies to imports made from worker/, so this import
// reaches the real catalog.

export { CHANNELS, parseScanKey, posterImagePath } from "../worker/catalog.js";

export const APP_STORE_URL = SMOOTH_HOST.appStore;

export const SCHOOLS = Object.fromEntries(
  [...SMOOTH_HOST.schools].map(([id, name]) => [id, id === "upenn" ? { name, legacy: true } : { name }]),
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

export function isValidCombo(school, poster) {
  return designsFor(school).includes(poster);
}

export const scanKey = SMOOTH_HOST.counterKey;
