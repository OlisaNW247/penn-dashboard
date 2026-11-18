// Ambassador system routes. Returns null for anything it does not own so the
// legacy tracker handles it. Nothing here changes existing routes or counters.
//
// Two ids per ambassador. The secret token opens everything private; the
// public ref is the only thing that is ever posted or printed.
//   /a/{token}                  ambassador's private page (404 once status is left)
//   /a/{token}/stickers         printable QR sheet of their poster codes
//   /a/{token}/me.json          their own numbers
//   /a/{token}/plan.json        the app's plan
//   POST /a/{token}/drop|post|check|feedback|pause|idea|capture
//   /a/_fonts/{name}.woff2      the page fonts, served from here (no third-party host)
//   /r/{ref}/s/{channel}        PUBLIC share link (group chat, fizz, ...) → App Store
//   /r/{ref}/p/{design}         PUBLIC poster/sticker code → App Store
//                               (also increments the school/design counter)
//                               both keep working after the ambassador leaves
//   /f/{FOUNDER_TOKEN}          founder view (+ POST add|update|reminder|replied|feedback-seen|idea-seen|idea-delete|
//                               suggest|suggest-delete|capture-seen|capture-delete)
//   /f/{FOUNDER_TOKEN}/idea/{id}  a poster idea's image bytes (founders only)
//   /f/{FOUNDER_TOKEN}/capture/{id}  a capture's image bytes (founders only)
//   /f/{FOUNDER_TOKEN}/export.json
//   /api/leaderboard            public, school level only

import qrcode from "qrcode-generator";
import { CHANNELS, SCHOOLS, designsFor, isValidCombo, posterName, scanKey } from "./catalog.js";
import { fontResponse } from "./fonts.js";
import messages from "./templates/messages.json";
import checklist from "./templates/checklist.json";
import playbook from "./templates/playbook.json";
import { ambassadorLinks } from "./digest.js";
import { html } from "./html.js";
import {
  ambassadorByToken,
  ambassadorByRef,
  ambassadorStats,
  createAmbassador,
  updateAmbassador,
  recordHit,
  logActivity,
  setChecklist,
  addFeedback,
  schoolLeaderboard,
  founderStats,
  dailyPost,
  dayIndex,
  recordReminder,
  markReplied,
  markFeedbackSeen,
  IDEA_DAILY_LIMIT,
  IDEA_TOTAL_LIMIT,
  FEED_FRAMES_PER_RECORDING,
  FEED_DAILY_LIMIT,
  FEED_TOTAL_LIMIT,
  FEED_FRAME_BYTES,
  RESULT_DAILY_LIMIT,
  RESULT_TOTAL_LIMIT,
  RESULT_IMAGE_BYTES,
  addFeedFrame,
  addResult,
  captureCounts,
  captureImage,
  markCaptureSeen,
  deleteCapture,
  addSuggestion,
  ambassadorExists,
  deleteSuggestion,
  suggestionsFor,
  addIdea,
  deleteIdea,
  ideaCounts,
  ideaImage,
  markIdeaSeen,
  schoolDesignScans,
} from "./data.js";
import { recordScan, appStoreRedirect, notFound } from "./legacy.js";
import { ambassadorPage, stickersPage, founderPage } from "./pages.js";

function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

function origin(request, env) {
  return env.PUBLIC_ORIGIN || new URL(request.url).origin;
}

function wantsJSON(request) {
  const accept = request.headers.get("accept") || "";
  const ct = request.headers.get("content-type") || "";
  return accept.includes("application/json") || ct.includes("application/json");
}

// Forms get a redirect back to the page; the app gets JSON.
function redirectBack(path, flash, request) {
  if (request && wantsJSON(request)) return Response.json({ ok: true, message: flash || null });
  const u = new URL(path, "https://x");
  if (flash) u.searchParams.set("ok", flash);
  return new Response(null, { status: 303, headers: { location: u.pathname + u.search } });
}

