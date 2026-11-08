// Token primitives for the agent connection (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md;
// research §3). Pure: no Deno APIs beyond WebCrypto, so `agentTokens.test.ts`
// can drive every rule and so both `agent-auth` (which mints) and `mcp`
// (which verifies) share one definition of what a token is.
//
// Why opaque tokens and not JWTs: a signed token the resource server can
// verify offline is the textbook answer, and it is wrong here for one
// reason the plan states — revocation. A student revokes a connection from
// Profile and expects the agent to stop reading at once; a self-contained
// JWT keeps working until it expires unless the resource server consults a
// list anyway, at which point the signature bought nothing. An opaque token
// is one row lookup by hash, and deleting the row is the revocation. The
// hash at rest means a database read never yields a usable credential.

/** 32 random bytes, so 256 bits of entropy, as unpadded base64url: 43 chars. */
const TOKEN_RANDOM_BYTES = 32;

/** Access tokens are short: an hour, the clients refresh silently. */
export const ACCESS_TOKEN_TTL_MS = 60 * 60_000;
/** Refresh tokens: 60 days, rotated on every use. A student who does not
 *  use the agent for two months signs in again from the agent, which is
 *  one phone approval. */
export const REFRESH_TOKEN_TTL_MS = 60 * 24 * 60 * 60_000;
/** A pending authorization waits five minutes for the phone. */
export const PENDING_AUTH_TTL_MS = 5 * 60_000;
/** The one-time authorization code the browser carries back to the client. */
export const AUTH_CODE_TTL_MS = 60_000;

export type TokenKind = "access" | "refresh";

/** The prefix makes a leaked string recognisable in a log or a bug report
 *  without hashing it first (`smt_a_` access, `smt_r_` refresh, `smt_c_`
 *  authorization code). The whole string, prefix included, is what is
 *  hashed and what the client presents. */
const PREFIX: Record<TokenKind | "code", string> = { access: "smt_a_", refresh: "smt_r_", code: "smt_c_" };
const TOKEN_PATTERN = /^smt_[arc]_[A-Za-z0-9_-]{43}$/;

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** A fresh token. `randomBytes` is a parameter only so a test can pin it. */
export function generateToken(
  kind: TokenKind | "code",
  randomBytes: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n)),
): string {
  return PREFIX[kind] + base64url(randomBytes(TOKEN_RANDOM_BYTES));
}

/** True when a presented string has the shape of one of our tokens. A
 *  string of another shape is refused before any database read, so a
 *  flood of junk bearers costs no lookups. */
export function looksLikeToken(value: string): boolean {
  return TOKEN_PATTERN.test(value);
}

export function tokenKindOf(value: string): TokenKind | "code" | null {
  if (value.startsWith(PREFIX.access)) return "access";
  if (value.startsWith(PREFIX.refresh)) return "refresh";
  if (value.startsWith(PREFIX.code)) return "code";
  return null;
}

/** SHA-256 of the token's UTF-8 bytes, lowercase hex: the only form stored.
 *  Also used for the browser nonce and the authorization code. */
export async function hashToken(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** The `Authorization: Bearer <token>` value, or null for a missing or
 *  malformed header. The scheme is case-insensitive per RFC 9110; the token
 *  itself is not. */
export function parseBearer(authorization: string | null | undefined): string | null {
  if (!authorization) return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(authorization);
  return match ? match[1] : null;
}

/** Constant-time string equality for hex digests of equal length. A plain
 *  `===` short-circuits on the first differing byte, which leaks the digest
 *  position by timing; on hashes of random tokens that is theoretical, and
 *  it costs nothing to be right. */
export function digestsEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
