// Ambassador system routes. Returns null for anything it does not own so the
// legacy tracker handles it. Nothing here changes existing routes or counters.
//
// Two ids per ambassador. The secret token opens everything private; the
// public ref is the only thing that is ever posted or printed.
//   /a/{token}                  ambassador's private page (404 once status is left)
//   /a/{token}/stickers         printable QR sheet of their poster codes
//   /a/{token}/me.json          their own numbers
//   /a/{token}/plan.json        the app's plan
//   POST /a/{token}/drop|post|check|feedback|pause|idea
//   /a/_fonts/{name}.woff2      the page fonts, served from here (no third-party host)
//   /r/{ref}/s/{channel}        PUBLIC share link (group chat, fizz, ...) → App Store
//   /r/{ref}/p/{design}         PUBLIC poster/sticker code → App Store
//                               (also increments the school/design counter)
//                               both keep working after the ambassador leaves
//   /f/{FOUNDER_TOKEN}          founder view (+ POST add|update|reminder|replied|feedback-seen|idea-seen|idea-delete)
//   /f/{FOUNDER_TOKEN}/idea/{id}  a poster idea's image bytes (founders only)
//   /f/{FOUNDER_TOKEN}/export.json
//   /api/leaderboard            public, school level only

import qrcode from "qrcode-generator";
import { CHANNELS, SCHOOLS, designsFor, isValidCombo, posterName, scanKey } from "./catalog.js";
import { fontResponse } from "./fonts.js";
import messages from "./templates/messages.json";
import checklist from "./templates/checklist.json";
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
async function form(request, max = MAX_BODY) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return { error: tooLarge() };
  let text;
  try {
    text = await request.text();
  } catch {
    return { error: badRequest() };
  }
  if (text.length > max) return { error: tooLarge() };
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
  for (const k of Object.keys(raw)) {
    const v = raw[k];
    if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") f[k] = String(v).trim().slice(0, max);
  }
  return { f };
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

  await addIdea(env, amb, { note, mime, image: image || null });
  return redirectBack(base + "#idea", "sent. thank you.", request);
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

const AMBASSADOR_POSTS = ["drop", "post", "check", "feedback", "pause", "idea"];

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
      const [stats, ideas, designScans] = await Promise.all([
        ambassadorStats(env, amb),
        ideaCounts(env, amb),
        schoolDesignScans(env, amb.school),
      ]);
      return html(ambassadorPage({ amb, stats, ideas, designScans, origin: pub, flash: url.searchParams.get("ok") }));
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
    if (!["add", "update", "reminder", "replied", "feedback-seen", "idea-seen", "idea-delete"].includes(action)) return notFound();
    const parsed = await form(request);
    if (parsed.error) return parsed.error;
    const f = parsed.f;
    const id = intField(f, "id", 1, 2 ** 31, 0);
    if (action !== "add" && !id) return badRequest();
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
      default:
        return notFound();
    }
  }
  return new Response("method not allowed", { status: 405 });
}