// What the app shows: the ambassador's own numbers, today's post with their
// link in it, the checklist, the tips. Never anyone else's data.
async function planPayload(env, amb, url, pub) {
  const stats = await ambassadorStats(env, amb);
  const ideas = await ideaCounts(env, amb);
  const caps = await captureCounts(env, amb);
  const suggested = await suggestionsFor(env, amb.id);
  const designScans = await schoolDesignScans(env, amb.school);
  const links = ambassadorLinks(pub, amb);
  const anonParam = url.searchParams.get("anon");
  const anonApp = ANON_APPS.includes(anonParam) ? anonParam : "fizz";
  const tzParsed = parseInt(url.searchParams.get("tz") || "", 10);
  const tz = Number.isFinite(tzParsed) ? Math.max(-840, Math.min(840, tzParsed)) : 300;
  const idx = dayIndex(new Date(), tz);
  const school = SCHOOLS[amb.school];
  const fill = (t, ch) => t.replace(/\{(\w+)\}/g, (_, k) =>
    ({ link: ch ? links.share(ch) : links.page, school: school.name.toLowerCase(), name: amb.name.split(/\s+/)[0] })[k] ?? `{${k}}`);
  const today = dailyPost({ daily: messages.daily, dayIndex: idx, anonApp });
  const paused = amb.paused_until && new Date(amb.paused_until) > new Date();
  return {
    name: amb.name,
    school: amb.school,
    schoolName: school.name,
    title: amb.title,
    status: amb.status,
    pausedUntil: paused ? amb.paused_until : null,
    page: links.page,
    appStore: "https://apps.apple.com/us/app/smooth-for-students/id6783911002",
    numbers: {
      linkOpens: stats.linkOpens + stats.posterOpens,
      linkOpensRecent: stats.linkOpensRecent + stats.posterOpensRecent,
      schoolScans: stats.schoolScansTotal,
      schoolScansRecent: stats.schoolScansRecent,
      drops: stats.drops,
      posts: stats.posts,
      days: stats.days,
    },
    today: today && {
      dayIndex: idx,
      kind: today.kind,
      channel: today.channel,
      platform: today.platform,
      text: fill(today.text, today.channel),
    },
    messages: messages.messages.map((m) => ({ key: m.key, label: m.label, channel: m.channel, text: fill(m.text, m.channel) })),
    checklist: checklist.steps.map((s) => ({ key: s.key, label: s.label, hint: s.hint, done: stats.checked.has(s.key) })),
    tips: messages.posting_tips,
    channels: CHANNELS,
    generatedAt: new Date().toISOString(),
    // Added 2026-11-11, additive: the app ignores keys it does not know.
    posters: designsFor(amb.school).map((key) => ({
      key,
      name: posterName(key),
      image: `${pub}/posters/${amb.school}/${key}.jpg`,
      scans: designScans[scanKey(amb.school, key)] ?? 0,
    })),
    dashboard: `${pub}/?school=${amb.school}`,
    ideas: { sent: ideas.total, limit: IDEA_TOTAL_LIMIT, dailyLimit: IDEA_DAILY_LIMIT },
    // Added 2026-11-18, additive: what works, posts a founder wants this
    // ambassador to try (only theirs), and the capture uploads' limits.
    playbook: { lead: playbook.lead, steps: playbook.steps, examples: playbook.examples },
    suggested: suggested.map((x) => ({ id: x.id, text: x.text, reply: x.reply, ts: x.ts })),
    captures: capturesPlan(caps),
  };
}

export const CAPTURE_STYLES = [
  { key: "question", label: "question" },
  { key: "list", label: "slipped into a list" },
  { key: "pitch", label: "straight pitch" },
  { key: "other", label: "something else" },
];

