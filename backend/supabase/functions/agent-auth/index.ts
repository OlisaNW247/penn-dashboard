// The `agent-auth` edge function: the OAuth authorization server for the
// agent connection (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §3). Claude
// and other MCP clients send the student's browser to `/authorize`; the page
// there shows a code and a number; the student's phone approves through
// `/phone`; the browser's poll of `/status` sees the approval and carries
// the one-time code back to the client; the client trades it at `/token`.
//
// The decisions are in `_shared/agentAuth.ts` and `_shared/agentTokens.ts`;
// storage is the `AgentStore` interface, so the tests run this whole file
// over `MemoryAgentStore`. Deployed with `verify_jwt = false`: the gateway
// has to let a browser's unauthenticated GET through, so the phone endpoint
// authenticates itself with `requireUser`.
//
// Never logs codes, tokens, nonces, user ids or URLs, only outcome codes.
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { corsHeaders, errorResponse, HttpError, json, readJSON } from "../_shared/http.ts";
import { enforceMinimumVersion } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import { guardedFetch, productionNetGuard, readTextCapped } from "../_shared/netguard.ts";
import type { AgentConnectionRow, AgentStore, AgentTokenRow, PendingAuthRow } from "../_shared/agentStore.ts";
import { PostgrestAgentStore } from "../_shared/agentStorePostgrest.ts";
import {
  authorizationServerMetadata,
  issuerURL,
  mcpURL as mcpURLFor,
  publicBaseFromEnv,
} from "../_shared/agentMetadata.ts";
import {
  ACCESS_TOKEN_TTL_MS,
  AUTH_CODE_TTL_MS,
  base64url,
  digestsEqual,
  generateToken,
  hashToken,
  looksLikeToken,
  PENDING_AUTH_TTL_MS,
  REFRESH_TOKEN_TTL_MS,
  tokenKindOf,
} from "../_shared/agentTokens.ts";
import {
  authorizePage,
  clientHost,
  errorPage,
  generateId,
  generateUserCode,
  isRegisteredClientId,
  matchChoices,
  nonceCookieName,
  normalizeUserCode,
  parseCookies,
  redirectURIMatches,
  validateAuthorizeRequest,
  validateClientMetadata,
  validateRegistrationRequest,
  verifyPKCE,
} from "../_shared/agentAuth.ts";

export interface AgentAuthDeps {
  store: AgentStore;
  /** Origin plus `/functions/v1` (see `_shared/agentMetadata.ts`). */
  publicBase: string;
  now?: () => Date;
  random?: (n: number) => Uint8Array;
  /** Fetches and parses a client's metadata document. Throws on any failure. */
  fetchClientMetadata: (url: string) => Promise<unknown>;
  /** The phone's student, or throws `HttpError(401)`. */
  requireUserId: (req: Request) => Promise<string>;
  /** Local development only. */
  devApproveURL?: (pendingId: string) => string;
  /** The secret the connector front proves itself with when it hands over
   *  the student's address (`LHF_FRONT_CLIENT_IP_SECRET`); see `clientIP`. */
  frontClientIPSecret?: string;
}

