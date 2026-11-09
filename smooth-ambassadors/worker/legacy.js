// The routes the live tracker serves today, re-implemented from the handoff
// spec so the whole system runs and is testable from this repository.
//
// IMPORTANT: when merging into the Sites repository, keep the live
// `worker/index.js` as the source of truth for these routes and replace this
// file with it (export default { fetch }). Behaviour that must not change:
//   /                         dashboard
//   /api/stats                counts per school and design
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
  parseScanKey,
} from "./catalog.js";
import { layout, esc } from "./html.js";

export async function recordScan(env, key, ambassadorId = null, ctx = null) {
  const stmts = [
    env.DB.prepare(
      "INSERT INTO scans (poster, total) VALUES (?1, 1) ON CONFLICT(poster) DO UPDATE SET total = total + 1",
    ).bind(key),
    env.DB.prepare(
      "INSERT INTO scan_events (poster, ambassador_id) VALUES (?1, ?2)",
    ).bind(key, ambassadorId),
  ];
  await env.DB.batch(stmts);
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

export async function statsPayload(env) {
  const { results } = await env.DB.prepare(
    "SELECT poster, total FROM scans",
  ).all();
  const byKey = new Map(results.map((r) => [r.poster, r.total]));
  const schools = Object.entries(SCHOOLS).map(([key, s]) => {
    const designs = designsFor(key).map((poster) => ({
      poster,
      key: scanKey(key, poster),
      total: byKey.get(scanKey(key, poster)) ?? 0,
    }));
    return {
      key,
      name: s.name,
      total: designs.reduce((a, d) => a + d.total, 0),
      designs,
    };
  });
  // Keys in D1 that the catalog does not know (should be none).
  const unknown = results
    .filter((r) => {
      const { school, poster } = parseScanKey(r.poster);
      return !isValidCombo(school, poster);
    })
    .map((r) => ({ key: r.poster, total: r.total }));
  return {
    updated: new Date().toISOString(),
    total: schools.reduce((a, s) => a + s.total, 0),
    schools,
    unknown,
  };
}

function dashboardHtml(stats) {
  const rows = stats.schools
    .map(
      (s) => `
    <section class="card">
      <h2>${esc(s.name)} <span class="muted">${s.total}</span></h2>
      <table>
        ${s.designs
          .map(
            (d) =>
              `<tr><td><a href="/posters/${esc(s.key)}/${esc(d.poster)}.jpg">${esc(d.poster)}</a></td><td class="num">${d.total}</td></tr>`,
          )
          .join("")}
      </table>
    </section>`,
    )
    .join("");
  return layout({
    title: "smooth poster scans",
    body: `
      <h1>smooth poster scans <span class="muted">${stats.total}</span></h1>
      <p class="muted">link opens per poster design, by school. repeats included. updated ${esc(stats.updated.slice(0, 16).replace("T", " "))} utc.</p>
      ${rows}
      <p class="muted"><a href="/api/stats">json</a> · <a href="/api/leaderboard">school leaderboard</a></p>`,
  });
}

async function servePoster(env, school, poster) {
  if (!isValidCombo(school, poster)) return notFound();
  // Poster images are embedded in the live Worker. Here they come from an
  // optional static-assets binding so this repo can run without them.
  if (env.POSTERS) {
    const r = await env.POSTERS.fetch(
      new Request(`https://assets/posters/${school}/${poster}.jpg`),
    );
    if (r.ok) return r;
  }
  return new Response(
    `poster image for ${school}/${poster} is not bundled in this build`,
    { status: 404, headers: { "content-type": "text/plain" } },
  );
}

function notFound() {
  return new Response("not found", { status: 404 });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts.length === 0) {
      return new Response(dashboardHtml(await statsPayload(env)), {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    if (parts[0] === "api" && parts[1] === "stats" && parts.length === 2) {
      return Response.json(await statsPayload(env), {
        headers: { "access-control-allow-origin": "*" },
      });
    }
    if (parts[0] === "scan") {
      let school, poster;
      if (parts.length === 2) [school, poster] = ["upenn", parts[1]];
      else if (parts.length === 3) [school, poster] = [parts[1], parts[2]];
      else return notFound();
      if (!isValidCombo(school, poster)) return notFound();
      const key = scanKey(school, poster);
      await recordScan(env, key, null, ctx);
      return appStoreRedirect(env, key);
    }
    if (parts[0] === "posters" && parts.length === 3 && parts[2].endsWith(".jpg")) {
      return servePoster(env, parts[1], parts[2].slice(0, -4));
    }
    return notFound();
  },
};