function capturesPlan(c) {
  return {
    feed: {
      framesPerRecording: FEED_FRAMES_PER_RECORDING,
      frameBytes: FEED_FRAME_BYTES,
      sentToday: c.feed.today,
      dailyLimit: FEED_DAILY_LIMIT,
      stored: c.feed.total,
      limit: FEED_TOTAL_LIMIT,
    },
    results: {
      imageBytes: RESULT_IMAGE_BYTES,
      sentToday: c.result.today,
      dailyLimit: RESULT_DAILY_LIMIT,
      stored: c.result.total,
      limit: RESULT_TOTAL_LIMIT,
    },
    styles: CAPTURE_STYLES,
  };
}

// Bodies. Everything the pages and the app send is a few short strings, so
// anything big, malformed or oddly shaped is the caller's mistake: a clean
// 4xx, never a 500 and never a row written from garbage.
const MAX_BODY = 16384;
const ANON_APPS = ["fizz", "sidechat", "yikyak"];

const badRequest = () => new Response("bad request", { status: 400, headers: { "content-type": "text/plain;charset=UTF-8" } });
const tooLarge = () => new Response("payload too large", { status: 413, headers: { "content-type": "text/plain;charset=UTF-8" } });

// Returns { f } with every value coerced to a trimmed string (only strings,
// numbers and booleans survive; objects and arrays are treated as missing),
// or { error } holding the Response to send. The null prototype keeps a
// "__proto__" key from meaning anything.
// Reads a body as text, giving up as soon as it passes `maxBytes`. A body sent
// in chunks declares no length, so the content-length check in form() never
// sees it, and request.text() would buffer whatever arrived, megabytes of it,
// before the size was looked at. Returns null for "too large". The byte cap is
// twice the character cap because a character can take more than one byte.
async function readCapped(request, maxBytes) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      try {
        await reader.cancel();
      } catch {
        // already closed: nothing to release
      }
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

async function form(request, max = MAX_BODY) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return { error: tooLarge() };
  let text;
  try {
    text = await readCapped(request, max * 2);
  } catch {
    return { error: badRequest() };
  }
  if (text === null || text.length > max) return { error: tooLarge() };
  if (!text.trim()) return { error: badRequest() };
  const ct = (request.headers.get("content-type") || "").toLowerCase();
  const raw = Object.create(null);
  if (ct.includes("application/json")) {
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      return { error: badRequest() };
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) return { error: badRequest() };
    for (const k of Object.keys(data)) raw[k] = data[k];
  } else if (ct.includes("application/x-www-form-urlencoded")) {
    for (const [k, v] of new URLSearchParams(text)) raw[k] = v;
  } else if (ct.includes("multipart/form-data")) {
    try {
      const fd = await new Response(text, { headers: { "content-type": ct } }).formData();
      for (const [k, v] of fd.entries()) raw[k] = v;
    } catch {
      return { error: badRequest() };
    }
  } else {
    return { error: badRequest() };
  }
  const f = Object.create(null);
  // The untrimmed values, for the one place that must not forgive stray
  // whitespace: a founder action's ids (see rawId). Ordinary text fields keep
  // reading the trimmed `f`.
  const rawValues = Object.create(null);
  for (const k of Object.keys(raw)) {
    const v = raw[k];
    if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") {
      f[k] = String(v).trim().slice(0, max);
      rawValues[k] = String(v).slice(0, max);
    }
  }
  return { f, rawValues };
}

// An id is digits and nothing else, checked against the value as it was sent:
// form() trims every value, so a trimmed "1 " would pass as the id 1 and act on
// row 1. 0 means "not a valid id". The wrong fix is trimming less in form(),
// which every text field relies on.
const ID_PATTERN = /^[1-9][0-9]{0,9}$/;
function rawId(rawValues, key) {
  const v = rawValues[key];
  return typeof v === "string" && ID_PATTERN.test(v) ? Number(v) : 0;
}

// A field as a trimmed string capped at `max`, or "" when missing.
function field(f, key, max = 200) {
  const v = f[key];
  return typeof v === "string" ? v.slice(0, max) : "";
}

// An integer field clamped to [lo, hi]; `dflt` when missing or not a number.
function intField(f, key, lo, hi, dflt) {
  const n = parseInt(field(f, key, 40), 10);
  return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : dflt;
}

