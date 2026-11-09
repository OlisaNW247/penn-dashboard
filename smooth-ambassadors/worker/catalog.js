// Schools and poster designs. Mirrors what the live tracker already knows.
// Keys here are the D1 `scans.poster` keys printed into QR codes, so they
// must never change. Adding a school or design is fine; renaming is not.

export const APP_STORE_URL =
  "https://apps.apple.com/us/app/smooth-for-students/id6783911002";

export const SCHOOLS = {
  upenn: { name: "UPenn", legacy: true },
  umiami: { name: "UMiami" },
  uva: { name: "UVA" },
  "case-western": { name: "Case Western" },
  clark: { name: "Clark University" },
};

// Designs available at every school.
export const DESIGNS = [
  "ib",
  "kylie",
  "compute",
  "these-two",
  "soccer",
  "grind",
  "ai-end",
  "smoother",
  "tabard",
  "taylor",
  "venture",
  "best-actor",
];

// UPenn-only designs.
export const UPENN_ONLY = ["jester", "regista"];

export function designsFor(school) {
  if (!SCHOOLS[school]) return [];
  return school === "upenn" ? [...DESIGNS, ...UPENN_ONLY] : [...DESIGNS];
}

export function isValidCombo(school, poster) {
  return designsFor(school).includes(poster);
}

// The D1 `scans.poster` key for a school + design.
// UPenn keeps its legacy bare keys (`ib`), every other school is prefixed.
export function scanKey(school, poster) {
  return school === "upenn" ? poster : `${school}/${poster}`;
}

export function parseScanKey(key) {
  const i = key.indexOf("/");
  if (i === -1) return { school: "upenn", poster: key };
  return { school: key.slice(0, i), poster: key.slice(i + 1) };
}

export function posterImagePath(school, poster) {
  return `/posters/${school}/${poster}.jpg`;
}

// Channels an ambassador can share a link in. Each gets its own tracked link.
export const CHANNELS = {
  gc: "group chat",
  fizz: "fizz",
  sidechat: "sidechat",
  yikyak: "yik yak",
  ig: "instagram story",
  dm: "dm",
  other: "other",
};
