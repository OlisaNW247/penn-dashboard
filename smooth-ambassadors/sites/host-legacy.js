/* global SMOOTH_HOST */
// Stands in for worker/legacy.js in the hosting platform's build. The real tracker
// already serves the public routes; the ambassador code only needs these three
// helpers, written against the host's own constants so a scan counts and redirects
// exactly as the real /scan route does.

export async function recordScan(env, key, ambassadorId = null) {
  await SMOOTH_HOST.initialize(env.DB);
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
  let url = SMOOTH_HOST.appStore;
  // Apple campaign links: only once a real provider token exists.
  if (env.APPLE_PROVIDER_TOKEN && campaignToken) {
    const u = new URL(SMOOTH_HOST.appStore);
    u.searchParams.set("pt", env.APPLE_PROVIDER_TOKEN);
    u.searchParams.set("ct", campaignToken.slice(0, 30));
    u.searchParams.set("mt", "8");
    url = u.toString();
  }
  // Same shape the real Worker returns for a scan.
  return new Response(null, { status: 302, headers: { "Cache-Control": "no-store", Location: url } });
}

export function notFound() {
  return new Response("Not found", { status: 404 });
}