// ---- poster ideas. This one route takes a larger body than the rest because an
// image rides in it as base64: 600,000 bytes decoded is 800,000 characters.
const IDEA_BODY_MAX = 900000;
const IDEA_IMAGE_MAX_BYTES = 600000;
const IDEA_NOTE_MAX = 500;

// The type comes from the bytes and never from what the client said it was, so
// a file named .jpg that is really SVG or HTML is refused. `head` holds the
// first 12 decoded bytes.
function sniffImage(head) {
  const at = (i, ...b) => b.every((v, k) => head[i + k] === v);
  if (at(0, 0xff, 0xd8, 0xff)) return "image/jpeg";
  if (at(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return "image/png";
  if (at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) return "image/webp";
  return null;
}

// JSON for the app and the page's script, plain text for anything else.
function ideaError(request, status, message) {
  if (wantsJSON(request)) return Response.json({ ok: false, message }, { status });
  return new Response(message, { status, headers: { "content-type": "text/plain;charset=UTF-8" } });
}

async function handleIdea(request, env, amb, base) {
  const parsed = await form(request, IDEA_BODY_MAX);
  if (parsed.error) {
    const status = parsed.error.status;
    return ideaError(request, status, status === 413 ? "that is too big. try a smaller image." : "bad request");
  }
  const f = parsed.f;
  const note = field(f, "note", IDEA_NOTE_MAX * 4).trim().slice(0, IDEA_NOTE_MAX);
  let image = field(f, "image", IDEA_BODY_MAX);
  image = image.replace(/^data:[^,]{0,100};base64,/i, "").replace(/\s+/g, "");
  if (!note && !image) return ideaError(request, 400, "add a picture or a note.");

  let mime = null;
  if (image) {
    // One regex for the whole payload, and only the first 16 characters are decoded.
    if (image.length < 16 || image.length % 4 === 1 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image)) {
      return ideaError(request, 400, "that isn't a picture we can use. jpeg, png or webp.");
    }
    const pad = image.endsWith("==") ? 2 : image.endsWith("=") ? 1 : 0;
    const bytes = Math.floor((image.length * 3) / 4) - pad;
    if (bytes > IDEA_IMAGE_MAX_BYTES) return ideaError(request, 413, "that is too big. try a smaller image.");
    let head;
    try {
      const bin = atob(image.slice(0, 16));
      head = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    } catch {
      return ideaError(request, 400, "that isn't a picture we can use. jpeg, png or webp.");
    }
    mime = sniffImage(head);
    if (!mime) return ideaError(request, 400, "that isn't a picture we can use. jpeg, png or webp.");
  }

  const counts = await ideaCounts(env, amb);
  if (counts.today >= IDEA_DAILY_LIMIT) return ideaError(request, 429, `that's ${IDEA_DAILY_LIMIT} for today. try again tomorrow.`);
  if (counts.total >= IDEA_TOTAL_LIMIT) return ideaError(request, 429, `we're holding ${IDEA_TOTAL_LIMIT} of yours already. thank you.`);

  // The counts above only choose the right words for the common case. This
  // insert is what enforces the limits (see addIdea): if it wrote nothing,
  // another request got there first.
  const stored = await addIdea(env, amb, { note, mime, image: image || null });
  if (!stored) return ideaError(request, 429, `that's ${IDEA_DAILY_LIMIT} for today. try again tomorrow.`);
  return redirectBack(base + "#idea", "sent. thank you.", request);
}

// ---- captures. Same body cap as an idea (an image rides in it as base64), same
// rule that the bytes decide the type. Two kinds, one route.
const CAPTURE_PLATFORMS = ["fizz", "sidechat", "yikyak", "other"];
const CAPTURE_NOTE_MAX = 300;
const FULL_MESSAGE = "we're full right now. tell olisa or marco.";
const COUNT_MAX = 10000000;

// Decodes nothing but the first 16 characters. `maxBytes` is the decoded size
// the caller allows. Returns { mime, image } or { response }.
function checkCaptureImage(request, raw, maxBytes) {
  const bad = () => ({ response: ideaError(request, 400, "that isn't a picture we can use. jpeg, png or webp.") });
  const image = raw.replace(/^data:[^,]{0,100};base64,/i, "").replace(/\s+/g, "");
  if (!image) return { response: ideaError(request, 400, "add a picture.") };
  if (image.length < 16 || image.length % 4 === 1 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image)) return bad();
  const pad = image.endsWith("==") ? 2 : image.endsWith("=") ? 1 : 0;
  if (Math.floor((image.length * 3) / 4) - pad > maxBytes) return { response: ideaError(request, 413, "that is too big. try a smaller image.") };
  let head;
  try {
    head = Uint8Array.from(atob(image.slice(0, 16)), (c) => c.charCodeAt(0));
  } catch {
    return bad();
  }
  const mime = sniffImage(head);
  return mime ? { mime, image } : bad();
}

