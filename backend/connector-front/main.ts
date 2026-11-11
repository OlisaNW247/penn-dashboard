// Root-path front for the agent connection's two Edge Functions. Claude Code
// reads discovery documents only at the root of the MCP URL's host and falls
// back to a root `POST /register`; an Edge Function cannot answer a root path
// (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md, section 8 item 3).
//
//   UPSTREAM_BASE=https://<ref>.supabase.co/functions/v1 \
//   PUBLIC_BASE=https://<this host>/functions/v1 \
//     deno run --allow-net --allow-env main.ts
//
// Logs one line per request: method, path, status. Nothing else.
import { authorizationServerMetadata, protectedResourceMetadata } from "../supabase/functions/_shared/agentMetadata.ts";

export interface FrontEnv {
  upstreamBase: string;
  publicBase: string;
  apikey?: string;
  /** `CLIENT_IP_SECRET`: when set, the student's address goes upstream as
   *  `x-smooth-client-ip` with this secret beside it (see `forward`). */
  clientIPSecret?: string;
}

const MAX_BODY = 6 * 1024 * 1024;
const HOP_BY_HOP = new Set(["host", "connection", "transfer-encoding", "content-length", "keep-alive", "upgrade", "te", "trailer", "proxy-authorization", "proxy-authenticate"]);
/** Never copied from the caller: only the front itself may say these. */
const FRONT_ONLY = new Set(["x-smooth-client-ip", "x-smooth-front-secret"]);
const ROOT_FALLBACKS: Record<string, string> = {
  "/register": "/agent-auth/register",
  "/authorize": "/agent-auth/authorize",
  "/token": "/agent-auth/token",
  "/revoke": "/agent-auth/revoke",
};

function trimSlash(v: string): string {
  return v.replace(/\/+$/, "");
}

export function envFromDeno(get: (k: string) => string | undefined = (k) => Deno.env.get(k)): FrontEnv {
  const upstreamBase = get("UPSTREAM_BASE")?.trim();
  const publicBase = get("PUBLIC_BASE")?.trim();
  if (!upstreamBase || !publicBase) throw new Error("UPSTREAM_BASE and PUBLIC_BASE are required");
  const apikey = get("UPSTREAM_APIKEY")?.trim();
  const clientIPSecret = get("CLIENT_IP_SECRET")?.trim();
  return {
    upstreamBase: trimSlash(upstreamBase),
    publicBase: trimSlash(publicBase),
    apikey: apikey || undefined,
    clientIPSecret: clientIPSecret || undefined,
  };
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return Response.json(body, { status, headers: extra });
}

