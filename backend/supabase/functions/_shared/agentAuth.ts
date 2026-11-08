// Pure rules for the agent connection's authorization server (`agent-auth`;
// docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §3). No I/O and no Deno APIs
// beyond WebCrypto, so `agentAuth.test.ts` can drive every branch and the
// handler stays a thin sequence of steps around these decisions.
//
// The shape of the flow: students have no login, so "authorize" is
// pairing. The browser (the agent's sign-in tab) shows a code and a number,
// the student's phone approves it, the browser proceeds. Everything here is
// either a check on what a client asked for, or a piece of that pairing.
import type { AuthorizeParams } from "./agentStore.ts";
import { AGENT_SCOPES, DEFAULT_SCOPE } from "./agentMetadata.ts";
import { base64url, digestsEqual } from "./agentTokens.ts";

export type AuthorizeRequest = AuthorizeParams & {
  /** `cimd`: the client id is an https metadata-document URL. `registered`:
   *  it is an `smc_` id from dynamic registration. */
  clientKind: "cimd" | "registered";
};

export type AuthorizeValidation =
  | { ok: true; request: AuthorizeRequest }
  | { ok: false; error: string; description: string; redirectable: boolean };

const CHALLENGE_PATTERN = /^[A-Za-z0-9._~-]{43,128}$/;
const MAX_STATE_LENGTH = 512;

function stripTrailingSlash(value: string): string {
  return value.endsWith("/") ? value.slice(0, -1) : value;
}

/** True for an IPv4 literal (any dotted-number or bare-number spelling) or
 *  an IPv6 literal: a client id must be a name, so a metadata fetch can
 *  never be aimed at an address. */
function isIPLiteral(hostname: string): boolean {
  return hostname.startsWith("[") || hostname.includes(":") || /^\d+(\.\d+){0,3}$/.test(hostname) ||
    /^0x[0-9a-f]+$/i.test(hostname);
}

const REGISTERED_CLIENT_PATTERN = /^smc_[A-Za-z0-9_-]{22}$/;

export function isRegisteredClientId(clientId: string): boolean {
  return REGISTERED_CLIENT_PATTERN.test(clientId);
}

/** An https URL on a public name: no fragment, credentials, IP literal,
 *  `localhost` or single-label host. */
function isCIMDClientId(clientId: string): boolean {
  const u = parseURL(clientId);
  return u !== null && u.protocol === "https:" && u.hash === "" && !clientId.includes("#") && u.username === "" &&
    u.password === "" && !isIPLiteral(u.hostname) && u.hostname !== "localhost" && u.hostname.includes(".");
}