// A count the ambassador typed: digits only, in range, else null (stored NULL).
function countField(f, key) {
  // "1,200" and "1 200" are how people write a thousand: strip commas and spaces
  // first. "1.2k", "12.5", "-5" and "1e3" are not digits and stay NULL.
  const t = field(f, key, 20).replace(/[,\s]/g, "");
  if (!/^\d{1,8}$/.test(t)) return null;
  const n = Number(t);
  return n <= COUNT_MAX ? n : null;
}

async function handleCapture(request, env, amb, base) {
  const parsed = await form(request, IDEA_BODY_MAX);
  if (parsed.error) {
    const status = parsed.error.status;
    return ideaError(request, status, status === 413 ? "that is too big. try a smaller image." : "bad request");
  }
  const f = parsed.f;
  const kind = field(f, "kind", 20);
  if (kind !== "feed" && kind !== "result") return ideaError(request, 400, "bad request");
  const checked = checkCaptureImage(request, field(f, "image", IDEA_BODY_MAX), kind === "feed" ? FEED_FRAME_BYTES : RESULT_IMAGE_BYTES);
  if (checked.response) return checked.response;
  const { mime, image } = checked;

  if (kind === "feed") {
    const batch = field(f, "batch", 64);
    const seqText = field(f, "seq", 10);
    if (!/^[a-z0-9]{8,32}$/.test(batch) || !/^\d{1,2}$/.test(seqText) || Number(seqText) >= FEED_FRAMES_PER_RECORDING) {
      return ideaError(request, 400, "bad request");
    }
    // The limits live inside the insert (see addFeedFrame). If it wrote nothing,
    // either this frame is already held, which is a retry and answers 200, or a
    // limit was reached.
    const outcome = await addFeedFrame(env, amb, { batch, seq: Number(seqText), mime, image });
    if (outcome === "full") return ideaError(request, 429, FULL_MESSAGE);
    if (outcome === "limit") return ideaError(request, 429, "that's all we can hold for now. thank you.");
    return redirectBack(base + "#feed", "sent.", request);
  }

  const platformText = field(f, "platform", 20).toLowerCase();
  const styleText = field(f, "style", 20).toLowerCase();
  const outcome = await addResult(env, amb, {
    platform: CAPTURE_PLATFORMS.includes(platformText) ? platformText : "other",
    style: CAPTURE_STYLES.some((s) => s.key === styleText) ? styleText : "other",
    upvotes: countField(f, "upvotes"),
    views: countField(f, "views"),
    note: field(f, "note", CAPTURE_NOTE_MAX * 4).trim().slice(0, CAPTURE_NOTE_MAX),
    mime,
    image,
  });
  if (outcome === "full") return ideaError(request, 429, FULL_MESSAGE);
  if (outcome !== "stored") return ideaError(request, 429, "that's all we can hold for now. thank you.");
  return redirectBack(base + "#result", "sent.", request);
}

function decodeBase64(b64) {
  if (typeof Uint8Array.fromBase64 === "function") return Uint8Array.fromBase64(b64);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function qrSvg(text) {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  return qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true }).replace("<svg ", '<svg class="qr" ');
}