// Measured 2026-11-08: Supabase's gateway rewrites any text/html response from
// an Edge Function on <ref>.supabase.co to text/plain and replaces our
// Content-Security-Policy with "default-src 'none'; sandbox", so the pages
// would show as raw HTML. Custom headers pass through, so the intended values
// are announced a second time in X-Smooth-Content-Type / X-Smooth-CSP and the
// connector front (backend/connector-front/main.ts) restores them. Direct
// callers of supabase.co still get the gateway's rewrite, which is harmless.
const PAGE_CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'";
const PAGE_CONTENT_TYPE = "text/html; charset=utf-8";
const PAGE_HEADERS = {
  "Content-Type": PAGE_CONTENT_TYPE,
  "Cache-Control": "no-store",
  "Content-Security-Policy": PAGE_CSP,
  "X-Smooth-Content-Type": PAGE_CONTENT_TYPE,
  "X-Smooth-CSP": PAGE_CSP,
  "Referrer-Policy": "no-referrer",
  "X-Frame-Options": "DENY",
};
const MAX_FORM_BYTES = 16 * 1024;
const HOUR = 3600;
// Per-hour limits (20261109090000_agent_hardening.sql counts them in
// Postgres, because an Edge Function runs in many isolates and a counter in
// each would multiply the limit by the number of warm ones). The phone's
// `lookup` limit is the one that matters: a typed code is 8 letters of a
// 20-letter alphabet (2.6e10 codes) live for five minutes, so 20 tries an
// hour is nothing against that, and a student typing by hand never needs
// more than a few.
//
// Why `/authorize` is per ip and `/token` and `/register` are not: the
// browser that opens `/authorize` is the student's own, so its address is
// one person's. `/token` and `/register` are called server to server by a
// hosted connector (claude.ai and the like) from a small set of shared
// egress addresses, so a per-ip cap there would throttle every student on
// that connector at once. `/token` is therefore limited per subject (the
// connection behind a refresh token, the one authorization code being
// redeemed), with a per-ip ceiling high enough never to bind real traffic and
// there only as a DoS backstop. `/register` has no subject yet; its per-ip
// number is generous for the same reason.
const LIMITS = {
  authorize: 60,
  register: 60,
  tokenIP: 1200,
  tokenConnection: 30,
  tokenCode: 5,
  lookup: 20,
  approve: 10,
} as const;
/** A pending row is swept only this long past its own `expires_at`.
 *  `status?go=1` on a row seen just before expiry mints a code valid for
 *  `AUTH_CODE_TTL_MS` more, so deleting the row at `expires_at` could kill a
 *  live code. Twice that TTL; keep in step with the SQL sweeper
 *  (`agent_sweep_expired`) if the TTL changes. */
export const PENDING_SWEEP_MARGIN_MS = 2 * 60_000;
/** One `/authorize` in about fifty (5 of 256 byte values) sweeps. */
const SWEEP_BELOW = 5;
const USER_CODE_ATTEMPTS = 5;

