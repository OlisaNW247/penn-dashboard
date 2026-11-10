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

// Designs available at every school, in the order the live /api/stats lists
// them (read off the live site 2026-11-10). The order is part of what the
// public dashboard shows, so it is kept.
export const DESIGNS = [
  "best-actor",
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
];

// UPenn-only designs. On the live site they sit right after best-actor.
export const UPENN_ONLY = ["regista", "jester"];

// Display names, exactly as the live dashboard shows them.
export const POSTER_NAMES = {
  "best-actor": "Vote Here for Best Actor",
  regista: "The Regista",
  jester: "The Jester",
  ib: "Funneled into IB",
  kylie: "Kylie Jenner",
  compute: "More Compute",
  "these-two": "Have You Seen These Two?",
  soccer: "That Was Pretty Smooth \u2014 Soccer",
  grind: "Tired of the Grind?",
  "ai-end": "AI Might Be the End",
  smoother: "What If We Made It Smoother",
  tabard: "Tabard Rush List",
  taylor: "Taylor Swift Wedding",
  venture: "Venture Backed \u2014 $300M",
};

export function posterName(poster) {
  return POSTER_NAMES[poster] ?? poster;
}

export function designsFor(school) {
  if (!SCHOOLS[school]) return [];
  if (school !== "upenn") return [...DESIGNS];
  return [DESIGNS[0], ...UPENN_ONLY, ...DESIGNS.slice(1)];
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