export async function handleAmbassadors(request, env, ctx) {
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length === 0) return null;

  if (url.pathname === "/api/leaderboard") {
    const days = Math.min(90, Math.max(1, parseInt(url.searchParams.get("days") || "14", 10) || 14));
    return Response.json(await schoolLeaderboard(env, days), {
      headers: { "access-control-allow-origin": "*", "cache-control": "public, max-age=60" },
    });
  }

  if (parts[0] === "a") return ambassadorRoutes(request, env, parts.slice(1), url);
  if (parts[0] === "f") return founderRoutes(request, env, parts.slice(1), url);
  if (parts[0] === "r") return publicRoutes(request, env, parts.slice(1));
  return null;
}

// The public links: /r/{ref}/s/{channel} and /r/{ref}/p/{design}. They sit in
// posts and on printed stickers, so they take only GET, open nothing private,
// and keep redirecting (and counting for the school) after an ambassador
// leaves. A departed ambassador is just no longer credited.
async function publicRoutes(request, env, parts) {
  if (request.method !== "GET") return new Response("method not allowed", { status: 405 });
  const [ref, action, arg, extra] = parts;
  if (!action || !arg || extra !== undefined) return notFound();
  const amb = await ambassadorByRef(env, ref);
  if (!amb) return notFound();
  const credited = amb.status !== "left";
  if (action === "s") {
    const channel = Object.hasOwn(CHANNELS, arg) ? arg : "other";
    if (credited) {
      await recordHit(env, amb, "link", channel);
      if (amb.status === "invited") await updateAmbassador(env, amb.id, { status: "active" });
    }
    return appStoreRedirect(env, `${amb.school}-${amb.id}-${channel}`);
  }
  if (action === "p") {
    if (!isValidCombo(amb.school, arg)) return notFound();
    const key = scanKey(amb.school, arg);
    // Counts for the school always, and for the ambassador while they are one.
    await recordScan(env, key, credited ? amb.id : null);
    if (credited) await recordHit(env, amb, "poster", arg);
    return appStoreRedirect(env, `${key.replace("/", "-")}-a${amb.id}`);
  }
  return notFound();
}

const AMBASSADOR_POSTS = ["drop", "post", "check", "feedback", "pause", "idea", "capture"];

