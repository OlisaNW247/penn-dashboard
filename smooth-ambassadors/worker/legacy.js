// The routes the live tracker serves today, rebuilt to answer exactly as the
// live site did when it was read on 2026-11-10 (the stats JSON, the dashboard
// page, poster previews, the plain "Not found"). Checked read-only: no /scan
// link was opened, so the one thing NOT verified against the live site is
// the redirect target of a scan, which follows the handoff spec (Smooth's
// App Store listing).
//
// IMPORTANT: when merging into the Sites repository, the live
// `worker/index.js` stays the source of truth for these routes. Replace this
// file with it, exporting `default { fetch }`, `recordScan` and
// `appStoreRedirect` (see docs/deploy.md). Behaviour that must not change:
//   /                         dashboard (draws itself from /api/stats)
//   /api/stats                { rows: [{ school, schoolName, poster, name, total }] }
//   /scan/{poster}            legacy UPenn tracking (bare keys such as `ib`)
//   /scan/{school}/{poster}   every other school (`umiami/ib` keys)
//   /posters/{school}/{poster}.jpg  poster previews
// Each valid scan increments scans.total and redirects to the App Store.
// This version additionally appends a row to scan_events (a log; totals are
// untouched) so "this week" numbers exist for digests.

import {
  APP_STORE_URL,
  SCHOOLS,
  designsFor,
  isValidCombo,
  scanKey,
  posterName,
} from "./catalog.js";
import { DASHBOARD_HTML } from "./dashboard.js";

export async function recordScan(env, key, ambassadorId = null) {
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO scans (poster, total) VALUES (?1, 1) ON CONFLICT(poster) DO UPDATE SET total = total + 1",
    ).bind(key),
    env.DB.prepare(
      "INSERT INTO scan_events (poster, ambassador_id) VALUES (?1, ?2)",
    ).bind(key, ambassadorId),
  ]);
}

export function appStoreRedirect(env, campaignToken = null) {
  let url = APP_STORE_URL;
  // Apple campaign links: only once a real provider token exists.
  if (env.APPLE_PROVIDER_TOKEN && campaignToken) {
    const u = new URL(APP_STORE_URL);
    u.searchParams.set("pt", env.APPLE_PROVIDER_TOKEN);
    u.searchParams.set("ct", campaignToken.slice(0, 30));
    u.searchParams.set("mt", "8");
    url = u.toString();
  }
  return Response.redirect(url, 302);
}

// One row per school and design, schools and designs in the live order, a
// design with no scans yet at 0.
export async function statsPayload(env) {
  const { results } = await env.DB.prepare("SELECT poster, total FROM scans").all();
  const byKey = new Map(results.map((r) => [r.poster, r.total]));
  const rows = [];
  for (const [school, s] of Object.entries(SCHOOLS)) {
    for (const poster of designsFor(school)) {
      rows.push({
        school,
        schoolName: s.name,
        poster,
        name: posterName(poster),
        total: byKey.get(scanKey(school, poster)) ?? 0,
      });
    }
  }
  return { rows };
}

async function servePoster(env, school, poster) {
  if (!isValidCombo(school, poster)) return notFound();
  // The live Worker embeds the images. Here they come from a static-assets
  // binding filled by `npm run posters` (scripts/fetch-posters.mjs), so the
  // repository itself carries no image.
  if (env.POSTERS) {
    const r = await env.POSTERS.fetch(
      new Request(`https://assets/posters/${school}/${poster}.jpg`),
    );
    if (r.ok) {
      return new Response(r.body, { headers: { "content-type": "image/jpeg" } });
    }
  }
  return notFound();
}

export function notFound() {
  return new Response("Not found", {
    status: 404,
    headers: { "content-type": "text/plain;charset=UTF-8" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts.length === 0) {
      return new Response(DASHBOARD_HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }
    if (parts[0] === "api" && parts[1] === "stats" && parts.length === 2) {
      return new Response(JSON.stringify(await statsPayload(env)), {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }
    if (parts[0] === "scan") {
      let school, poster;
      if (parts.length === 2) [school, poster] = ["upenn", parts[1]];
      else if (parts.length === 3) [school, poster] = [parts[1], parts[2]];
      else return notFound();
      if (!isValidCombo(school, poster)) return notFound();
      const key = scanKey(school, poster);
      await recordScan(env, key, null);
      return appStoreRedirect(env, key);
    }
    if (parts[0] === "posters" && parts.length === 3 && parts[2].endsWith(".jpg")) {
      return servePoster(env, parts[1], parts[2].slice(0, -4));
    }
    return notFound();
  },
};