function parseURL(value: string | null): URL | null {
  if (!value) return null;
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

/** What a client asked for, checked before anything is stored or fetched.
 *  `redirectable` says whether the error may be sent back to the client's
 *  `redirect_uri`: never when the client id or the redirect URI is itself
 *  unusable, because bouncing to an unverified URL is an open redirect. */
export function validateAuthorizeRequest(params: URLSearchParams, mcpURL: string): AuthorizeValidation {
  const fatal = (description: string): AuthorizeValidation => ({
    ok: false,
    error: "invalid_request",
    description,
    redirectable: false,
  });
  const soft = (error: string, description: string): AuthorizeValidation => ({
    ok: false,
    error,
    description,
    redirectable: true,
  });

  const clientId = params.get("client_id");
  if (!clientId || !(isRegisteredClientId(clientId) || isCIMDClientId(clientId))) {
    return fatal("client_id must be an https URL on a public host name, or a registered client id");
  }
  const clientKind = isRegisteredClientId(clientId) ? "registered" : "cimd";

  const redirectUri = params.get("redirect_uri");
  const redirectURL = parseURL(redirectUri);
  if (!redirectUri || !redirectURL || redirectURL.hash !== "" || redirectUri.includes("#")) {
    return fatal("redirect_uri must be a URL without a fragment");
  }

  if (params.get("response_type") !== "code") {
    return soft("unsupported_response_type", "response_type must be code");
  }

  const challenge = params.get("code_challenge");
  if (!challenge || !CHALLENGE_PATTERN.test(challenge)) {
    return soft("invalid_request", "code_challenge must be 43 to 128 URL-safe characters");
  }
  if (params.get("code_challenge_method") !== "S256") {
    return soft("invalid_request", "code_challenge_method must be S256");
  }

  // Claude and ChatGPT send `resource`; an older client may not. Absent
  // means "the only resource this server has".
  const resource = params.get("resource");
  if (resource !== null && stripTrailingSlash(resource) !== mcpURL) {
    return soft("invalid_target", "resource does not name this server");
  }

  const scopes = (params.get("scope") ?? "")
    .split(" ")
    .filter((s) => (AGENT_SCOPES as readonly string[]).includes(s));
  // A missing scope means "everything this server has"; a scope that names
  // only things we do not have is a client error, not a grant of everything.
  const askedAnything = (params.get("scope") ?? "").trim() !== "";
  if (askedAnything && scopes.length === 0) return soft("invalid_scope", "no recognised scope was asked for");
  const granted = [...new Set(scopes.length > 0 ? scopes : DEFAULT_SCOPE.split(" "))];

  const state = params.get("state");
  if (state !== null && state.length > MAX_STATE_LENGTH) {
    return soft("invalid_request", "state is too long");
  }

  return {
    ok: true,
    request: {
      clientId,
      clientKind,
      redirectUri,
      codeChallenge: challenge,
      state,
      resource: mcpURL,
      scopes: granted,
    },
  };
}

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/** Exact match, except for the loopback redirect a native client such as
 *  Claude Code uses: it picks its port at run time, so for
 *  `http://localhost…` / `127.0.0.1` / `[::1]` the port is ignored while
 *  scheme, host, path and query must still match (RFC 8252 §7.3). */
export function redirectURIMatches(requested: string, registered: string): boolean {
  if (requested === registered) return true;
  const a = parseURL(requested);
  const b = parseURL(registered);
  if (!a || !b) return false;
  if (a.protocol !== "http:" || b.protocol !== "http:") return false;
  if (!LOOPBACK_HOSTS.has(a.hostname) || !LOOPBACK_HOSTS.has(b.hostname)) return false;
  return a.hostname === b.hostname && a.pathname === b.pathname && a.search === b.search;
}

export function clientHost(clientId: string): string {
  if (isRegisteredClientId(clientId)) return "registered client";
  return parseURL(clientId)?.hostname ?? clientId;
}

export type ClientMetadataValidation = { ok: true; clientName: string } | { ok: false; reason: string };

/** Checks a fetched client metadata document (CIMD) against what the
 *  request claimed: the document must say it is that client, list the
 *  redirect URI, and be a public client (`none`), since we hold no secret
 *  for anyone. */
export function validateClientMetadata(doc: unknown, clientId: string, redirectUri: string): ClientMetadataValidation {
  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) return { ok: false, reason: "not an object" };
  const d = doc as Record<string, unknown>;
  if (d.client_id !== clientId) return { ok: false, reason: "client_id does not match" };
  const uris = d.redirect_uris;
  if (!Array.isArray(uris) || uris.length === 0 || !uris.every((u) => typeof u === "string")) {
    return { ok: false, reason: "redirect_uris missing" };
  }
  if (!uris.some((u) => redirectURIMatches(redirectUri, u as string))) {
    return { ok: false, reason: "redirect_uri is not registered" };
  }
  const method = d.token_endpoint_auth_method;
  if (method !== undefined && method !== "none") return { ok: false, reason: "client authentication is not supported" };
  const grants = d.grant_types;
  if (grants !== undefined && !(Array.isArray(grants) && grants.includes("authorization_code"))) {
    return { ok: false, reason: "authorization_code grant is not declared" };
  }
  const name = typeof d.client_name === "string" ? d.client_name.trim().slice(0, 80) : "";
  return { ok: true, clientName: name !== "" ? name : clientHost(clientId) };
}

const VERIFIER_PATTERN = /^[A-Za-z0-9._~-]{43,128}$/;

/** RFC 7636 S256: base64url(sha256(verifier)), unpadded, compared in
 *  constant time. */
export async function verifyPKCE(verifier: string, challenge: string): Promise<boolean> {
  if (!VERIFIER_PATTERN.test(verifier)) return false;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return digestsEqual(base64url(new Uint8Array(digest)), challenge);
}

// ---------------------------------------------------------------------
// Dynamic client registration (RFC 7591)
// ---------------------------------------------------------------------

export type RegistrationValidation =
  | { ok: true; clientName: string; redirectUris: string[] }
  | { ok: false; error: "invalid_client_metadata"; description: string };