export async function handleAgentAuth(req: Request, deps: AgentAuthDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });

  const url = new URL(req.url);
  const segments = url.pathname.split("/");
  const at = segments.indexOf("agent-auth");
  if (at < 0) return logged(json(404, { error: "not_found" }), "route");
  // The root is derived from the public base, never from the request path:
  // Supabase's runtime hands the function `/agent-auth/...` with
  // `/functions/v1` stripped, while the browser sits at
  // `<front>/functions/v1/agent-auth/authorize`. Taken from the path, the
  // root gave the nonce cookie `Path=/agent-auth` and the page a status URL
  // the front could not route, so two approvals on Marco's phone
  // (2026-11-09) never became a code. The dev tunnel kept the full path and
  // hid it. The wrong fix is a rewrite in the front: a direct caller of
  // supabase.co would still get the stripped root.
  const root = `${new URL(deps.publicBase).pathname.replace(/\/+$/, "")}/agent-auth`;
  const route = "/" + segments.slice(at + 1).join("/");

  try {
    const ctx: Ctx = {
      deps,
      url,
      root,
      now: deps.now ?? (() => new Date()),
      random: deps.random ?? ((n) => crypto.getRandomValues(new Uint8Array(n))),
      issuer: issuerURL(deps.publicBase),
      mcpURL: mcpURLFor(deps.publicBase),
    };

    if (route === "/.well-known/oauth-authorization-server" || route === "/.well-known/openid-configuration") {
      if (req.method !== "GET") return logged(json(405, { error: "method_not_allowed" }), "method");
      return json(200, authorizationServerMetadata(deps.publicBase), { "Cache-Control": "public, max-age=300" });
    }
    if (route === "/authorize") {
      if (req.method !== "GET") return logged(json(405, { error: "method_not_allowed" }), "method");
      return await authorize(req, ctx);
    }
    if (route === "/register") {
      if (req.method !== "POST") return logged(json(405, { error: "method_not_allowed" }), "method");
      return await register(req, ctx);
    }
    if (route === "/status") {
      if (req.method !== "GET") return logged(json(405, { error: "method_not_allowed" }), "method");
      return await status(req, ctx);
    }
    if (route === "/token") {
      if (req.method !== "POST") return logged(json(405, { error: "method_not_allowed" }), "method");
      return await token(req, ctx);
    }
    if (route === "/revoke") {
      if (req.method !== "POST") return logged(json(405, { error: "method_not_allowed" }), "method");
      return await revoke(req, ctx);
    }
    if (route === "/phone") {
      if (req.method !== "POST") return logged(json(405, { error: "method_not_allowed" }), "method");
      return await phone(req, ctx);
    }
    return logged(json(404, { error: "not_found" }), "route");
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`agent-auth error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("agent-auth error: unexpected", err instanceof Error ? err.name : "unknown");
    return errorResponse("internal_error", "unexpected server error", 500);
  }
}

interface Ctx {
  deps: AgentAuthDeps;
  url: URL;
  root: string;
  now: () => Date;
  random: (n: number) => Uint8Array;
  issuer: string;
  mcpURL: string;
}

/** The caller's address for rate limiting.
 *
 *  Measured 2026-11-11 (docs/V11_TEST_BACKEND_2026-11-11.md): Supabase's
 *  gateway overwrites `x-forwarded-for` with the address that connected to
 *  it. Called straight, that is the caller's own (a spoofed header is
 *  replaced, which is good). Behind the connector front it is Vercel's
 *  egress address, a handful of addresses shared by every student, so the
 *  "per ip" limits on `/authorize` and `/register` were one bucket for the
 *  whole school: 60 requests an hour from anyone blocked every sign-in.
 *
 *  So the front, which sees Vercel's own `x-forwarded-for` (Vercel overwrites
 *  that header with the real client), passes the address on as
 *  `x-smooth-client-ip` together with `x-smooth-front-secret`, and that
 *  address is believed only when the secret matches `LHF_FRONT_CLIENT_IP_SECRET`
 *  (compared as hashes, in constant time). Without the secret configured, or
 *  with a wrong one, nothing changes: `x-forwarded-for`, else
 *  `cf-connecting-ip`, else one shared "unknown" bucket. The wrong fix is
 *  trusting `x-smooth-client-ip` (or any client header) without the secret:
 *  a direct caller of supabase.co could then pick a fresh bucket per request.
 *  Never logged. */
async function clientIP(req: Request, secret: string | undefined): Promise<string> {
  if (secret) {
    const presented = req.headers.get("x-smooth-front-secret");
    const handed = req.headers.get("x-smooth-client-ip")?.trim();
    if (presented && handed && handed.length <= 64 && digestsEqual(await hashToken(presented), await hashToken(secret))) {
      return handed;
    }
  }
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (forwarded) return forwarded;
  return req.headers.get("cf-connecting-ip")?.trim() || "unknown";
}

/** True when the hit is within the limit. Fails OPEN on any store error
 *  (table missing before the migration, database down): the 2026-10-22
 *  `requireUser` trap in CLAUDE.md is that a lookup failure on a shared path
 *  must not take every caller down, and a missed rate limit costs far less
 *  than a dead sign-in. One line, no key. */
async function withinLimit(ctx: Ctx, key: string, limit: number): Promise<boolean> {
  try {
    return await ctx.deps.store.rateCheck(await hashedKey(key), limit, HOUR);
  } catch {
    console.error("agent-auth error: rate_check_failed (open)");
    return true;
  }
}

/** Keys hold a hash, so the table never holds a raw address or user id. */
async function hashedKey(key: string): Promise<string> {
  const at = key.indexOf(":");
  return `${key.slice(0, at)}:${await hashToken(key.slice(at + 1))}`;
}

/** 429. RFC 6749 §5.2 has no rate-limit code; `slow_down` is RFC 8628's
 *  (device grant) word for "too fast", the nearest standard one. */
function tooMany(code: string): Response {
  console.error(`agent-auth error: ${code} (429)`);
  return json(429, { error: "slow_down" }, { "Retry-After": "60", "Cache-Control": "no-store" });
}

/** Opportunistic housekeeping; never blocks or fails the request. Logs only
 *  how many rows went. A cron job would be better (PROTOCOL.md → Limitations). */
async function maybeSweep(ctx: Ctx): Promise<void> {
  if (ctx.random(1)[0] >= SWEEP_BELOW) return;
  try {
    const removed = await ctx.deps.store.sweep();
    console.log(`agent-auth: swept ${removed}`);
  } catch {
    console.error("agent-auth error: sweep_failed (open)");
  }
}

/** Logs the outcome code and status of a refusal and passes it through. */
function logged(res: Response, code: string): Response {
  if (res.status >= 400) console.error(`agent-auth error: ${code} (${res.status})`);
  return res;
}

function iso(ctx: Ctx, plusMs = 0): string {
  return new Date(ctx.now().getTime() + plusMs).toISOString();
}

function html(status: number, body: string, extra: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { ...PAGE_HEADERS, ...extra } });
}

function redirect(location: string): Response {
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
}

function redirectWith(base: string, params: Record<string, string | null>, issuer: string): string {
  const target = new URL(base);
  for (const [k, v] of Object.entries(params)) if (v !== null) target.searchParams.set(k, v);
  target.searchParams.set("iss", issuer);
  return target.toString();
}

// ---------------------------------------------------------------------
// POST /register (RFC 7591)
// ---------------------------------------------------------------------

async function register(req: Request, ctx: Ctx): Promise<Response> {
  if (!(await withinLimit(ctx, `register:${await clientIP(req, ctx.deps.frontClientIPSecret)}`, LIMITS.register))) return tooMany("register_rate");
  const refuse = (description: string) => {
    console.error("agent-auth error: register_invalid_client_metadata (400)");
    return json(400, { error: "invalid_client_metadata", error_description: description }, { "Cache-Control": "no-store" });
  };
  let body: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_FORM_BYTES) return refuse("body is too large");
    body = JSON.parse(text);
  } catch {
    return refuse("body must be JSON");
  }
  const checked = validateRegistrationRequest(body);
  if (!checked.ok) return refuse(checked.description);

  const row = {
    clientId: `smc_${generateId(ctx.random)}`,
    clientName: checked.clientName,
    redirectUris: checked.redirectUris,
    createdAt: iso(ctx),
  };
  await ctx.deps.store.insertClient(row);
  return json(201, {
    client_id: row.clientId,
    client_name: row.clientName,
    redirect_uris: row.redirectUris,
    token_endpoint_auth_method: "none",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    client_id_issued_at: Math.floor(ctx.now().getTime() / 1000),
  }, { "Cache-Control": "no-store" });
}

/** The client behind a `client_id`, with the redirect URI vouched for: a
 *  registered client from its stored row, anything else from its fetched
 *  metadata document. Never throws; `ok: false` means "do not redirect". */
async function resolveClient(
  ctx: Ctx,
  clientId: string,
  redirectUri: string,
): Promise<{ ok: true; clientName: string } | { ok: false }> {
  try {
    if (isRegisteredClientId(clientId)) {
      const row = await ctx.deps.store.selectClient(clientId);
      if (!row || !row.redirectUris.some((registered) => redirectURIMatches(redirectUri, registered))) return { ok: false };
      return { ok: true, clientName: row.clientName };
    }
    const checked = validateClientMetadata(await ctx.deps.fetchClientMetadata(clientId), clientId, redirectUri);
    return checked.ok ? { ok: true, clientName: checked.clientName } : { ok: false };
  } catch {
    return { ok: false };
  }
}

// ---------------------------------------------------------------------
// GET /authorize
// ---------------------------------------------------------------------

async function authorize(req: Request, ctx: Ctx): Promise<Response> {
  if (!(await withinLimit(ctx, `authorize:${await clientIP(req, ctx.deps.frontClientIPSecret)}`, LIMITS.authorize))) return tooMany("authorize_rate");
  await maybeSweep(ctx);
  const checked = validateAuthorizeRequest(ctx.url.searchParams, ctx.mcpURL);
  if (!checked.ok) {
    if (!checked.redirectable) {
      return logged(
        html(400, errorPage("this sign-in link is not valid", "Close this tab and try again from the app.")),
        `authorize_${checked.error}`,
      );
    }
    // Even an "ordinary" OAuth error is only ever sent back to a redirect
    // URI the client's own metadata document lists. Bouncing to the URI as
    // given would let anyone craft a link that lands a student on an
    // arbitrary site with an official-looking error, which the OAuth
    // security BCP (RFC 9700 §4.1) forbids. So the metadata is fetched and
    // checked here too, and an unverifiable URI gets the plain error page.
    const clientId = ctx.url.searchParams.get("client_id")!;
    const redirectUri = ctx.url.searchParams.get("redirect_uri")!;
    if (!(await resolveClient(ctx, clientId, redirectUri)).ok) {
      return logged(
        html(400, errorPage("this app's sign-in details could not be read", "Close this tab and try again from the app.")),
        "authorize_client_metadata",
      );
    }
    const state = ctx.url.searchParams.get("state");
    const location = redirectWith(redirectUri, {
      error: checked.error,
      error_description: checked.description,
      state,
    }, ctx.issuer);
    console.error(`agent-auth error: authorize_${checked.error} (302)`);
    return redirect(location);
  }
  const { clientKind: _kind, ...params } = checked.request;
  const request = params;

  // A document that cannot be fetched or does not vouch for the redirect
  // URI is never answered with a redirect: that URI is exactly the thing
  // we failed to verify.
  const unreadable = () =>
    logged(
      html(400, errorPage("this app's sign-in details could not be read", "Close this tab and try again from the app.")),
      "authorize_client_metadata",
    );
  const metadata = await resolveClient(ctx, request.clientId, request.redirectUri);
  if (!metadata.ok) return unreadable();

  const id = generateId(ctx.random);
  const { answer, choices } = matchChoices(ctx.random);
  const nonce = base64url(ctx.random(32));
  const base: Omit<PendingAuthRow, "userCode"> = {
    id,
    matchNumber: answer,
    matchChoices: choices,
    nonceHash: await hashToken(nonce),
    params,
    userId: null,
    authCodeHash: null,
    authCodeExpiresAt: null,
    clientName: metadata.clientName,
    status: "pending",
    createdAt: iso(ctx),
    expiresAt: iso(ctx, PENDING_AUTH_TTL_MS),
  };

  let userCode = "";
  let stored = false;
  for (let attempt = 0; attempt < USER_CODE_ATTEMPTS && !stored; attempt++) {
    userCode = generateUserCode(ctx.random);
    try {
      await ctx.deps.store.insertPending({ ...base, userCode });
      stored = true;
    } catch {
      // A duplicate live code; draw another.
    }
  }
  if (!stored) throw new HttpError(503, "code_unavailable");

  const page = authorizePage({
    clientName: metadata.clientName,
    clientHost: clientHost(request.clientId),
    scopes: request.scopes,
    pendingId: id,
    userCode,
    matchNumber: answer,
    statusURL: `${ctx.root}/status?p=${encodeURIComponent(id)}`,
    devApproveURL: ctx.deps.devApproveURL?.(id),
  });
  return html(200, page, {
    "Set-Cookie": `${nonceCookieName(id)}=${nonce}; HttpOnly; Secure; SameSite=Lax; Max-Age=600; Path=${ctx.root}`,
  });
}

// ---------------------------------------------------------------------
// GET /status
// ---------------------------------------------------------------------

function pendingState(row: PendingAuthRow, ctx: Ctx): "pending" | "approved" | "denied" | "expired" {
  if (row.status === "pending") return Date.parse(row.expiresAt) <= ctx.now().getTime() ? "expired" : "pending";
  if (row.status === "consumed") return "approved";
  return row.status;
}

async function status(req: Request, ctx: Ctx): Promise<Response> {
  const forbidden = () => logged(json(403, { error: "forbidden" }, { "Cache-Control": "no-store" }), "status_forbidden");
  const id = ctx.url.searchParams.get("p");
  if (!id) return forbidden();
  const row = await ctx.deps.store.selectPendingById(id);
  const nonce = parseCookies(req.headers.get("cookie")).get(nonceCookieName(id));
  if (!row || !nonce || !digestsEqual(await hashToken(nonce), row.nonceHash)) return forbidden();

  const state = pendingState(row, ctx);
  if (ctx.url.searchParams.get("go") !== "1") return json(200, { state }, { "Cache-Control": "no-store" });
  if (state !== "approved") return logged(json(400, { error: "not_approved" }), "status_go_state");
  // The pending row's five minutes bound the whole hand-off, approval
  // included: a browser that comes back for its code after that gets
  // nothing, even though the phone said yes in time.
  if (Date.parse(row.expiresAt) <= ctx.now().getTime()) return logged(json(400, { error: "expired" }), "status_go_expired");

  const code = generateToken("code", ctx.random);
  const issued = await ctx.deps.store.issueAuthCode(id, await hashToken(code), iso(ctx, AUTH_CODE_TTL_MS));
  if (!issued) return logged(json(409, { error: "already_issued" }), "status_go_issued");
  return redirect(redirectWith(row.params.redirectUri, { code, state: row.params.state }, ctx.issuer));
}

// ---------------------------------------------------------------------
// POST /token
// ---------------------------------------------------------------------

function tokenError(error: string, description: string): Response {
  console.error(`agent-auth error: token_${error} (400)`);
  return json(400, { error, error_description: description }, { "Cache-Control": "no-store", "Pragma": "no-cache" });
}

async function readForm(req: Request): Promise<URLSearchParams | null> {
  const type = req.headers.get("content-type") ?? "";
  if (!type.toLowerCase().startsWith("application/x-www-form-urlencoded")) return null;
  const text = await req.text();
  if (text.length > MAX_FORM_BYTES) return null;
  return new URLSearchParams(text);
}

function stripSlash(value: string): string {
  return value.endsWith("/") ? value.slice(0, -1) : value;
}

async function mintTokens(
  ctx: Ctx,
  connectionId: string,
  resource: string,
  scopes: string[],
  rotatedFrom: string | null,
): Promise<{ response: Response; rows: AgentTokenRow[] }> {
  const access = generateToken("access", ctx.random);
  const refresh = generateToken("refresh", ctx.random);
  const createdAt = iso(ctx);
  const rows: AgentTokenRow[] = [
    {
      hash: await hashToken(access),
      kind: "access",
      connectionId,
      resource,
      scopes,
      expiresAt: iso(ctx, ACCESS_TOKEN_TTL_MS),
      rotatedFrom: null,
      usedAt: null,
      createdAt,
    },
    {
      hash: await hashToken(refresh),
      kind: "refresh",
      connectionId,
      resource,
      scopes,
      expiresAt: iso(ctx, REFRESH_TOKEN_TTL_MS),
      rotatedFrom,
      usedAt: null,
      createdAt,
    },
  ];
  const response = json(200, {
    access_token: access,
    token_type: "Bearer",
    expires_in: ACCESS_TOKEN_TTL_MS / 1000,
    refresh_token: refresh,
    scope: scopes.join(" "),
  }, { "Cache-Control": "no-store", "Pragma": "no-cache" });
  return { response, rows };
}

async function token(req: Request, ctx: Ctx): Promise<Response> {
  if (!(await withinLimit(ctx, `token-ip:${await clientIP(req, ctx.deps.frontClientIPSecret)}`, LIMITS.tokenIP))) return tooMany("token_rate");
  const form = await readForm(req);
  if (!form) return tokenError("invalid_request", "send application/x-www-form-urlencoded");
  const grantType = form.get("grant_type");
  if (grantType === "authorization_code") return await codeGrant(form, ctx);
  if (grantType === "refresh_token") return await refreshGrant(form, ctx);
  return tokenError("unsupported_grant_type", "grant_type must be authorization_code or refresh_token");
}

async function codeGrant(form: URLSearchParams, ctx: Ctx): Promise<Response> {
  const code = form.get("code");
  const verifier = form.get("code_verifier");
  const redirectUri = form.get("redirect_uri");
  const clientId = form.get("client_id");
  if (!code || !verifier || !redirectUri || !clientId) {
    return tokenError("invalid_request", "code, code_verifier, redirect_uri and client_id are required");
  }
  if (!looksLikeToken(code) || tokenKindOf(code) !== "code") return tokenError("invalid_grant", "unknown code");

  // Per code, before it is burnt: five tries at one code is all a legitimate
  // client needs (it redeems once), and it stops guessing at a single code.
  const codeHash = await hashToken(code);
  if (!(await withinLimit(ctx, `token-code:${codeHash}`, LIMITS.tokenCode))) return tooMany("token_code_rate");
  const row = await ctx.deps.store.consumeAuthCode(codeHash);
  if (!row || row.userId === null) return tokenError("invalid_grant", "unknown code");

  const resource = form.get("resource");
  if (
    row.authCodeExpiresAt === null || Date.parse(row.authCodeExpiresAt) <= ctx.now().getTime() ||
    clientId !== row.params.clientId || redirectUri !== row.params.redirectUri ||
    (resource !== null && stripSlash(resource) !== row.params.resource) ||
    !(await verifyPKCE(verifier, row.params.codeChallenge))
  ) {
    return tokenError("invalid_grant", "the code cannot be used");
  }

  const connection: AgentConnectionRow = {
    id: generateId(ctx.random),
    userId: row.userId,
    clientId: row.params.clientId,
    clientName: row.clientName,
    scopes: row.params.scopes,
    createdAt: iso(ctx),
    lastUsedAt: null,
    revokedAt: null,
  };
  await ctx.deps.store.insertConnection(connection);
  const minted = await mintTokens(ctx, connection.id, row.params.resource, row.params.scopes, null);
  await ctx.deps.store.insertTokens(minted.rows);
  return minted.response;
}

async function refreshGrant(form: URLSearchParams, ctx: Ctx): Promise<Response> {
  const presented = form.get("refresh_token");
  if (!presented) return tokenError("invalid_request", "refresh_token is required");
  if (!looksLikeToken(presented) || tokenKindOf(presented) !== "refresh") {
    return tokenError("invalid_grant", "unknown refresh token");
  }
  const hash = await hashToken(presented);
  const old = await ctx.deps.store.selectToken(hash);
  if (!old || old.kind !== "refresh" || Date.parse(old.expiresAt) <= ctx.now().getTime()) {
    return tokenError("invalid_grant", "unknown refresh token");
  }
  const connection = await ctx.deps.store.selectConnection(old.connectionId);
  if (!connection || connection.revokedAt !== null) return tokenError("invalid_grant", "unknown refresh token");
  // Per connection, and only now that the token is known and live: an unknown
  // or expired token is `invalid_grant` above and never counts.
  if (!(await withinLimit(ctx, `token-conn:${connection.id}`, LIMITS.tokenConnection))) return tooMany("token_connection_rate");
  // A public client sends its client_id with the refresh; when it does, it
  // has to be the client the connection was made for.
  const refreshClientId = form.get("client_id");
  if (refreshClientId !== null && refreshClientId !== connection.clientId) {
    return tokenError("invalid_grant", "unknown refresh token");
  }

  const resource = form.get("resource");
  if (resource !== null && stripSlash(resource) !== old.resource) return tokenError("invalid_target", "resource does not match");
  const scopeParam = form.get("scope");
  let scopes = old.scopes;
  if (scopeParam !== null && scopeParam.trim() !== "") {
    const asked = scopeParam.split(" ").filter((s) => s !== "");
    if (!asked.every((s) => old.scopes.includes(s))) return tokenError("invalid_scope", "scope exceeds the original grant");
    scopes = asked;
  }

  // A refresh token redeems once. A second presentation means two parties
  // hold it (one of them stole it), and the whole connection goes.
  if (!(await ctx.deps.store.markRefreshUsed(hash, iso(ctx)))) {
    await ctx.deps.store.revokeConnection(connection.id, connection.userId, iso(ctx));
    return tokenError("invalid_grant", "refresh token was already used");
  }
  const minted = await mintTokens(ctx, connection.id, old.resource, scopes, hash);
  await ctx.deps.store.insertTokens(minted.rows);
  return minted.response;
}

// ---------------------------------------------------------------------
// POST /revoke (RFC 7009)
// ---------------------------------------------------------------------

async function revoke(req: Request, ctx: Ctx): Promise<Response> {
  const form = await readForm(req);
  const presented = form?.get("token") ?? null;
  // Unknown, malformed or already gone all answer 200: the caller learns
  // nothing about what exists.
  if (presented && looksLikeToken(presented)) {
    const kind = tokenKindOf(presented);
    const hash = await hashToken(presented);
    if (kind === "access") {
      await ctx.deps.store.deleteToken(hash);
    } else if (kind === "refresh") {
      const row = await ctx.deps.store.selectToken(hash);
      const connection = row ? await ctx.deps.store.selectConnection(row.connectionId) : null;
      if (connection) await ctx.deps.store.revokeConnection(connection.id, connection.userId, iso(ctx));
    }
  }
  return json(200, {}, { "Cache-Control": "no-store" });
}

// ---------------------------------------------------------------------
// POST /phone
// ---------------------------------------------------------------------

function liveForPhone(row: PendingAuthRow | null, ctx: Ctx): row is PendingAuthRow {
  return row !== null && row.status === "pending" && Date.parse(row.expiresAt) > ctx.now().getTime();
}

async function phone(req: Request, ctx: Ctx): Promise<Response> {
  await enforceMinimumVersion(req, { headerOptional: true });
  const userId = await ctx.deps.requireUserId(req);
  const raw = await readJSON<unknown>(req);
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new HttpError(400, "bad_request");
  const body = raw as Record<string, unknown>;
  const notFound = () => logged(json(404, { error: "not_found" }), "phone_not_found");
  const store = ctx.deps.store;

  switch (body.action) {
    case "lookup": {
      if (!(await withinLimit(ctx, `lookup:${userId}`, LIMITS.lookup))) return tooMany("lookup_rate");
      let row: PendingAuthRow | null = null;
      if (typeof body.c === "string") {
        row = await store.selectPendingById(body.c);
      } else if (typeof body.code === "string") {
        const code = normalizeUserCode(body.code);
        row = code ? await store.selectPendingByUserCode(code) : null;
      } else {
        throw new HttpError(400, "bad_request");
      }
      if (!liveForPhone(row, ctx)) return notFound();
      // Binds the request to the student who has now seen it; `deny` and
      // `approve` ask for exactly this. Last lookup wins: first-wins would let
      // a stranger who guessed a code lock the real student out for good. The
      // cost of last-wins is that a stranger who looks the code up after the
      // student takes the binding, and the student's approve or deny answers
      // 404 until they look it up again, which the phone's flow does anyway.
      await store.claimPending(row.id, userId);
      return json(200, {
        id: row.id,
        clientName: row.clientName,
        clientHost: clientHost(row.params.clientId),
        scopes: row.params.scopes,
        choices: row.matchChoices,
        expiresAt: row.expiresAt,
      });
    }
    case "approve": {
      if (typeof body.c !== "string" || typeof body.picked !== "number") throw new HttpError(400, "bad_request");
      if (!(await withinLimit(ctx, `approve:${userId}`, LIMITS.approve))) return tooMany("approve_rate");
      const row = await store.selectPendingById(body.c);
      // Same binding as `deny`: only the student who last looked the request
      // up may decide it. Without it, anyone holding an id could approve a
      // request they never saw the page of (the match number would still
      // stop them, but a wrong pick would deny the real student's request).
      if (!liveForPhone(row, ctx) || row.claimedBy !== userId) return notFound();
      if (body.picked !== row.matchNumber) {
        await store.denyPending(row.id);
        return json(200, { approved: false, reason: "match" });
      }
      if (!(await store.approvePending(row.id, userId))) return logged(json(409, { error: "already_decided" }), "phone_decided");
      return json(200, { approved: true, clientName: row.clientName });
    }
    case "deny": {
      if (typeof body.c !== "string") throw new HttpError(400, "bad_request");
      // A student can deny only a request they have looked up (by its typed
      // code or its id), the same knowledge `approve` starts from. Any other
      // id, unknown or someone else's, is the one 404. The wrong fix is
      // requiring the user code in the body: the phone opened the request
      // from a QR id and never saw the code.
      const row = await store.selectPendingById(body.c);
      if (!row || row.claimedBy !== userId) return notFound();
      return json(200, { denied: await store.denyPending(row.id) });
    }
    case "list": {
      const rows = (await store.listConnections(userId)).filter((c) => c.revokedAt === null);
      return json(200, {
        connections: rows.map((c) => ({
          id: c.id,
          clientName: c.clientName,
          clientHost: clientHost(c.clientId),
          scopes: c.scopes,
          createdAt: c.createdAt,
          lastUsedAt: c.lastUsedAt,
        })),
      });
    }
    case "revoke": {
      if (typeof body.id !== "string") throw new HttpError(400, "bad_request");
      return json(200, { revoked: await store.revokeConnection(body.id, userId, iso(ctx)) });
    }
    case "revokeAll":
      return json(200, { revoked: await store.revokeAllConnections(userId, iso(ctx)) });
    default:
      throw new HttpError(400, "bad_request");
  }
}

// ---------------------------------------------------------------------
// Production wiring
// ---------------------------------------------------------------------

function productionDeps(): AgentAuthDeps {
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Client metadata hosts are the agents' (claude.ai, chatgpt.com), not
  // Penn's: the course-site allow-list (`LHF_DISCOVERY_HOSTS`) must not
  // apply, so only the public-address and https rules are kept.
  const guard = { ...productionNetGuard(), allowedHostSuffixes: null };
  return {
    store: new PostgrestAgentStore(client),
    publicBase: publicBaseFromEnv(),
    fetchClientMetadata: async (url) => {
      const response = await guardedFetch(fetch, url, { timeoutMs: 5000, headers: { Accept: "application/json" } }, guard);
      if (!response.ok) throw new Error(`metadata status ${response.status}`);
      const body = await readTextCapped(response, { maxBytes: 64 * 1024, deadlineMs: 5000 });
      if (!body || body.truncated) throw new Error("metadata unreadable");
      return JSON.parse(body.text);
    },
    requireUserId: async (req) => (await requireUser(req)).userId,
    frontClientIPSecret: Deno.env.get("LHF_FRONT_CLIENT_IP_SECRET")?.trim() || undefined,
  };
}

if (import.meta.main) Deno.serve((req) => handleAgentAuth(req, productionDeps()));