export function landingPage(env: FrontEnv): Response {
  const mcp = `${env.publicBase}/mcp`;
  const body = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Smooth</title>
<style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:48px 24px;max-width:560px;color:#111;background:#fff}code{display:block;margin:16px 0;padding:12px 14px;background:#f3f3f3;border-radius:10px;word-break:break-all;font-size:15px}p{margin:0 0 12px}</style></head>
<body><p><strong>Smooth</strong> · the connector an AI assistant uses to read your classes.</p>
<p>There is nothing to see here. In Claude, add a custom connector with this URL, then approve it in Smooth on your phone (Profile → accounts → connect an agent):</p>
<code>${mcp}</code>
<p><a href="https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md">What is shared, and how to turn it off</a>.</p></body></html>`;
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=300",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
      "Referrer-Policy": "no-referrer",
      "X-Frame-Options": "DENY",
    },
  });
}

function wellKnown(path: string, env: FrontEnv): Response | null {
  const headers = { "Cache-Control": "public, max-age=300", "Access-Control-Allow-Origin": "*" };
  if (/^\/\.well-known\/oauth-protected-resource(\/functions\/v1\/mcp)?\/?$/.test(path)) {
    return json(protectedResourceMetadata(env.publicBase), 200, headers);
  }
  if (/^\/\.well-known\/(oauth-authorization-server|openid-configuration)(\/functions\/v1\/agent-auth)?\/?$/.test(path)) {
    return json(authorizationServerMetadata(env.publicBase), 200, headers);
  }
  return null;
}

function upstreamPath(path: string): string | null {
  if (path.startsWith("/functions/v1/mcp") || path.startsWith("/functions/v1/agent-auth")) {
    return path.slice("/functions/v1".length);
  }
  const bare = path.length > 1 ? path.replace(/\/+$/, "") : path;
  return ROOT_FALLBACKS[bare] ?? null;
}

async function forward(req: Request, url: URL, target: string, env: FrontEnv): Promise<Response> {
  const headers = new Headers();
  for (const [k, v] of req.headers) if (!HOP_BY_HOP.has(k.toLowerCase()) && !FRONT_ONLY.has(k.toLowerCase())) headers.set(k, v);
  if (env.apikey) headers.set("apikey", env.apikey);
  // Supabase's gateway replaces x-forwarded-for with the address that
  // connected to it, which from here is Vercel's egress, shared by every
  // student (measured 2026-11-11). Vercel itself overwrites x-forwarded-for
  // with the real client, so its first entry is the student's browser; it
  // goes upstream in a header of our own, believed by agent-auth only with
  // the secret beside it (agent-auth `clientIP`).
  const client = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (env.clientIPSecret && client && target.startsWith("/agent-auth")) {
    headers.set("x-smooth-client-ip", client);
    headers.set("x-smooth-front-secret", env.clientIPSecret);
  }
  headers.set("x-forwarded-host", url.host);
  headers.set("x-forwarded-proto", url.protocol.replace(":", ""));
  const hasBody = req.body !== null && req.method !== "GET" && req.method !== "HEAD";
  const init: RequestInit & { duplex?: "half" } = { method: req.method, headers, redirect: "manual" };
  if (hasBody) {
    init.body = req.body;
    init.duplex = "half";
  }
  const up = await fetch(env.upstreamBase + target + url.search, init);
  // Rebuild so the status and headers (Set-Cookie, Location, ...) pass through unchanged.
  const out = new Headers(up.headers);
  out.delete("content-length");
  out.delete("transfer-encoding");
  out.delete("connection");
  // Supabase's gateway turns an Edge Function's text/html into text/plain with
  // a sandbox CSP (measured 2026-11-08); agent-auth announces the intended
  // values in marker headers and we restore them here. Never for /mcp.
  if (target.startsWith("/agent-auth")) {
    const type = out.get("x-smooth-content-type");
    const csp = out.get("x-smooth-csp");
    if (type) {
      out.set("content-type", type);
      if (csp) out.set("content-security-policy", csp);
    }
    out.delete("x-smooth-content-type");
    out.delete("x-smooth-csp");
  }
  return new Response([101, 204, 205, 304].includes(up.status) ? null : up.body, { status: up.status, statusText: up.statusText, headers: out });
}

export async function handle(req: Request, env: FrontEnv): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;
  if (req.method === "GET" || req.method === "HEAD") {
    const known = wellKnown(path, env);
    if (known) return known;
    // A person who opens the host in a browser (Marco did, 2026-11-09, and
    // saw a bare 404) gets one sentence and the URL to paste into Claude.
    // Nothing else lives at the root: Claude never asks for it.
    if (path === "/" || path === "") return landingPage(env);
  }
  const target = upstreamPath(path);
  if (target === null) return json({ error: "not_found" }, 404);
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY) return json({ error: "payload_too_large" }, 413);
  try {
    return await forward(req, url, target, env);
  } catch {
    return json({ error: "bad_gateway" }, 502);
  }
}

if (import.meta.main) {
  const env = envFromDeno();
  const port = Number(Deno.env.get("PORT") ?? "8000");
  Deno.serve({ port }, async (req) => {
    const res = await handle(req, env);
    console.log(`${req.method} ${new URL(req.url).pathname} ${res.status}`);
    return res;
  });
}