const MAX_REDIRECT_URIS = 10;

function isAcceptableRegisteredRedirect(value: string): boolean {
  const u = parseURL(value);
  if (!u || u.hash !== "" || value.includes("#") || u.username !== "" || u.password !== "") return false;
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && LOOPBACK_HOSTS.has(u.hostname);
}

/** A registration request, checked. Only public clients (`none`) with the
 *  code flow are accepted; anything else is refused rather than quietly
 *  downgraded, so a client that wants a secret learns it at registration. */
export function validateRegistrationRequest(body: unknown): RegistrationValidation {
  const bad = (description: string): RegistrationValidation => ({ ok: false, error: "invalid_client_metadata", description });
  if (typeof body !== "object" || body === null || Array.isArray(body)) return bad("body must be a JSON object");
  const b = body as Record<string, unknown>;
  const uris = b.redirect_uris;
  if (!Array.isArray(uris) || uris.length === 0 || uris.length > MAX_REDIRECT_URIS || !uris.every((u) => typeof u === "string")) {
    return bad("redirect_uris must be 1 to 10 strings");
  }
  if (!uris.every((u) => isAcceptableRegisteredRedirect(u as string))) {
    return bad("redirect_uris must be https or loopback http URLs without a fragment");
  }
  if (b.client_name !== undefined && typeof b.client_name !== "string") return bad("client_name must be a string");
  if (b.token_endpoint_auth_method !== undefined && b.token_endpoint_auth_method !== "none") {
    return bad("token_endpoint_auth_method must be none");
  }
  const subset = (value: unknown, allowed: string[]) =>
    value === undefined || (Array.isArray(value) && value.every((v) => typeof v === "string" && allowed.includes(v)));
  if (!subset(b.grant_types, ["authorization_code", "refresh_token"])) {
    return bad("grant_types must be authorization_code and refresh_token");
  }
  if (!subset(b.response_types, ["code"])) return bad("response_types must be code");
  const name = typeof b.client_name === "string" ? b.client_name.trim().slice(0, 80) : "";
  return { ok: true, clientName: name !== "" ? name : "MCP client", redirectUris: [...uris] as string[] };
}

// ---------------------------------------------------------------------
// Pairing codes
// ---------------------------------------------------------------------

export type RandomBytes = (n: number) => Uint8Array;

export const USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ";
const USER_CODE_LENGTH = 8;

/** Uniform integer in [0, n) for n <= 256 by rejection sampling: bytes at
 *  or above the largest multiple of n are discarded, so there is no modulo
 *  bias at all. */
function randomBelow(n: number, random: RandomBytes): number {
  const limit = Math.floor(256 / n) * n;
  for (;;) {
    for (const byte of random(16)) {
      if (byte < limit) return byte % n;
    }
  }
}

/** 8 characters of RFC 8628's consonant alphabet (no vowels, so no words;
 *  no 0/O/1/I to misread). 20^8 is about 2.6e10 codes, and a code lives
 *  five minutes. Uniform by rejection sampling (see `randomBelow`). */
export function generateUserCode(random: RandomBytes): string {
  let code = "";
  for (let i = 0; i < USER_CODE_LENGTH; i++) code += USER_CODE_ALPHABET[randomBelow(USER_CODE_ALPHABET.length, random)];
  return code;
}

export function formatUserCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/** What the student typed, as a stored code, or null when it cannot be one. */
export function normalizeUserCode(typed: string): string | null {
  const code = typed.toUpperCase().replace(/[\s-]/g, "");
  if (code.length !== USER_CODE_LENGTH) return null;
  for (const ch of code) if (!USER_CODE_ALPHABET.includes(ch)) return null;
  return code;
}

/** The number the page shows and the phone asks the student to pick out of
 *  three: a relayed code (QRLJacking) reaches a phone whose owner is not
 *  looking at the page that started it, and cannot pick the right one. */
export function matchChoices(random: RandomBytes): { answer: number; choices: number[] } {
  const picked: number[] = [];
  while (picked.length < 3) {
    const n = 10 + randomBelow(90, random);
    if (!picked.includes(n)) picked.push(n);
  }
  const answer = picked[0];
  for (let i = picked.length - 1; i > 0; i--) {
    const j = randomBelow(i + 1, random);
    [picked[i], picked[j]] = [picked[j], picked[i]];
  }
  return { answer, choices: picked };
}