async function ambassadorRoutes(request, env, parts, url) {
  const [token, action, arg] = parts;
  // The fonts are public files that live under /a/ so they sit beside the pages
  // that use them. Handled before the code lookup: "_fonts" is never a code
  // (codes are lowercase letters and digits, with hyphens), and the lookup
  // would cost a query.
  if (token === "_fonts") {
    if (request.method !== "GET") return new Response("method not allowed", { status: 405 });
    return (arg === undefined && fontResponse(action)) || notFound();
  }
  const amb = await ambassadorByToken(env, token);
  // A departed ambassador's code stops working: the founder marking them left
  // is how access is ended.
  if (!amb || amb.status === "left") return notFound();
  const base = `/a/${amb.token}`;
  const pub = origin(request, env);

  if (request.method === "GET") {
    if (arg !== undefined) return notFound();
    if (!action) {
      const [stats, ideas, designScans, caps, suggested] = await Promise.all([
        ambassadorStats(env, amb),
        ideaCounts(env, amb),
        schoolDesignScans(env, amb.school),
        captureCounts(env, amb),
        suggestionsFor(env, amb.id),
      ]);
      return html(ambassadorPage({ amb, stats, ideas, designScans, playbook, suggested, captures: capturesPlan(caps), origin: pub, flash: url.searchParams.get("ok") }));
    }
    if (action === "stickers") return html(stickersPage({ amb, origin: pub, qrSvg }));
    if (action === "plan.json") {
      return Response.json(await planPayload(env, amb, url, pub), { headers: { "cache-control": "no-store" } });
    }
    if (action === "me.json") {
      const s = await ambassadorStats(env, amb);
      return Response.json({ name: amb.name, school: amb.school, ...s, checked: [...s.checked] }, { headers: { "cache-control": "no-store" } });
    }
    return notFound();
  }

  if (request.method === "POST") {
    if (arg !== undefined || !AMBASSADOR_POSTS.includes(action)) return notFound();
    if (action === "idea") return handleIdea(request, env, amb, base);
    if (action === "capture") return handleCapture(request, env, amb, base);
    const parsed = await form(request);
    if (parsed.error) return parsed.error;
    const f = parsed.f;
    switch (action) {
      case "drop": {
        const design = field(f, "design", 40);
        if (!isValidCombo(amb.school, design)) return new Response("bad design", { status: 400 });
        await logActivity(env, amb, { kind: "drop", design, place: field(f, "place", 200), copies: intField(f, "copies", 0, 999, 1) });
        return redirectBack(base + "#drop", "logged. thank you.", request);
      }
      case "post": {
        const channel = field(f, "channel", 40);
        if (!Object.hasOwn(CHANNELS, channel)) return new Response("bad channel", { status: 400 });
        await logActivity(env, amb, { kind: "post", channel, place: field(f, "place", 200), note: field(f, "note", 200) });
        return redirectBack(base + "#drop", "logged. thank you.", request);
      }
      case "check": {
        const step = field(f, "step", 40);
        if (!checklist.steps.some((s) => s.key === step)) return new Response("bad step", { status: 400 });
        const done = field(f, "done", 10);
        await setChecklist(env, amb, step, done === "1" || done === "true");
        return redirectBack(base + "#start", null, request);
      }
      case "feedback": {
        const body = field(f, "body", 2000);
        if (!body) return badRequest();
        await addFeedback(env, amb, body);
        return redirectBack(base + "#feedback", "sent. thank you, seriously.", request);
      }
      case "pause": {
        const weeks = intField(f, "weeks", 0, 12, 0);
        const until = weeks > 0 ? new Date(Date.now() + weeks * 7 * 86400000).toISOString() : "";
        await updateAmbassador(env, amb.id, { paused_until: until });
        return redirectBack(base, weeks > 0 ? `paused for ${weeks} weeks.` : "reminders back on.", request);
      }
    }
  }
  return new Response("method not allowed", { status: 405 });
}

