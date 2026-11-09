// Ambassador system routes. Returns null for anything it does not own so the
// legacy tracker handles it. Nothing here changes existing routes or counters.
//
//   /a/{token}                  ambassador's private page
//   /a/{token}/s/{channel}      share link (group chat, fizz, ...) → App Store
//   /a/{token}/p/{design}       ambassador poster code → App Store
//                               (also increments the school/design counter)
//   /a/{token}/stickers         printable QR sheet of their poster codes
//   /a/{token}/me.json          their own numbers
//   POST /a/{token}/drop|post|check|feedback|pause
//   /f/{FOUNDER_TOKEN}          founder view (+ POST add|update|reminder|replied|feedback-seen)
//   /f/{FOUNDER_TOKEN}/export.json
//   /api/leaderboard            public, school level only

import qrcode from "qrcode-generator";
import { CHANNELS, isValidCombo, scanKey } from "./catalog.js";
import { html } from "./html.js";
import {
  ambassadorByToken,
  ambassadorStats,
  createAmbassador,
  updateAmbassador,
  recordHit,
  logActivity,
  setChecklist,
  addFeedback,
  schoolLeaderboard,
  founderStats,
  recordReminder,
  markReplied,
  markFeedbackSeen,
} from "./data.js";
import { recordScan, appStoreRedirect } from "./legacy.js";
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

function redirectBack(path, flash) {
  const u = new URL(path, "https://x");
  if (flash) u.searchParams.set("ok", flash);
  return new Response(null, { status: 303, headers: { location: u.pathname + u.search } });
}

async function form(request) {
  const ct = request.headers.get("content-type") || "";
  if (ct.includes("application/json")) return await request.json();
  const fd = await request.formData();
  return Object.fromEntries(fd.entries());
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

  if (parts[0] === "api" && parts[1] === "leaderboard" && parts.length === 2) {
    const days = Math.min(90, Math.max(1, parseInt(url.searchParams.get("days") || "14", 10) || 14));
    return Response.json(await schoolLeaderboard(env, days), {
      headers: { "access-control-allow-origin": "*", "cache-control": "public, max-age=60" },
    });
  }

  if (parts[0] === "a") return ambassadorRoutes(request, env, parts.slice(1), url);
  if (parts[0] === "f") return founderRoutes(request, env, parts.slice(1), url);
  return null;
}

async function ambassadorRoutes(request, env, parts, url) {
  const [token, action, arg] = parts;
  const amb = await ambassadorByToken(env, token);
  if (!amb) return new Response("not found", { status: 404 });
  const base = `/a/${amb.token}`;
  const pub = origin(request, env);

  if (request.method === "GET") {
    if (!action) {
      const stats = await ambassadorStats(env, amb);
      return html(ambassadorPage({ amb, stats, origin: pub, flash: url.searchParams.get("ok") }));
    }
    if (action === "s" && arg) {
      const channel = CHANNELS[arg] ? arg : "other";
      await recordHit(env, amb, "link", channel);
      if (amb.status === "invited") await updateAmbassador(env, amb.id, { status: "active" });
      return appStoreRedirect(env, `${amb.school}-${amb.id}-${channel}`);
    }
    if (action === "p" && arg) {
      if (!isValidCombo(amb.school, arg)) return new Response("not found", { status: 404 });
      const key = scanKey(amb.school, arg);
      // Counts for the school AND the ambassador.
      await recordScan(env, key, amb.id);
      await recordHit(env, amb, "poster", arg);
      return appStoreRedirect(env, `${key.replace("/", "-")}-a${amb.id}`);
    }
    if (action === "stickers") return html(stickersPage({ amb, origin: pub, qrSvg }));
    if (action === "me.json") {
      const s = await ambassadorStats(env, amb);
      return Response.json({ name: amb.name, school: amb.school, ...s, checked: [...s.checked] }, { headers: { "cache-control": "no-store" } });
    }
    return new Response("not found", { status: 404 });
  }

  if (request.method === "POST") {
    const f = await form(request);
    switch (action) {
      case "drop":
        if (!isValidCombo(amb.school, f.design)) return new Response("bad design", { status: 400 });
        await logActivity(env, amb, { kind: "drop", design: f.design, place: f.place, copies: f.copies });
        return redirectBack(base + "#drop", "logged. thank you.");
      case "post":
        if (!CHANNELS[f.channel]) return new Response("bad channel", { status: 400 });
        await logActivity(env, amb, { kind: "post", channel: f.channel, place: f.place, note: f.note });
        return redirectBack(base + "#drop", "logged. thank you.");
      case "check":
        if (!f.step) return new Response("bad step", { status: 400 });
        await setChecklist(env, amb, String(f.step).slice(0, 40), f.done === "1" || f.done === 1 || f.done === true);
        return redirectBack(base + "#start");
      case "feedback":
        await addFeedback(env, amb, f.body);
        return redirectBack(base + "#feedback", "sent. thank you, seriously.");
      case "pause": {
        const weeks = parseInt(f.weeks, 10) || 0;
        const until = weeks > 0 ? new Date(Date.now() + weeks * 7 * 86400000).toISOString() : "";
        await updateAmbassador(env, amb.id, { paused_until: until });
        return redirectBack(base, weeks > 0 ? `paused for ${weeks} weeks.` : "reminders back on.");
      }
      default:
        return new Response("not found", { status: 404 });
    }
  }
  return new Response("method not allowed", { status: 405 });
}

async function founderRoutes(request, env, parts, url) {
  const [secret, action] = parts;
  if (!env.FOUNDER_TOKEN || env.FOUNDER_TOKEN.length < 16 || !safeEqual(secret, env.FOUNDER_TOKEN)) {
    return new Response("not found", { status: 404 });
  }
  const base = `/f/${secret}`;
  const pub = origin(request, env);

  if (request.method === "GET") {
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
    return new Response("not found", { status: 404 });
  }

  if (request.method === "POST") {
    const f = await form(request);
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
        await updateAmbassador(env, parseInt(f.id, 10), f);
        return redirectBack(base + "#roster", "saved.");
      case "reminder":
        await recordReminder(env, parseInt(f.id, 10), String(f.kind || "digest"));
        return redirectBack(base + "#digest", "marked sent.");
      case "replied":
        await markReplied(env, parseInt(f.id, 10));
        return redirectBack(base + "#roster", "noted.");
      case "feedback-seen":
        await markFeedbackSeen(env, parseInt(f.id, 10));
        return redirectBack(base + "#feedback");
      default:
        return new Response("not found", { status: 404 });
    }
  }
  return new Response("method not allowed", { status: 405 });
}