/** 128 random bits as base64url (22 chars). */
export function generateId(random: RandomBytes): string {
  return base64url(random(16));
}

export function nonceCookieName(pendingId: string): string {
  return `sa_${pendingId}`;
}

export function parseCookies(header: string | null): Map<string, string> {
  const cookies = new Map<string, string>();
  if (!header) return cookies;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const name = part.slice(0, eq).trim();
    if (name !== "" && !cookies.has(name)) cookies.set(name, part.slice(eq + 1).trim());
  }
  return cookies;
}

// ---------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------

export function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** A JS string literal that is safe inside an inline `<script>`. */
function jsString(value: string): string {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026")
    .replaceAll(" ", "\\u2028")
    .replaceAll(" ", "\\u2029");
}

export interface AuthorizePageView {
  clientName: string;
  clientHost: string;
  scopes: string[];
  pendingId: string;
  /** The stored 8-character code, unformatted. */
  userCode: string;
  matchNumber: number;
  /** `<agent-auth root>/status?p=<id>`, same origin. */
  statusURL: string;
  /** Local development only: a link that approves without a phone. The
   *  production handler never sets it. */
  devApproveURL?: string;
}

const PAGE_STYLE = `
body{font:16px/1.4 -apple-system,system-ui,sans-serif;margin:0;padding:32px 20px;display:flex;justify-content:center;color:#1c1c1e;background:#fff}
main{max-width:420px;width:100%}
h1{font-size:20px;font-weight:600;margin:0 0 24px}
.label{font-size:13px;color:#6e6e73;margin:20px 0 4px}
.code{font:600 28px ui-monospace,monospace;letter-spacing:2px}
.num{font-size:64px;font-weight:700;line-height:1}
.btn{display:block;text-align:center;margin:28px 0 12px;padding:14px;border-radius:12px;background:#1c1c1e;color:#fff;text-decoration:none;font-weight:600}
.small{font-size:14px;color:#6e6e73}
@media (prefers-color-scheme:dark){body{background:#000;color:#f5f5f7}.btn{background:#f5f5f7;color:#000}}
`;

export function authorizePage(view: AuthorizePageView): string {
  const name = escapeHTML(view.clientName);
  const host = escapeHTML(view.clientHost);
  const asksDraft = view.scopes.includes("draft");
  const wants = asksDraft
    ? "wants to read your classes and work and propose drafts for you to review"
    : "wants to read your classes and work";
  const deepLink = `smooth://link?c=${encodeURIComponent(view.pendingId)}`;
  const dev = typeof view.devApproveURL === "string"
    ? `<p class="small"><a href="${escapeHTML(view.devApproveURL)}">approve (dev)</a></p>`
    : "";
  const failure = `Not approved. Close this tab and try again from ${view.clientName}.`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>Smooth</title><style>${PAGE_STYLE}</style></head>
<body><main>
<h1>${name} (${host}) ${wants}</h1>
<div class="label">code</div><div class="code">${escapeHTML(formatUserCode(view.userCode))}</div>
<div class="label">Smooth will ask you to pick this number</div><div class="num">${view.matchNumber}</div>
<a class="btn" role="button" href="${escapeHTML(deepLink)}">Open Smooth</a>
<p class="small">On another device: open Smooth → Profile → connect an agent and type the code</p>
${dev}
<p class="small" id="status" aria-live="polite">waiting for approval</p>
</main>
<script>
(function(){
var url=${jsString(view.statusURL)};
var failure=${jsString(failure)};
var el=document.getElementById("status");
var timer=null;
function stop(text){if(timer)clearInterval(timer);timer=null;el.textContent=text}
function poll(){
fetch(url,{credentials:"same-origin",cache:"no-store"}).then(function(r){
if(r.status>=400&&r.status<500){stop(failure);return null}
return r.json()}).then(function(b){
if(!b)return;
if(b.state==="approved"){stop("approved. going back to the app…");location.href=url+"&go=1"}
else if(b.state==="denied"||b.state==="expired"){stop(failure)}
}).catch(function(){})}
timer=setInterval(poll,2000);poll();
})();
</script></body></html>`;
}

export function errorPage(title: string, sentence: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Smooth</title><style>${PAGE_STYLE}</style></head>
<body><main><h1>${escapeHTML(title)}</h1><p class="small">${escapeHTML(sentence)}</p></main></body></html>`;
}