async function founderRoutes(request, env, parts, url) {
  const [secret, action, arg] = parts;
  if (!env.FOUNDER_TOKEN || env.FOUNDER_TOKEN.length < 16 || !safeEqual(secret, env.FOUNDER_TOKEN)) {
    return notFound();
  }
  const base = `/f/${secret}`;
  const pub = origin(request, env);

  if (request.method === "GET") {
    if (action === "idea") {
      // The image bytes, for founders only. Served as an inert, sandboxed file:
      // the type is the sniffed one stored with it, and nothing here can run.
      const id = /^\d{1,10}$/.test(arg || "") ? parseInt(arg, 10) : 0;
      const row = id && parts.length === 3 ? await ideaImage(env, id) : null;
      if (!row) return notFound();
      return new Response(decodeBase64(row.image), {
        headers: {
          "content-type": row.mime,
          "x-content-type-options": "nosniff",
          "cache-control": "private, no-store",
          "content-security-policy": "default-src 'none'; sandbox",
          "content-disposition": "inline",
          "referrer-policy": "no-referrer",
        },
      });
    }
    if (action === "capture") {
      // Same inert, sandboxed delivery as an idea's image. The route lives under
      // the founder secret only: an ambassador's code opens none of /f/.
      const id = ID_PATTERN.test(arg || "") ? Number(arg) : 0;
      const row = id && parts.length === 3 ? await captureImage(env, id) : null;
      if (!row) return notFound();
      return new Response(decodeBase64(row.image), {
        headers: {
          "content-type": row.mime,
          "x-content-type-options": "nosniff",
          "cache-control": "private, no-store",
          "content-security-policy": "default-src 'none'; sandbox",
          "content-disposition": "inline",
          "referrer-policy": "no-referrer",
        },
      });
    }
    if (arg !== undefined) return notFound();
    if (!action) {
      const days = Math.min(90, Math.max(1, parseInt(url.searchParams.get("days") || "14", 10) || 14));
      const stats = await founderStats(env, days);
      let created = null;
      if (url.searchParams.get("created")) created = await ambassadorByToken(env, url.searchParams.get("created"));
      return html(founderPage({ stats, origin: pub, secret, flash: url.searchParams.get("ok"), created }));
    }
    if (action === "export.json") {
      const stats = await founderStats(env, 365);
      return Response.json(stats, { headers: { "cache-control": "no-store" } });
    }
    return notFound();
  }

  if (request.method === "POST") {
    if (!["add", "update", "reminder", "replied", "feedback-seen", "idea-seen", "idea-delete", "suggest", "suggest-delete", "capture-seen", "capture-delete"].includes(action)) return notFound();
    const parsed = await form(request);
    if (parsed.error) return parsed.error;
    const f = parsed.f;
    // An id is digits and nothing else. parseInt would read "1e3" and "0x10"
    // as 1 and 0, and a clamp would turn "-1" into 1, so a mistyped or hostile
    // id would quietly act on the first row: for idea-delete, the wrong idea.
    const id = rawId(parsed.rawValues, "id");
    // capture-seen and capture-delete take either one row's id or a whole
    // recording as (amb, batch), both held to the same strict rule.
    const ambId = rawId(parsed.rawValues, "amb");
    const batch = field(f, "batch", 64);
    const batchOk = /^[a-z0-9]{8,32}$/.test(batch);
    const captureTarget = id ? { id } : ambId && batchOk ? { amb: ambId, batch } : null;
    if (action === "capture-seen" || action === "capture-delete") {
      if (!captureTarget) return badRequest();
    } else if (action !== "add" && !id) return badRequest();
    switch (action) {
      case "add": {
        try {
          const amb = await createAmbassador(env, f);
          return new Response(null, { status: 303, headers: { location: `${base}?created=${amb.token}` } });
        } catch (e) {
          return new Response(String(e.message), { status: 400 });
        }
      }
      case "update":
        await updateAmbassador(env, id, f);
        return redirectBack(base + "#roster", "saved.");
      case "reminder":
        await recordReminder(env, id, field(f, "kind", 40) || "digest");
        return redirectBack(base + "#digest", "marked sent.");
      case "replied":
        await markReplied(env, id);
        return redirectBack(base + "#roster", "noted.");
      case "feedback-seen":
        await markFeedbackSeen(env, id);
        return redirectBack(base + "#feedback");
      case "idea-seen":
        await markIdeaSeen(env, id);
        return redirectBack(base + "#ideas");
      case "idea-delete":
        await deleteIdea(env, id);
        return redirectBack(base + "#ideas", "deleted.");
      case "capture-seen":
        await markCaptureSeen(env, captureTarget);
        return redirectBack(base + "#feeds");
      case "capture-delete":
        await deleteCapture(env, captureTarget);
        return redirectBack(base + "#feeds", "deleted.");
      case "suggest": {
        const text = field(f, "text", 2400).trim();
        if (!text || text.length > 600) return ideaError(request, 400, "the post should be 1 to 600 characters.");
        const reply = field(f, "reply", 1200).trim().slice(0, 300);
        // At most 20 per ambassador, enforced inside the insert (addSuggestion).
        if (!(await addSuggestion(env, id, { text, reply }))) {
          return (await ambassadorExists(env, id))
            ? ideaError(request, 429, "that ambassador already has 20 to try. delete one first.")
            : ideaError(request, 404, "no such ambassador.");
        }
        return redirectBack(base + "#feeds", "sent.");
      }
      case "suggest-delete":
        await deleteSuggestion(env, id);
        return redirectBack(base + "#roster", "deleted.");
      default:
        return notFound();
    }
  }
  return new Response("method not allowed", { status: 405 });
}
