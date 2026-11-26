// Schools and poster designs. Mirrors what the live tracker already knows.
// Keys here are the D1 `scans.poster` keys printed into QR codes, so they
// must never change. Adding a school or design is fine; renaming is not.

export const APP_STORE_URL =
  "https://apps.apple.com/us/app/smooth-for-students/id6783911002";

export const SCHOOLS = {
  // canvasHosts: the Canvas hosts the app's own school catalog lists for the
  // school (CanvasSchoolCatalogData.swift), used to turn an install count's host
  // into a school. Left out when unsure rather than guessed.
  upenn: { name: "UPenn", legacy: true, canvasHosts: ["canvas.upenn.edu"] },
  umiami: { name: "UMiami", canvasHosts: ["miami.instructure.com"] },
  uva: { name: "UVA", canvasHosts: ["canvas.its.virginia.edu"] },
  "case-western": { name: "Case Western", canvasHosts: ["case.instructure.com"] },
  clark: { name: "Clark University", canvasHosts: ["canvas.clarku.edu"] },
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
  // The five generic designs of 2026-11-22 (Marco: "make more generic ones.
  // right now they're not very good"), approved from the renders the same
  // day. Appended, never inserted, so the rows above keep their live order.
  // Their previews are posters/previews/{key}.jpg (sources in posters/src),
  // and scripts/build-sites.mjs embeds them into the live Worker's own
  // image dictionary at the next deploy; until then the live site does not
  // know them (fetch-posters.mjs falls back to the repo's file).
  "missed",
  "moved",
  "one-list",
  "sweeper",
  "ask",
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
  missed: "Missed a Deadline?",
  moved: "Your Professor Moved the Deadline",
  "one-list": "One List",
  sweeper: "Ten Minutes. Not Turned In.",
  ask: "Ask Your Classes Anything",
};

// Designs no ambassador is handed any more (2026-11-21, Marco, looking at the
// gallery on his phone: "there are some specific ones to Penn we need to get
// rid of. it mentions Tabard rush list, what does that even mean for a
// non-Penn student? or 'have you seen these two' with a photo of two people
// at Penn"). Retired, not deleted: their keys are printed into QR codes on
// posters already on walls, so `/scan/...` and `/r/{ref}/p/{design}` still
// count them and `/api/stats` still lists them. They only leave what an
// ambassador is offered: the plan's `posters`, the page's gallery and drop
// chips, and the stickers sheet (`offeredDesignsFor`). The rule for the
// rest of the list is "would a UVA or Miami student understand it": a
// celebrity or a finance joke travels, a Penn club or two Penn students does
// not. The UPenn-only designs are a different thing (printed for one school
// on purpose) and stay as they are.
export const RETIRED = ["these-two", "tabard"];

export function posterName(poster) {
  return POSTER_NAMES[poster] ?? poster;
}

// Every design that is valid for a school: the key space of scans, stats and
// stickers already printed. Never shrinks.
export function designsFor(school) {
  if (!SCHOOLS[school]) return [];
  if (school !== "upenn") return [...DESIGNS];
  return [DESIGNS[0], ...UPENN_ONLY, ...DESIGNS.slice(1)];
}

// The designs an ambassador is shown and handed today: `designsFor` minus
// the retired ones. What the plan, the gallery, the drop chips and the
// stickers sheet read.
export function offeredDesignsFor(school) {
  return designsFor(school).filter((d) => !RETIRED.includes(d));
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
